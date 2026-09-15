import Foundation
import Combine
import PDFKit
import Vision
import ImageIO

struct IOSDocumentExtraction: Sendable {
    let text: String
    let coverage: String
}

/// Reads only URLs supplied by the document picker. No writes to originals or network requests.
actor IOSDocumentReader {
    func extract(at url: URL) throws -> IOSDocumentExtraction {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw IOSDocumentError.unreadable }
            var pages: [String] = []
            var failed = 0
            let count = min(pdf.pageCount, 30)
            for i in 0..<count {
                try Task.checkCancellation()
                guard let page = pdf.page(at: i) else { failed += 1; continue }
                let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty { pages.append("Página \(i + 1):\n\(embedded)") }
                else if let image = Self.render(page), let text = try? Self.ocr(image), !text.isEmpty {
                    pages.append("Página \(i + 1) — OCR:\n\(text)")
                } else { failed += 1 }
            }
            let text = pages.joined(separator: "\n\n")
            let limit = text.count > 60_000 ? " Texto limitado a 60.000 caracteres." : ""
            return .init(text: String(text.prefix(60_000)), coverage: "\(count) de \(pdf.pageCount) página(s) consultada(s); \(failed) sem texto legível.\(limit)")
        }
        guard ["jpg", "jpeg", "png"].contains(ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400
              ] as CFDictionary) else { throw IOSDocumentError.unreadable }
        let text = try Self.ocr(image)
        return .init(text: String(text.prefix(60_000)), coverage: text.isEmpty ? "OCR concluído sem texto legível." : "OCR local da imagem; confira a leitura na prévia.")
    }

    private static func ocr(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["pt-BR", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let bounds = ref.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2400 / max(bounds.width, bounds.height), 3)
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }
}

enum IOSDocumentError: LocalizedError {
    case unreadable, changed
    var errorDescription: String? {
        switch self {
        case .unreadable: "Não foi possível ler este documento. Escolha um PDF desbloqueado, JPEG ou PNG."
        case .changed: "O arquivo mudou ou não está mais acessível. Escolha-o novamente antes de continuar."
        }
    }
}

struct IOSImportedDocument: Identifiable {
    let id: UUID
    let url: URL
    let bookmark: Data
    let modified: Date?
    let size: Int?
    let extraction: IOSDocumentExtraction
    var title: String { url.lastPathComponent }
}

@MainActor
final class IOSDocumentStore: ObservableObject {
    @Published private(set) var documents: [IOSImportedDocument] = []
    @Published private(set) var isReading = false
    @Published private(set) var errorMessage: String?
    private let reader = IOSDocumentReader()

    func add(_ urls: [URL]) async {
        guard !isReading else { return }
        isReading = true; errorMessage = nil
        defer { isReading = false }
        var failures: [String] = []
        for url in urls.prefix(20) {
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                let extraction = try await reader.extract(at: url)
                documents.removeAll { $0.url == url }
                documents.append(.init(id: UUID(), url: url, bookmark: bookmark, modified: values.contentModificationDate,
                                       size: values.fileSize, extraction: extraction))
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if urls.count > 20 { failures.append("Escolha até 20 arquivos por vez.") }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func search(_ query: String) -> [IOSImportedDocument] {
        let parsed = PhotoDocumentQuery(query)
        return documents.filter {
            parsed.matches(extracted: PhotoDocumentQuery.normalize($0.extraction.text), metadata: PhotoDocumentQuery.normalize($0.title), rawText: $0.extraction.text)
        }.sorted { a, b in
            func score(_ item: IOSImportedDocument) -> Int {
                let text = PhotoDocumentQuery.normalize(item.extraction.text)
                return parsed.terms.reduce(0) { $0 + (PhotoDocumentQuery.contains(text, phrase: $1) ? 8 : 0) }
            }
            if score(a) != score(b) { return score(a) > score(b) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.prefix(5).map { $0 }
    }

    /// Caller balances the security scope after preview or payload assembly.
    func resolve(_ document: IOSImportedDocument) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: document.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard !stale, v.contentModificationDate == document.modified, v.fileSize == document.size else { throw IOSDocumentError.changed }
            return url
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw IOSDocumentError.changed
        }
    }
}

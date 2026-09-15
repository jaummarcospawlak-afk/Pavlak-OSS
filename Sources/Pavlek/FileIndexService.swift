#if os(macOS)
import AppKit
import Foundation
import PDFKit
@preconcurrency import Vision

struct ScopedFileIndexSnapshot {
    let files: [IndexedFile]
    let rootNamesByID: [String: String]
    let coveredDirectoryCount: Int
}

@MainActor
final class FileIndexService: ObservableObject {
    @Published private(set) var snapshot = FileIndexSnapshot()
    @Published private(set) var isIndexing = false
    @Published private(set) var errorMessage: String?
    private let store: FileIndexStore
    private let allowedExtensions = Set(["pdf", "pages", "doc", "docx", "txt", "rtf", "md"])
    private var extractedTextCache: [String: (modifiedAt: Date?, text: String)] = [:]

    init(store: FileIndexStore = FileIndexStore()) {
        self.store = store
        Task { snapshot = await store.current() }
    }

    func reload() async { snapshot = await store.current() }

    func authorizedDirectories() async -> [URL] {
        await reload()
        var directories: [URL] = []
        for root in snapshot.roots {
            if let url = try? await store.resolve(root) { directories.append(url) }
        }
        return directories
    }

    func authorizedSnapshot() async -> ScopedFileIndexSnapshot {
        let directories = await authorizedDirectories()
        return await snapshot(inside: directories)
    }

    func snapshot(inside allowedDirectories: [URL]) async -> ScopedFileIndexSnapshot {
        await reload()
        let allowed = allowedDirectories.map(Self.canonicalDirectory)
        var rootURLs: [String: URL] = [:]
        var rootNamesByID: [String: String] = [:]
        var coveredDirectories = Set<Int>()

        for root in snapshot.roots {
            guard let resolved = try? await store.resolve(root) else { continue }
            let rootURL = Self.canonicalDirectory(resolved)
            for (index, directory) in allowed.enumerated()
            where Self.isDescendantOrSame(rootURL, of: directory) || Self.isDescendantOrSame(directory, of: rootURL) {
                coveredDirectories.insert(index)
            }
            guard allowed.contains(where: {
                Self.isDescendantOrSame(rootURL, of: $0) || Self.isDescendantOrSame($0, of: rootURL)
            }) else { continue }
            rootURLs[root.id] = rootURL
            rootNamesByID[root.id] = root.displayName
        }

        var seenPaths = Set<String>()
        let files = snapshot.files.compactMap { file -> IndexedFile? in
            guard let rootURL = rootURLs[file.rootID] else { return nil }
            let fileURL = Self.canonicalDirectory(rootURL.appendingPathComponent(file.relativePath))
            guard allowed.contains(where: { Self.isDescendantOrSame(fileURL, of: $0) }),
                  seenPaths.insert(fileURL.path).inserted else { return nil }
            return IndexedFile(
                id: "\(file.rootID):\(file.id)",
                rootID: file.rootID,
                name: file.name,
                relativePath: file.relativePath,
                fileExtension: file.fileExtension,
                modifiedAt: file.modifiedAt
            )
        }
        return .init(
            files: files,
            rootNamesByID: rootNamesByID,
            coveredDirectoryCount: coveredDirectories.count
        )
    }

    nonisolated static func isDescendantOrSame(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = canonicalDirectory(candidate).pathComponents
        let directoryComponents = canonicalDirectory(directory).pathComponents
        guard candidateComponents.count >= directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    func refreshAuthorizedFolders() async {
        await reload()
        let roots = snapshot.roots
        guard !roots.isEmpty else { return }
        for root in roots {
            do {
                let directory = try await store.resolve(root)
                let accessed = directory.startAccessingSecurityScopedResource()
                await index(directory: directory)
                if accessed { directory.stopAccessingSecurityScopedResource() }
            } catch {
                errorMessage = error.localizedDescription
                PavlakErrorReporter.shared.report(
                    module: "FileIndexService",
                    action: "atualizar_pastas_autorizadas",
                    message: "Não foi possível atualizar uma pasta já autorizada.",
                    error: error,
                    result: "erro_recuperado"
                )
            }
        }
    }

    func chooseAndIndexFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Autorizar pasta para o Pavlak File Index"
        panel.message = "O Pavlak armazenará somente metadados e manterá os arquivos originais intactos."
        panel.prompt = "Autorizar pasta"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { await index(directory: url) }
    }

    func index(directory: URL) async {
        let canonicalRoot = Self.canonicalDirectory(directory)
        let accessed = canonicalRoot.startAccessingSecurityScopedResource()
        defer { if accessed { canonicalRoot.stopAccessingSecurityScopedResource() } }
        isIndexing = true; errorMessage = nil
        defer { isIndexing = false }
        do {
            guard FileManager.default.isReadableFile(atPath: canonicalRoot.path) else { throw FileIndexError.rootUnavailable }
            let bookmark = try canonicalRoot.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let rootID = stableID(canonicalRoot.path)
            let root = AuthorizedFileRoot(id: rootID, displayName: canonicalRoot.lastPathComponent, bookmark: bookmark)
            let keys: [URLResourceKey] = [
                .isRegularFileKey, .isPackageKey, .isDirectoryKey,
                .contentModificationDateKey, .fileResourceIdentifierKey, .isHiddenKey
            ]
            let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var records: [IndexedFile] = []
            while let fileURL = enumerator?.nextObject() as? URL {
                let canonicalFile = Self.canonicalDirectory(fileURL)
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                let ext = fileURL.pathExtension.lowercased()
                let supportedPackage = values?.isPackage == true && ext == "pages"
                guard values?.isRegularFile == true || supportedPackage,
                      Self.isDescendantOrSame(canonicalFile, of: canonicalRoot) else { continue }
                guard allowedExtensions.contains(ext) else { continue }
                let relative = String(canonicalFile.path.dropFirst(canonicalRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let identifier = values?.fileResourceIdentifier.map { String(describing: $0) } ?? stableID(relative)
                records.append(IndexedFile(id: identifier, rootID: rootID, name: fileURL.lastPathComponent,
                                           relativePath: relative, fileExtension: ext, modifiedAt: values?.contentModificationDate))
            }
            try await store.replace(root: root, files: records)
            snapshot = await store.current()
        } catch {
            errorMessage = error.localizedDescription
            PavlakErrorReporter.shared.report(module: "FileIndexService", action: "indexar_pasta", message: "Não foi possível atualizar o índice de arquivos.", error: error, result: "erro_recuperado")
        }
    }

    func search(command: String) -> [FileSearchCandidate] {
        Self.search(command: command, in: snapshot.files)
    }

    /// Searches both index metadata and locally extracted document text. This is intentionally
    /// explicit and asynchronous: OCR/PDF extraction is never performed by the cheap metadata API.
    func searchIncludingContent(command: String, limit: Int = 20) async -> [FileSearchCandidate] {
        let tokens = Self.meaningfulTokens(in: Self.normalize(command))
        guard !tokens.isEmpty else { return [] }
        var contents: [String: String] = [:]
        for file in snapshot.files {
            if let cached = extractedTextCache[file.id], cached.modifiedAt == file.modifiedAt {
                contents[file.id] = cached.text
                continue
            }
            let candidate = FileSearchCandidate(file: file, score: 0)
            if let text = try? await extractText(from: candidate) {
                contents[file.id] = text
                extractedTextCache[file.id] = (file.modifiedAt, text)
            }
        }
        return Array(Self.search(command: command, in: snapshot.files, contentsByFileID: contents).prefix(max(1, limit)))
    }

    static func search(command: String, in files: [IndexedFile]) -> [FileSearchCandidate] {
        search(command: command, in: files, contentsByFileID: [:])
    }

    static func search(
        command: String,
        in files: [IndexedFile],
        contentsByFileID: [String: String]
    ) -> [FileSearchCandidate] {
        let query = normalize(command)
        let tokens = meaningfulTokens(in: query)
        guard !tokens.isEmpty else { return [] }
        let preferredTypes: [String: Int] = ["pdf": 8, "pages": 7, "docx": 7, "doc": 6, "txt": 4, "rtf": 4, "md": 3]
        let phrase = tokens.joined(separator: " ")
        return files.compactMap { file in
            let name = normalize(file.name)
            let path = normalize(file.relativePath)
            let content = normalize(contentsByFileID[file.id] ?? "")
            var relevance = 0
            if !phrase.isEmpty && name.contains(phrase) { relevance += 40 }
            if !phrase.isEmpty && path.contains(phrase) { relevance += 24 }
            if !phrase.isEmpty && content.contains(phrase) { relevance += 32 }
            for token in tokens {
                if name.contains(token) { relevance += 14 }
                if path.contains(token) { relevance += 6 }
                if content.contains(token) { relevance += 10 }
            }
            guard relevance > 0 else { return nil }
            return FileSearchCandidate(file: file, score: relevance + (preferredTypes[file.fileExtension] ?? 0))
        }.sorted { lhs, rhs in lhs.score == rhs.score ? (lhs.file.modifiedAt ?? .distantPast) > (rhs.file.modifiedAt ?? .distantPast) : lhs.score > rhs.score }
    }

    func extractText(from candidate: FileSearchCandidate) async throws -> String {
        let url = try await store.resolve(candidate.file)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FileIndexError.rootUnavailable }
        let cacheKey = url.path
        let currentDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = extractedTextCache[cacheKey], let currentDate, cached.modifiedAt == currentDate { return cached.text }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let ext = candidate.file.fileExtension
        let text: String?
        if ext == "pdf" { text = try await extractPDFText(at: url) }
        else if ["txt", "md"].contains(ext) { text = try String(contentsOf: url, encoding: .utf8) }
        else if ["rtf", "doc", "docx"].contains(ext) {
            text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        } else {
            // Pages packages remain searchable by name, path, type, date and Spotlight metadata,
            // and can be previewed/opened. No private package parsing is attempted.
            throw FileIndexError.unsupportedDocument
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileIndexError.emptyDocument }
        let result = String(text.prefix(80_000))
        extractedTextCache[cacheKey] = (currentDate, result)
        return result
    }

    func resolveForPreview(_ file: IndexedFile) async throws -> URL {
        let url = try await store.resolve(file)
        _ = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            throw FileIndexError.rootUnavailable
        }
        return url
    }

    private func extractPDFText(at url: URL) async throws -> String? {
        guard let document = PDFDocument(url: url) else { throw FileIndexError.unsupportedDocument }
        if document.isEncrypted && !document.unlock(withPassword: "") {
            throw FileIndexError.protectedDocument
        }
        if let embedded = document.string, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return embedded }
        var pageTexts: [String] = []
        for pageIndex in 0..<min(document.pageCount, 20) {
            guard let page = document.page(at: pageIndex) else { continue }
            let thumbnail = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
            var rect = CGRect(origin: .zero, size: thumbnail.size)
            guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            let recognized = await recognizeText(in: image)
            if !recognized.isEmpty { pageTexts.append(recognized) }
        }
        return pageTexts.isEmpty ? nil : pageTexts.joined(separator: "\n\n")
    }

    nonisolated private func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["pt-BR", "en-US"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(returning: "") }
            }
        }
    }

    private static func meaningfulTokens(in query: String) -> [String] {
        let ignored = Set([
            "a", "ao", "aos", "as", "da", "das", "de", "do", "dos", "e", "em", "me", "meu", "minha",
            "na", "nas", "no", "nos", "o", "os", "para", "por", "um", "uma", "pavlak", "pavlek",
            "arquivo", "arquivos", "documento", "documentos", "encontre", "localize", "pasta", "pastas",
            "procure", "pesquise", "buscar", "busque", "local"
        ])
        return query.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !ignored.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
    }

    nonisolated private static func canonicalDirectory(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func stableID(_ value: String) -> String {
        String(value.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }
}
#endif

#if os(macOS)
import Foundation

protocol DocumentSummarizer: Sendable {
    var name: String { get }
    func summarize(title: String, text: String) async throws -> String
}

struct ExtractiveDocumentSummarizer: DocumentSummarizer {
    let name = "Resumo local de contingência"
    func summarize(title: String, text: String) async throws -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let sentences = cleaned.split(whereSeparator: { ".!?".contains($0) }).prefix(6).map(String.init)
        return "Resumo de \(title):\n\n" + sentences.joined(separator: ". ") + (sentences.isEmpty ? "" : ".")
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
actor FoundationDocumentSummarizer: DocumentSummarizer {
    nonisolated let name = "Apple Intelligence"
    private let session = LanguageModelSession(instructions: "Resuma documentos em português do Brasil. Seja fiel ao texto, destaque partes, datas, valores, obrigações e prazos. Não invente informações.")
    func summarize(title: String, text: String) async throws -> String {
        try await session.respond(to: "Documento: \(title)\n\nProduza um resumo objetivo:\n\n\(text)").content
    }
}
#endif

enum DocumentSummarizerFactory {
    static func make() -> any DocumentSummarizer {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationDocumentSummarizer() }
        #endif
        return ExtractiveDocumentSummarizer()
    }
}
#endif

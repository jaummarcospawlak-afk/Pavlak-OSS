#if os(macOS)
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum PavlakAction: String, Sendable { case searchDocument, searchFile, unknown }
enum PavlakDocumentAction { case open, reveal }

struct PavlakIntent: Sendable {
    let action: PavlakAction
    let query: String
    let documentType: String?
    let dateContext: Date?

    init(query: LocalUnifiedSearchQuery) {
        action = query.documentKind == .file ? .searchFile : .searchDocument
        self.query = ([query.requestedPhrase] + query.detailTerms).joined(separator: " ")
        documentType = query.documentKind == .file ? nil : query.documentKind.rawValue
        dateContext = query.dateContext
    }
}

typealias PavlakSearchRequest = LocalUnifiedSearchQuery
struct PavlakProviderResponse {
    let records: [LocalSearchRecord]
    let status: LocalSearchSourceStatus
}

@MainActor
protocol PavlakSearchProvider {
    func search(_ request: PavlakSearchRequest) async -> PavlakProviderResponse
}

struct PavlakFileSearchProvider: PavlakSearchProvider {
    let index: FileIndexService
    func search(_ request: PavlakSearchRequest) async -> PavlakProviderResponse {
        let result = await PavlakOrchestrator.searchFiles(query: request, index: index)
        return .init(records: result.records, status: result.status)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private enum DocumentCategory {
    case contract, receipt, ticket, file
}
#endif

enum PavlakLocalIntentInterpreter {
    @MainActor
    static func interpret(_ fallback: LocalUnifiedSearchQuery) async -> LocalUnifiedSearchQuery {
        // Known categories already have an exact deterministic interpretation. The local
        // model interprets other wording without seeing file names or document contents.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), fallback.documentKind == .file,
           SystemLanguageModel.default.availability == .available {
            do {
                let session = LanguageModelSession(instructions: "Classifique apenas a categoria do arquivo solicitado. Contrato: contract. Comprovante, recibo ou conta de consumo: receipt. Ingresso ou bilhete: ticket. Outros: file.")
                let response = try await session.respond(to: fallback.original, generating: DocumentCategory.self)
                let kind: LocalUnifiedSearchQuery.DocumentKind
                switch response.content {
                case .contract: kind = .contract
                case .receipt: kind = .receipt
                case .ticket: kind = .ticket
                case .file: return fallback
                }
                return .init(original: fallback.original, normalized: fallback.normalized,
                             documentKind: kind, requestedPhrase: fallback.requestedPhrase,
                             expandedPhrases: kind.phrases + fallback.detailTerms,
                             detailTerms: fallback.detailTerms, dateContext: fallback.dateContext)
            } catch { return fallback }
        }
        #endif
        return fallback
    }
}
#endif

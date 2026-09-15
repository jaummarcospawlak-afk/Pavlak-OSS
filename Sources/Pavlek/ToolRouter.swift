import Foundation

@MainActor
final class ToolRouter {
    nonisolated static let photoSearchTool = "photos.search"
    private let photos: PhotoLibraryService
    private let registry: PavlakConnectorRegistry
    #if os(macOS)
    private let workflowFileIndex = FileIndexService()
    private let workflowSummarizer: any DocumentSummarizer = DocumentSummarizerFactory.make()
    private let workflowDocumentTool = RichTextDocumentTool()
    #endif

    init(photos: PhotoLibraryService, registry: PavlakConnectorRegistry? = nil) {
        self.photos = photos
        self.registry = registry ?? PavlakConnectorRegistry.shared
    }

    var availableTools: [String] {
        registry.connector(forAction: Self.photoSearchTool) == nil ? [] : [Self.photoSearchTool]
    }

    func availableTools(for request: ParsedRequest) -> [String] {
        switch request.source {
        case .photos: availableTools.filter { $0 == Self.photoSearchTool }
        case .unknown: availableTools
        default: []
        }
    }

    func execute(intent: AgentIntent) async throws -> ToolResult {
        guard intent.toolName == Self.photoSearchTool else {
            throw AgentError.unsupportedTool(intent.toolName)
        }
        registry.refresh()
        guard registry.canExecute(intent.toolName) else {
            throw AgentError.capabilityUnavailable(intent.toolName)
        }
        let query = try photos.locatePhotos(period: intent.period)
        return ToolResult(
            toolName: intent.toolName,
            message: "A busca local encontrou \(query.matchedItemCount) item(ns) em Fotos.",
            authorizationStatus: photos.authorizationState.title,
            accessibleItemCount: query.accessibleItemCount,
            matchedItemCount: query.matchedItemCount,
            photos: query.sample
        )
    }

    #if os(macOS)
    func workflowSearchFiles(query: String) async -> [FileSearchCandidate] {
        await workflowFileIndex.reload()
        return await workflowFileIndex.searchIncludingContent(command: query)
    }

    func workflowExtract(candidate: FileSearchCandidate) async throws -> String {
        try await workflowFileIndex.extractText(from: candidate)
    }

    func workflowSummarize(title: String, text: String) async throws -> String {
        try await workflowSummarizer.summarize(title: title, text: text)
    }

    func workflowCreateDocument(sourceName: String, summary: String) throws -> URL {
        try workflowDocumentTool.createOrganizedDocument(title: "Resumo organizado — contrato de locação", sourceName: sourceName, summary: summary)
    }

    var workflowSummaryToolName: String { workflowSummarizer.name }
    #endif
}

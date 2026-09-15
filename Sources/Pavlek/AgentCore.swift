import Foundation

@MainActor
final class AgentCore: ObservableObject {
    @Published var command = "Pavlek, localize as fotos de ontem."
    @Published private(set) var phase: AgentPhase = .idle
    @Published private(set) var intent: AgentIntent?
    @Published private(set) var structuredIntent: ParsedRequest?
    @Published private(set) var toolResult: ToolResult?
    @Published private(set) var finalResponse = ""
    @Published var showingApproval = false

    let photos: PhotoLibraryService
    private let router: ToolRouter
    private let model: any ModelClient

    var modelName: String { model.displayName }

    init() {
        let photos = PhotoLibraryService()
        self.photos = photos
        self.router = ToolRouter(photos: photos)
        self.model = ModelClientFactory.make()
    }

    func interpret() {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .interpreting
        intent = nil
        structuredIntent = nil
        toolResult = nil
        finalResponse = ""
        Task {
            do {
                let routed = PavlakIntentRouter.parse(command)
                structuredIntent = routed
                let reducedTools = router.availableTools(for: routed)
                if routed.source == .photos,
                   routed.action == "Localizar e apresentar resultados",
                   reducedTools.contains(ToolRouter.photoSearchTool) {
                    intent = AgentIntent(
                        action: routed.action, source: routed.source.rawValue,
                        object: routed.object, period: routed.period,
                        toolName: ToolRouter.photoSearchTool
                    )
                } else {
                    intent = try await model.interpret(command, tools: reducedTools)
                }
                phase = .awaitingApproval
            } catch {
                PavlakErrorReporter.shared.report(module: "AgentCore", action: "interpretar_solicitacao", message: "Não foi possível interpretar a solicitação.", error: error, result: "erro_recuperado")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func requestExecution() { showingApproval = true }

    func authorizeAndExecute() {
        guard let intent else { return }
        showingApproval = false
        phase = .executing
        Task {
            do {
                if intent.toolName == ToolRouter.photoSearchTool {
                    let state = await photos.requestReadAccess()
                    guard state.canRead else { throw AgentError.permissionDenied }
                }
                let result = try await router.execute(intent: intent)
                toolResult = result
                finalResponse = try await model.continueAfterTool(command: command, intent: intent, result: result)
                phase = .finished
            } catch {
                photos.record(error: error)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        phase = .idle
        intent = nil
        structuredIntent = nil
        toolResult = nil
        finalResponse = ""
    }
}

import Foundation

struct PavlakExecutionRequest: Identifiable, Sendable {
    let id: UUID
    let intent: ParsedRequest
    let connectorID: String
    let toolAction: String
}

struct PavlakResultContext: Sendable {
    let requestID: UUID
    let intent: ParsedRequest
    let connectorID: String
    let toolAction: String
    let referenceID: String
}

enum PavlakPipelineError: LocalizedError {
    case noTool
    case connectorUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noTool: "Ainda não há uma conexão capaz de realizar este pedido."
        case .connectorUnavailable: "A conexão necessária não está disponível ou autorizada."
        }
    }
}

@MainActor
final class PavlakExecutionPipeline {
    static let shared = PavlakExecutionPipeline()
    private let registry = PavlakConnectorRegistry.shared

    private init() { }

    func prepare(_ command: String) throws -> PavlakExecutionRequest {
        registry.refresh()
        let intent = PavlakIntentRouter.parse(command)
        let action: String
        switch intent.source {
        case .files:
            action = "files.search"
        case .photos where intent.searchScopes.contains("Álbuns"):
            action = "photos.album.search"
        case .photos:
            action = "photos.search"
        case .web:
            action = "web.open"
        default:
            throw PavlakPipelineError.noTool
        }
        guard let connector = registry.connector(forAction: action) else { throw PavlakPipelineError.noTool }
        guard registry.canExecute(action) else { throw PavlakPipelineError.connectorUnavailable(connector.name) }
        return PavlakExecutionRequest(id: UUID(), intent: intent, connectorID: connector.id, toolAction: action)
    }
}

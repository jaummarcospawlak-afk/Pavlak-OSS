import Foundation

enum AgentPhase: Equatable {
    case idle
    case interpreting
    case awaitingApproval
    case executing
    case finished
    case failed(String)
}

struct AgentIntent: Equatable, Codable, Sendable {
    let action: String
    let source: String
    let object: String
    let period: String
    let toolName: String

    var parsedRequest: ParsedRequest {
        ParsedRequest(
            action: action,
            source: source.lowercased().contains("foto") ? .photos : .files,
            object: object,
            period: period,
            originalText: ""
        )
    }
}

struct PhotoMatch: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date?
    let mediaType: String
    let width: Int
    let height: Int
    let isFavorite: Bool
}

struct ToolResult: Codable, Equatable, Sendable {
    let toolName: String
    let message: String
    let authorizationStatus: String
    let accessibleItemCount: Int
    let matchedItemCount: Int
    let photos: [PhotoMatch]
}

struct PhotoQueryResult: Equatable, Sendable {
    let accessibleItemCount: Int
    let matchedItemCount: Int
    let sample: [PhotoMatch]
}

enum AgentError: LocalizedError {
    case unsupportedTool(String)
    case permissionDenied
    case modelUnavailable
    case invalidModelResponse
    case capabilityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name): "A ferramenta “\(name)” não está disponível."
        case .permissionDenied: "O acesso à biblioteca Fotos não foi autorizado."
        case .modelUnavailable: "A IA do dispositivo não está disponível neste Mac."
        case .invalidModelResponse: "A IA retornou uma interpretação inválida."
        case .capabilityUnavailable: "Esta conexão ainda não está disponível."
        }
    }
}

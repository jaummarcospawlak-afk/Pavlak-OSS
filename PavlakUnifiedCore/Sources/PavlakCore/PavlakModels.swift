import Foundation

public enum PavlakToolName: String, Codable, Sendable, CaseIterable {
    case browserOpen = "browser_open"
    case browserSearch = "browser_search"
    case appOpen = "app_open"
    case fileFind = "file_find"
    case fileOpen = "file_open"
    case systemNotify = "system_notify"
    case inspectorRecentActions = "inspector_recent_actions"
}

public enum PavlakAction: Equatable, Sendable {
    case browserOpen(url: String)
    case browserSearch(query: String)
    case appOpen(name: String)
    case fileFind(query: String, maxResults: Int)
    case fileOpen(relativePath: String)
    case systemNotify(title: String, body: String)
    case inspectorRecentActions(limit: Int)

    public var toolName: PavlakToolName {
        switch self {
        case .browserOpen: return .browserOpen
        case .browserSearch: return .browserSearch
        case .appOpen: return .appOpen
        case .fileFind: return .fileFind
        case .fileOpen: return .fileOpen
        case .systemNotify: return .systemNotify
        case .inspectorRecentActions: return .inspectorRecentActions
        }
    }

    public var argumentsForLog: [String: String] {
        switch self {
        case .browserOpen(let url):
            return ["url": url]
        case .browserSearch(let query):
            return ["query": query]
        case .appOpen(let name):
            return ["name": name]
        case .fileFind(let query, let maxResults):
            return ["query": query, "max_results": String(maxResults)]
        case .fileOpen(let relativePath):
            return ["relative_path": relativePath]
        case .systemNotify(let title, let body):
            return ["title": title, "body": body]
        case .inspectorRecentActions(let limit):
            return ["limit": String(limit)]
        }
    }
}

public struct PavlakActionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let tool: String
    public let arguments: [String: String]
    public let result: String
    public let succeeded: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        tool: String,
        arguments: [String: String],
        result: String,
        succeeded: Bool
    ) {
        self.id = id
        self.date = date
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.succeeded = succeeded
    }
}

public enum PavlakAgentEvent: Sendable, Equatable {
    case interpreting
    case executing(String)
    case completed(String)
    case failed(String)
}

public enum PavlakError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidHTTPResponse
    case invalidResponse
    case authenticationFailed(String)
    case permissionDenied(String)
    case rateLimited(String)
    case api(statusCode: Int, message: String, requestID: String?)
    case unknownTool(String)
    case invalidArguments(String)
    case workspaceNotConfigured
    case unsupportedPlatform(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "A conexão com a OpenAI ainda não foi configurada. Os comandos locais continuam disponíveis."
        case .invalidHTTPResponse:
            return "A OpenAI devolveu uma resposta HTTP inválida."
        case .invalidResponse:
            return "A resposta recebida não pôde ser interpretada."
        case .authenticationFailed(let message):
            return "Autenticação OpenAI recusada: \(message)"
        case .permissionDenied(let message):
            return "Operação bloqueada: \(message)"
        case .rateLimited(let message):
            return "Limite ou cota da OpenAI atingido: \(message)"
        case .api(let statusCode, let message, let requestID):
            let suffix = requestID.map { " • request_id: \($0)" } ?? ""
            return "OpenAI HTTP \(statusCode): \(message)\(suffix)"
        case .unknownTool(let name):
            return "Ferramenta desconhecida: \(name)"
        case .invalidArguments(let details):
            return "Argumentos inválidos: \(details)"
        case .workspaceNotConfigured:
            return "Escolha primeiro a pasta que o Pavlak poderá consultar."
        case .unsupportedPlatform(let details):
            return details
        case .operationFailed(let details):
            return details
        }
    }
}

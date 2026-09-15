import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PavlakOpenAIConnectionStatus: String, Sendable, Equatable {
    case ready
    case authenticatedButRestricted
    case rateLimited
}

public struct PavlakOpenAIConnectionResult: Sendable, Equatable {
    public let status: PavlakOpenAIConnectionStatus
    public let message: String
    public let requestID: String?

    public init(status: PavlakOpenAIConnectionStatus, message: String, requestID: String? = nil) {
        self.status = status
        self.message = message
        self.requestID = requestID
    }
}

private struct PavlakOpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }
    let error: APIError?
}

public actor PavlakOpenAIConnectionService {
    public static let shared = PavlakOpenAIConnectionService()

    private let store: any PavlakAPIKeyStoring
    private let transport: any PavlakHTTPTransport
    private var cachedAPIKey: String?

    public init(
        store: any PavlakAPIKeyStoring = PavlakKeychainStore(),
        transport: any PavlakHTTPTransport = PavlakURLSessionTransport()
    ) {
        self.store = store
        self.transport = transport
    }

    public func connect(apiKey rawKey: String) async throws -> PavlakOpenAIConnectionResult {
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw PavlakError.authenticationFailed("Informe uma chave de API.")
        }

        let result = try await probe(apiKey: apiKey)
        try store.save(apiKey)
        cachedAPIKey = apiKey
        return result
    }

    public func validateStoredKey() async throws -> PavlakOpenAIConnectionResult {
        try await probe(apiKey: resolvedAPIKey())
    }

    public func hasStoredKey() -> Bool {
        (try? resolvedAPIKey()) != nil
    }

    public func disconnect() throws {
        try store.delete()
        cachedAPIKey = nil
    }

    public func authorizedRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = "application/json"
    ) throws -> URLRequest {
        let key = try resolvedAPIKey()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func resolvedAPIKey() throws -> String {
        if let cachedAPIKey, !cachedAPIKey.isEmpty {
            return cachedAPIKey
        }
        guard let stored = try store.load(), !stored.isEmpty else {
            throw PavlakError.missingAPIKey
        }
        cachedAPIKey = stored
        return stored
    }

    private func probe(apiKey: String) async throws -> PavlakOpenAIConnectionResult {
        // Endpoint oficial de metadados usado para confirmar que o cabeçalho
        // Bearer chegou à OpenAI. Não depende do endpoint não documentado /v1/me.
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Client-Request-Id")

        let response = try await transport.send(request)
        let message = Self.errorMessage(from: response.data)

        switch response.statusCode {
        case 200..<300:
            return PavlakOpenAIConnectionResult(
                status: .ready,
                message: "Credencial validada pela OpenAI.",
                requestID: response.requestID
            )
        case 401:
            throw PavlakError.authenticationFailed(message)
        case 403:
            // 403 comprova que a credencial foi recebida e autenticada, mas está restrita.
            return PavlakOpenAIConnectionResult(
                status: .authenticatedButRestricted,
                message: "Credencial autenticada, porém sem permissão para listar modelos.",
                requestID: response.requestID
            )
        case 429:
            // A autenticação também ocorreu; o bloqueio é de cota ou limite.
            return PavlakOpenAIConnectionResult(
                status: .rateLimited,
                message: "Credencial autenticada, mas a conta está limitada ou sem cota.",
                requestID: response.requestID
            )
        default:
            throw PavlakError.api(
                statusCode: response.statusCode,
                message: message,
                requestID: response.requestID
            )
        }
    }

    static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(PavlakOpenAIErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(500))
        }
        return "A API não forneceu detalhes adicionais."
    }
}

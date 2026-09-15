import Foundation

struct OpenAICredentialValidation: Sendable {
    let responseID: String
    let statusCode: Int
    let requestID: String?

    var diagnosticMessage: String {
        "HTTP \(statusCode) • credencial validada pela Responses API" +
        (requestID.map { " • x-request-id: \($0)" } ?? "")
    }
}

enum OpenAIAPIErrorCategory: Sendable, Equatable {
    case authentication, authorization, rateLimit, quota, modelUnavailable, serviceUnavailable, invalidResponse, network, tls, other
}

struct OpenAIAPIError: LocalizedError, Sendable {
    let category: OpenAIAPIErrorCategory
    let statusCode: Int?
    let apiMessage: String?
    let apiType: String?
    let apiCode: String?
    let requestID: String?

    var errorDescription: String? {
        var details = ["category=\(category)"]
        if let statusCode { details.append("http=\(statusCode)") }
        if let apiType { details.append("type=\(apiType)") }
        if let apiCode { details.append("code=\(apiCode)") }
        if let requestID { details.append("request_id=\(requestID)") }
        if let apiMessage { details.append("api_message=\(apiMessage)") }
        return details.joined(separator: ", ")
    }

    var userMessage: String {
        switch category {
        case .authentication: "A credencial não foi aceita pela OpenAI."
        case .authorization: "A Service Account não tem permissão para usar a OpenAI neste projeto."
        case .rateLimit: "O limite de requisições da OpenAI foi atingido. Tente novamente em instantes."
        case .quota: "A cota do projeto OpenAI está indisponível ou esgotada."
        case .modelUnavailable: "O modelo necessário não está disponível para este projeto."
        case .serviceUnavailable: "A OpenAI está temporariamente indisponível."
        case .network: "Não foi possível conectar à OpenAI. Verifique a conexão de rede."
        case .tls: "Não foi possível estabelecer uma conexão segura com a OpenAI."
        case .invalidResponse, .other: "Não foi possível confirmar a conexão com a OpenAI."
        }
    }

    var diagnosticMessage: String {
        let status = statusCode.map { "HTTP \($0)" } ?? "Sem status HTTP"
        let message = apiMessage ?? "Sem mensagem retornada pela OpenAI"
        return "\(status) • \(message)" + (requestID.map { " • x-request-id: \($0)" } ?? "")
    }

    static func response(statusCode: Int, data: Data, requestID: String?) -> Self {
        let api = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data).error
        let code = sanitizedIdentifier(api?.code?.stringValue)
        let type = sanitizedIdentifier(api?.type)
        let category: OpenAIAPIErrorCategory
        switch statusCode {
        case 401: category = .authentication
        case 403: category = .authorization
        case 404 where code.map({ ["model_not_found", "deployment_not_found", "deploymentnotfound", "resourcenotfound",
                                  "model_not_supported", "unsupported_model"].contains($0) }) == true: category = .modelUnavailable
        case 429 where code == "insufficient_quota": category = .quota
        case 429: category = .rateLimit
        case 500...599: category = .serviceUnavailable
        default: category = code == "model_not_found" ? .modelUnavailable : .other
        }
        return Self(category: category, statusCode: statusCode, apiMessage: safeMessage(for: category),
                    apiType: type, apiCode: code, requestID: sanitizedIdentifier(requestID))
    }

    private static func safeMessage(for category: OpenAIAPIErrorCategory) -> String {
        switch category {
        case .authentication: "Authentication failed."
        case .authorization: "Authorization failed."
        case .rateLimit: "Rate limit reached."
        case .quota: "Quota unavailable."
        case .modelUnavailable: "Model unavailable."
        case .serviceUnavailable: "Service temporarily unavailable."
        case .invalidResponse: "Invalid API response."
        case .network: "Network request failed."
        case .tls: "Secure connection failed."
        case .other: "API request failed."
        }
    }

    static func sanitizedIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
              }) else { return nil }
        return value
    }
}

actor OpenAICredentialValidator {
    static let validationModel = PavlakAIConfiguration.currentModelID
    static let validationInput = "Responda somente com OK."
    static let validationMaxOutputTokens = 32

    private let client: OpenAIClient
    private let responsesEndpoint: URL
    private let model: String
    private let authentication: OpenAIRequestFactory.Authentication
    private let configuration: PavlakAIConfiguration

    init(session: URLSession = .shared,
         responsesEndpoint: URL? = nil,
         model: String? = nil,
         configuration: PavlakAIConfiguration = .openAIDefault,
         isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly }) {
        self.client = OpenAIClient(session: session, isLocalOnly: isLocalOnly)
        self.responsesEndpoint = responsesEndpoint ?? configuration.responsesURL ?? URL(string: "https://api.openai.com/v1/responses")!
        self.model = model ?? configuration.effectiveModelName ?? OpenAICredentialValidator.validationModel
        self.authentication = configuration.usesBearerAuthentication ? .bearer : .apiKey
        self.configuration = configuration
    }

    func validate(_ credential: String) async throws -> OpenAICredentialValidation {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIKeyStoreError.emptyCredential }
        guard configuration.validationError() == nil else {
            throw OpenAIAPIError(category: .invalidResponse, statusCode: nil, apiMessage: nil,
                                 apiType: "invalid_configuration", apiCode: nil, requestID: nil)
        }
        let body = try JSONEncoder().encode(ValidationRequestBody(
            model: model,
            input: Self.validationInput,
            store: false,
            maxOutputTokens: Self.validationMaxOutputTokens
        ))
        let request = OpenAIRequestFactory.make(
            url: responsesEndpoint,
            method: .post,
            apiKey: trimmed,
            body: body,
            timeout: 30,
            authentication: authentication
        )
        let (data, response) = try await client.data(for: request)
        let result = try decode(ValidationResponse.self, data: data, response: response)
        guard result.object == "response", !result.id.isEmpty,
              result.status == "completed" else {
            throw OpenAIAPIError(
                category: .invalidResponse,
                statusCode: response.statusCode,
                apiMessage: nil,
                apiType: nil,
                apiCode: nil,
                requestID: OpenAIAPIError.sanitizedIdentifier(response.value(forHTTPHeaderField: "x-request-id"))
            )
        }
        return OpenAICredentialValidation(
            responseID: result.id,
            statusCode: response.statusCode,
            requestID: OpenAIAPIError.sanitizedIdentifier(response.value(forHTTPHeaderField: "x-request-id"))
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: HTTPURLResponse) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            throw OpenAIAPIError(
                category: .invalidResponse,
                statusCode: response.statusCode,
                apiMessage: nil,
                apiType: nil,
                apiCode: nil,
                requestID: OpenAIAPIError.sanitizedIdentifier(response.value(forHTTPHeaderField: "x-request-id"))
            )
        }
    }
}

private struct ValidationRequestBody: Encodable {
    let model: String
    let input: String
    let store: Bool
    let maxOutputTokens: Int
    enum CodingKeys: String, CodingKey {
        case model, input, store
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct ValidationResponse: Decodable {
    let id: String
    let object: String
    let status: String
}

struct OpenAIErrorEnvelope: Decodable { let error: OpenAIErrorBody }
struct OpenAIErrorBody: Decodable { let message: String; let type: String?; let code: OpenAIErrorCode? }
enum OpenAIErrorCode: Decodable {
    case string(String), number(Int)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .number(try container.decode(Int.self)) }
    }
    var stringValue: String { switch self { case .string(let value): value; case .number(let value): String(value) } }
}

import Foundation

struct OpenAIToolDefinition: Encodable, Sendable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONValue
    let strict = true
}

struct OpenAIFunctionCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
}

struct OpenAIResponseTurn: Sendable {
    let id: String
    let text: String?
    let calls: [OpenAIFunctionCall]
}

struct OpenAIConversation: Decodable, Sendable { let id: String }

struct OpenAIFunctionOutput: Encodable, Sendable {
    let type = "function_call_output"
    let callID: String
    let output: String
    enum CodingKeys: String, CodingKey { case type; case callID = "call_id"; case output }
}

enum JSONValue: Codable, Sendable {
    case string(String), bool(Bool), number(Double), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

actor OpenAIResponsesClient {
    private let client: OpenAIClient
    private let isLocalOnly: @Sendable () -> Bool
    private let model: String
    private let configurationProvider: @Sendable () -> PavlakAIConfiguration
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    init(
        model: String = "gpt-5",
        session: URLSession = .shared,
        configurationProvider: @escaping @Sendable () -> PavlakAIConfiguration = { PavlakAIConfiguration.openAIDefault },
        isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly }
    ) {
        self.model = model
        self.configurationProvider = configurationProvider
        self.isLocalOnly = isLocalOnly
        self.client = OpenAIClient(session: session, isLocalOnly: isLocalOnly)
    }

    private var configuredModel: String { configurationProvider().effectiveModelName ?? model }

    func createConversation() async throws -> String {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        guard OpenAIKeyStore.hasValidatedKey, let key = OpenAIKeyStore.load() else { throw OpenAIClientError.missingKey }
        let request = OpenAIRequestFactory.make(
            url: URL(string: "https://api.openai.com/v1/conversations")!, method: .post,
            apiKey: key, body: Data("{}".utf8)
        )
        let (data, _) = try await client.data(for: request)
        return try JSONDecoder().decode(OpenAIConversation.self, from: data).id
    }

    func stream(input: JSONValue, conversationID: String, instructions: String,
                tools: [OpenAIToolDefinition], onText: @escaping @Sendable (String) async -> Void) async throws -> OpenAIResponseTurn {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        guard OpenAIKeyStore.hasValidatedKey, let key = OpenAIKeyStore.load() else { throw OpenAIClientError.missingKey }
        let body = try JSONEncoder().encode(StreamingRequestBody(
            model: configuredModel, instructions: instructions, input: input, tools: tools,
            conversation: .init(id: conversationID)
        ))
        let request = OpenAIRequestFactory.make(
            url: endpoint, method: .post, apiKey: key, body: body,
            accept: "text/event-stream", timeout: 120
        )

        let (bytes, _) = try await client.bytes(for: request)

        var calls: [OpenAIFunctionCall] = []
        var responseID = ""
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ResponseStreamEvent.self, from: data) else { continue }
            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta { text += delta; await onText(delta) }
            case "response.output_item.done":
                if let item = event.item, item.type == "function_call",
                   let callID = item.callID, let name = item.name, let arguments = item.arguments {
                    calls.append(.init(callID: callID, name: name, arguments: arguments))
                }
            case "response.completed": responseID = event.response?.id ?? responseID
            case "response.failed", "error":
                throw OpenAIClientError.api(event.response?.error?.message ?? event.error?.message ?? "Falha no streaming.")
            default: break
            }
        }
        return OpenAIResponseTurn(id: responseID, text: text.isEmpty ? nil : text, calls: calls)
    }

    func start(input: String, instructions: String, tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        try await request(body: RequestBody(model: configuredModel, instructions: instructions, input: .text(input), tools: tools, previousResponseID: nil))
    }

    func continueTurn(previousResponseID: String, outputs: [OpenAIFunctionOutput], instructions: String, tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        try await request(body: RequestBody(model: configuredModel, instructions: instructions, input: .outputs(outputs), tools: tools, previousResponseID: previousResponseID))
    }

    private func request(body: RequestBody) async throws -> OpenAIResponseTurn {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        guard OpenAIKeyStore.hasValidatedKey, let key = OpenAIKeyStore.load() else { throw OpenAIClientError.missingKey }
        let request = OpenAIRequestFactory.make(
            url: endpoint, method: .post, apiKey: key,
            body: try JSONEncoder().encode(body), timeout: 90
        )
        let (data, _) = try await client.data(for: request)
        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        let calls = decoded.output.compactMap { item -> OpenAIFunctionCall? in
            guard item.type == "function_call", let callID = item.callID, let name = item.name, let arguments = item.arguments else { return nil }
            return OpenAIFunctionCall(callID: callID, name: name, arguments: arguments)
        }
        let text = decoded.output.compactMap(\.content).flatMap { $0 }.first(where: { $0.type == "output_text" })?.text
        return OpenAIResponseTurn(id: decoded.id, text: text, calls: calls)
    }
}

private struct StreamingRequestBody: Encodable {
    struct ConversationReference: Encodable { let id: String }
    let model: String
    let instructions: String
    let input: JSONValue
    let tools: [OpenAIToolDefinition]
    let conversation: ConversationReference
    let stream = true
    let store = true
}

private struct ResponseStreamEvent: Decodable {
    struct Item: Decodable {
        let type: String
        let callID: String?
        let name: String?
        let arguments: String?
        enum CodingKeys: String, CodingKey { case type; case callID = "call_id"; case name, arguments }
    }
    struct Response: Decodable {
        struct Failure: Decodable { let message: String? }
        let id: String?
        let error: Failure?
    }
    struct EventError: Decodable { let message: String? }
    let type: String
    let delta: String?
    let item: Item?
    let response: Response?
    let error: EventError?
}

private struct RequestBody: Encodable {
    let model: String
    let instructions: String
    let input: RequestInput
    let tools: [OpenAIToolDefinition]
    let previousResponseID: String?
    let store = true
    enum CodingKeys: String, CodingKey { case model, instructions, input, tools, store; case previousResponseID = "previous_response_id" }
}

private enum RequestInput: Encodable {
    case text(String), outputs([OpenAIFunctionOutput])
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .text(let value): try container.encode(value); case .outputs(let value): try container.encode(value) }
    }
}

private struct ResponseEnvelope: Decodable {
    let id: String
    let output: [OutputItem]
    struct OutputItem: Decodable {
        let type: String
        let callID: String?
        let name: String?
        let arguments: String?
        let content: [Content]?
        enum CodingKeys: String, CodingKey { case type; case callID = "call_id"; case name, arguments, content }
    }
    struct Content: Decodable { let type: String; let text: String? }
}

enum OpenAIClientError: LocalizedError {
    case missingKey, invalidConfiguration, invalidResponse, api(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: "Configure a conexão OpenAI para usar o raciocínio em nuvem."
        case .invalidConfiguration: "A configuração do provider remoto é inválida."
        case .invalidResponse: "A OpenAI retornou uma resposta inválida."
        case .api(let message): "A OpenAI não concluiu a solicitação: \(message)"
        }
    }
}

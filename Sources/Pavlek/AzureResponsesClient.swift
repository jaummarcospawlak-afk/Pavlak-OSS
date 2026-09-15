import Foundation

protocol PavlakResponsesClient: Sendable {
    func createConversation() async throws -> String
    func stream(input: JSONValue, conversationID: String, instructions: String,
                tools: [OpenAIToolDefinition], onText: @escaping @Sendable (String) async -> Void) async throws -> OpenAIResponseTurn
    func start(input: String, instructions: String, tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn
    func continueTurn(previousResponseID: String, outputs: [OpenAIFunctionOutput], instructions: String,
                      tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn
}

extension OpenAIResponsesClient: PavlakResponsesClient { }

/// Routes the configured remote provider without ever falling back from Azure
/// to a legacy OpenAI key or endpoint.
actor PavlakResponsesClientRouter: PavlakResponsesClient {
    private let configurationProvider: @Sendable () -> PavlakAIConfiguration
    private let openAI: OpenAIResponsesClient
    private let azure: AzureResponsesClient

    init(configurationProvider: @escaping @Sendable () -> PavlakAIConfiguration = { PavlakAIConfigurationStore.load() },
         session: URLSession = CloudHTTP.session, budget: CloudBudget = .shared,
         isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly }) {
        self.configurationProvider = configurationProvider
        self.openAI = OpenAIResponsesClient(session: session, configurationProvider: configurationProvider, isLocalOnly: isLocalOnly)
        self.azure = AzureResponsesClient(configurationProvider: configurationProvider, session: session, budget: budget, isLocalOnly: isLocalOnly)
    }

    func createConversation() async throws -> String {
        if configurationProvider().provider == .azureOpenAI { return try await azure.createConversation() }
        return try await openAI.createConversation()
    }

    func stream(input: JSONValue, conversationID: String, instructions: String,
                tools: [OpenAIToolDefinition], onText: @escaping @Sendable (String) async -> Void) async throws -> OpenAIResponseTurn {
        if configurationProvider().provider == .azureOpenAI {
            return try await azure.stream(input: input, conversationID: conversationID, instructions: instructions, tools: tools, onText: onText)
        }
        return try await openAI.stream(input: input, conversationID: conversationID, instructions: instructions, tools: tools, onText: onText)
    }

    func start(input: String, instructions: String, tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        if configurationProvider().provider == .azureOpenAI {
            return try await azure.start(input: input, instructions: instructions, tools: tools)
        }
        return try await openAI.start(input: input, instructions: instructions, tools: tools)
    }

    func continueTurn(previousResponseID: String, outputs: [OpenAIFunctionOutput], instructions: String,
                      tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        if configurationProvider().provider == .azureOpenAI {
            return try await azure.continueTurn(previousResponseID: previousResponseID, outputs: outputs, instructions: instructions, tools: tools)
        }
        return try await openAI.continueTurn(previousResponseID: previousResponseID, outputs: outputs, instructions: instructions, tools: tools)
    }
}

/// Azure Responses API transport. It uses the GA `/openai/v1` contract with
/// API-key authentication and carries the conversation in memory with store=false.
actor AzureResponsesClient: PavlakResponsesClient {
    private struct State { var input: [JSONValue] = [] }

    private let configurationProvider: @Sendable () -> PavlakAIConfiguration
    private let client: OpenAIClient
    private let budget: CloudBudget
    private let isLocalOnly: @Sendable () -> Bool
    private let credentialProvider: (@Sendable (PavlakAIConfiguration) async -> String?)?
    private var states: [String: State] = [:]
    private var stateByResponseID: [String: String] = [:]

    init(configurationProvider: @escaping @Sendable () -> PavlakAIConfiguration = { PavlakAIConfigurationStore.load() },
         session: URLSession = CloudHTTP.session, budget: CloudBudget = .shared,
         isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly },
         credentialProvider: (@Sendable (PavlakAIConfiguration) async -> String?)? = nil) {
        self.configurationProvider = configurationProvider
        self.client = OpenAIClient(session: session, isLocalOnly: isLocalOnly)
        self.budget = budget
        self.isLocalOnly = isLocalOnly
        self.credentialProvider = credentialProvider
    }

    func createConversation() async throws -> String {
        guard !isLocalOnly(), configuration().provider == .azureOpenAI else { throw OpenAIClientError.invalidConfiguration }
        let id = UUID().uuidString
        states[id] = .init()
        return id
    }

    func stream(input: JSONValue, conversationID: String, instructions: String,
                tools: [OpenAIToolDefinition], onText: @escaping @Sendable (String) async -> Void) async throws -> OpenAIResponseTurn {
        let configuration = try readyConfiguration()
        let key = try await credential(for: configuration)
        let previousState = states[conversationID] ?? .init()
        var state = previousState
        let limits = budget.limits
        state.input.append(contentsOf: Self.inputItems(for: input))
        let body = try JSONEncoder().encode(AzureStreamBody(
            model: try modelName(configuration), instructions: instructions, input: state.input, tools: tools,
            max_output_tokens: limits.outputTokens
        ))
        try budget.reserve(inputBytes: body.count)
        let request = try makeRequest(body: body, configuration: configuration, credential: key, streaming: true)
        states[conversationID] = state
        do {
            let (bytes, _) = try await client.bytes(for: request)
            let result = try await parse(bytes: bytes, stateID: conversationID, onText: onText)
            budget.record(input: body.count, output: result.text?.count ?? 0)
            return result
        } catch {
            states[conversationID] = previousState
            throw error
        }
    }

    func start(input: String, instructions: String, tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        let configuration = try readyConfiguration()
        let key = try await credential(for: configuration)
        let stateID = UUID().uuidString
        states[stateID] = .init()
        return try await request(newItems: Self.inputItems(for: .string(input)), stateID: stateID,
                                 instructions: instructions, tools: tools, configuration: configuration, credential: key)
    }

    func continueTurn(previousResponseID: String, outputs: [OpenAIFunctionOutput], instructions: String,
                      tools: [OpenAIToolDefinition]) async throws -> OpenAIResponseTurn {
        let configuration = try readyConfiguration()
        let key = try await credential(for: configuration)
        guard let stateID = stateByResponseID[previousResponseID] else { throw OpenAIClientError.invalidResponse }
        let items = outputs.map { JSONValue.object([
            "type": .string("function_call_output"),
            "call_id": .string($0.callID),
            "output": .string(String($0.output.prefix(20_000)))
        ]) }
        return try await request(newItems: items, stateID: stateID, instructions: instructions, tools: tools,
                                 configuration: configuration, credential: key)
    }

    private func configuration() -> PavlakAIConfiguration { configurationProvider() }

    private func readyConfiguration() throws -> PavlakAIConfiguration {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        let value = configuration()
        guard value.provider == .azureOpenAI, value.validationError() == nil else { throw OpenAIClientError.invalidConfiguration }
        return value
    }

    private func modelName(_ configuration: PavlakAIConfiguration) throws -> String {
        guard let value = configuration.effectiveModelName else { throw OpenAIClientError.invalidConfiguration }
        return value
    }

    private func credential(for configuration: PavlakAIConfiguration) async throws -> String {
        let value = if let credentialProvider {
            await credentialProvider(configuration)
        } else {
            await CloudCredentialStore.load(configuration: configuration)
        }
        guard let value, !value.isEmpty else {
            throw OpenAIClientError.missingKey
        }
        return value
    }

    private func makeRequest(body: Data, configuration: PavlakAIConfiguration, credential: String,
                             streaming: Bool) throws -> URLRequest {
        guard let url = configuration.responsesURL else { throw OpenAIClientError.invalidConfiguration }
        return OpenAIRequestFactory.make(url: url, method: .post, apiKey: credential, body: body,
                                         accept: streaming ? "text/event-stream" : "application/json",
                                         timeout: streaming ? 120 : 90, authentication: .apiKey)
    }

    private func request(newItems: [JSONValue], stateID: String, instructions: String,
                         tools: [OpenAIToolDefinition], configuration: PavlakAIConfiguration,
                         credential: String) async throws -> OpenAIResponseTurn {
        var state = states[stateID] ?? .init()
        let limits = budget.limits
        state.input.append(contentsOf: newItems)
        let body = try JSONEncoder().encode(AzureBody(
            model: try modelName(configuration), instructions: instructions, input: state.input, tools: tools,
            max_output_tokens: limits.outputTokens
        ))
        try budget.reserve(inputBytes: body.count)
        let request = try makeRequest(body: body, configuration: configuration, credential: credential, streaming: false)
        let (data, _) = try await client.data(for: request)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty else { throw OpenAIClientError.invalidResponse }
        let output = object["output"]?.arrayValue ?? []
        let result = Self.turn(id: id, output: output)
        guard !result.calls.isEmpty || result.text != nil else { throw OpenAIClientError.invalidResponse }
        state.input.append(contentsOf: output)
        states[stateID] = state
        stateByResponseID[id] = stateID
        budget.record(input: body.count, output: result.text?.count ?? 0)
        return result
    }

    private func parse(bytes: URLSession.AsyncBytes, stateID: String,
                       onText: @escaping @Sendable (String) async -> Void) async throws -> OpenAIResponseTurn {
        var output: [JSONValue] = []
        var text = ""
        var responseID = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONDecoder().decode(AzureEvent.self, from: data) else { continue }
            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta { text += delta; await onText(delta) }
            case "response.output_item.done":
                if let item = event.item { output.append(item) }
            case "response.completed":
                responseID = event.response?.id ?? responseID
                if output.isEmpty { output = event.response?.output ?? [] }
            case "response.failed", "error":
                throw OpenAIClientError.api(event.response?.error?.message ?? event.error?.message ?? "Falha no streaming.")
            default: break
            }
        }
        var state = states[stateID] ?? .init()
        state.input.append(contentsOf: output)
        states[stateID] = state
        if !responseID.isEmpty { stateByResponseID[responseID] = stateID }
        let result = Self.turn(id: responseID, output: output)
        let final = Self.initTurn(id: result.id, text: text.isEmpty ? result.text : text, calls: result.calls)
        guard !final.id.isEmpty, !final.calls.isEmpty || final.text != nil else { throw OpenAIClientError.invalidResponse }
        return final
    }

    private static func initTurn(id: String, text: String?, calls: [OpenAIFunctionCall]) -> OpenAIResponseTurn {
        .init(id: id, text: text.map { String($0.prefix(8_000)) }, calls: calls)
    }

    private static func inputItems(for input: JSONValue) -> [JSONValue] {
        switch input {
        case .string(let value):
            [.object([
                "type": .string("message"), "role": .string("user"),
                "content": .array([.object(["type": .string("input_text"), "text": .string(value)])])
            ])]
        case .array(let value): value
        default: [input]
        }
    }

    private static func functionCall(from item: JSONValue) -> OpenAIFunctionCall? {
        guard let object = item.objectValue, object["type"]?.stringValue == "function_call",
              let callID = object["call_id"]?.stringValue, let name = object["name"]?.stringValue,
              let arguments = object["arguments"]?.stringValue else { return nil }
        return .init(callID: callID, name: name, arguments: arguments)
    }

    private static func turn(id: String, output: [JSONValue]) -> OpenAIResponseTurn {
        let calls = output.compactMap(functionCall(from:))
        let text = output.compactMap { item -> String? in
            guard let object = item.objectValue, object["type"]?.stringValue == "message" else { return nil }
            return object["content"]?.arrayValue?.compactMap { block in
                guard block.objectValue?["type"]?.stringValue == "output_text" else { return nil }
                return block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(id: id, text: text.isEmpty ? nil : text, calls: calls)
    }
}

private struct AzureBody: Encodable {
    let model: String
    let instructions: String
    let input: [JSONValue]
    let tools: [OpenAIToolDefinition]
    let max_output_tokens: Int
    let include = ["reasoning.encrypted_content"]
    let store = false
}

private struct AzureStreamBody: Encodable {
    let model: String
    let instructions: String
    let input: [JSONValue]
    let tools: [OpenAIToolDefinition]
    let max_output_tokens: Int
    let include = ["reasoning.encrypted_content"]
    let stream = true
    let store = false
}

private struct AzureEvent: Decodable {
    struct Failure: Decodable { let message: String? }
    struct Response: Decodable { let id: String?; let output: [JSONValue]?; let error: Failure? }
    struct ErrorBody: Decodable { let message: String? }
    let type: String
    let delta: String?
    let item: JSONValue?
    let response: Response?
    let error: ErrorBody?
}

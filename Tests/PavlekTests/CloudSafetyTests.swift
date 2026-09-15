import XCTest
@testable import Pavlek

final class CloudSafetyTests: XCTestCase {
    func testBudgetBlocksUntilUserSetsAValidVoiceEstimate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PavlekTests.\(UUID().uuidString)"))
        let budget = CloudBudget(defaults: defaults)

        XCTAssertThrowsError(try budget.reserve(inputBytes: 0, voice: true)) { error in
            XCTAssertEqual(error as? CloudFailure, .budget)
        }

        var limits = CloudLimits()
        limits.dailyUSD = 0.01
        limits.voiceUSDPerMinute = 0.01
        limits.voiceSeconds = 10
        try budget.save(limits)
        XCTAssertNoThrow(try budget.reserve(inputBytes: 0, voice: true))
    }

    func testPortalMonitoringModeDoesNotRequireLocalDollarEstimates() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PavlekTests.\(UUID().uuidString)"))
        let budget = CloudBudget(defaults: defaults)
        let limits = CloudLimits(localBudgetEnabled: false)
        try budget.save(limits)

        XCTAssertNoThrow(try budget.reserve(inputBytes: 0))
        XCTAssertNoThrow(try budget.reserve(inputBytes: 0, voice: true))
        XCTAssertEqual(budget.summary.requests, 2)
        XCTAssertEqual(budget.summary.reservedUSD, 0)
    }

    func testLegacyLimitsRemainProtectedWhenModeFieldIsMissing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PavlekTests.\(UUID().uuidString)"))
        defaults.set(Data(#"{"dailyUSD":0.01,"textUSDPerMillionTokens":1,"voiceUSDPerMinute":1,"outputTokens":128,"cycles":2,"voiceSeconds":10}"#.utf8), forKey: "Pavlek.cloud.limits.v1")
        let budget = CloudBudget(defaults: defaults)

        XCTAssertTrue(budget.limits.localBudgetEnabled)
        XCTAssertNoThrow(try budget.reserve(inputBytes: 0))
    }

    #if os(macOS)
    func testAzureTextTransportUsesLiteralDeploymentApiKeyAndOutputLimit() async throws {
        let configuration = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                                   deploymentName: "text-deployment", baseURL: URL(string: "https://resource.openai.azure.com/openai/v1/")!,
                                                   realtimeDeploymentName: "gpt-realtime-mini")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PavlekTests.\(UUID().uuidString)"))
        let budget = CloudBudget(defaults: defaults)
        var limits = CloudLimits(); limits.dailyUSD = 0.05; limits.textUSDPerMillionTokens = 1; limits.outputTokens = 128
        try budget.save(limits)
        let recorder = AzureTestRequestRecorder()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AzureTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        AzureTestURLProtocol.handler = { request in
            recorder.record(request)
            return .init(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Content-Type": "application/json"])!,
                         data: Data(#"{"id":"resp_fixture","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8))
        }
        defer { AzureTestURLProtocol.handler = nil }

        let client = AzureResponsesClient(configurationProvider: { configuration }, session: session, budget: budget,
                                          isLocalOnly: { false }, credentialProvider: { _ in "synthetic-token" })
        let result = try await client.start(input: "Olá", instructions: "Responda curto", tools: [])
        XCTAssertEqual(result.text, "OK")
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://resource.openai.azure.com/openai/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.body)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "text-deployment")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 128)
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testAzureBudgetBlocksBeforeTransport() async throws {
        let configuration = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                                   deploymentName: "text-deployment", baseURL: URL(string: "https://resource.openai.azure.com/openai/v1/")!)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PavlekTests.\(UUID().uuidString)"))
        let recorder = AzureTestRequestRecorder()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AzureTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        AzureTestURLProtocol.handler = { request in
            recorder.record(request)
            return .init(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, data: Data())
        }
        defer { AzureTestURLProtocol.handler = nil }

        let client = AzureResponsesClient(configurationProvider: { configuration }, session: session,
                                          budget: CloudBudget(defaults: defaults), isLocalOnly: { false },
                                          credentialProvider: { _ in "synthetic-token" })
        do {
            _ = try await client.start(input: "não enviar", instructions: "", tools: [])
            XCTFail("O orçamento padrão deve bloquear a chamada Azure")
        } catch { XCTAssertEqual(error as? CloudFailure, .budget) }
        XCTAssertNil(recorder.request, "Nenhum transporte deve ser iniciado antes do teto")
    }

    func testRealtimeAudioAndTranscriptEventsAreDecodedWithoutNetwork() throws {
        let configuration = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                                   deploymentName: "text-deployment", baseURL: URL(string: "https://resource.openai.azure.com/openai/v1/")!,
                                                   realtimeDeploymentName: "gpt-realtime-mini")
        let request = try AzureRealtimeClient.makeRealtimeRequest(configuration: configuration, credential: "synthetic-token")
        XCTAssertEqual(request.url?.absoluteString, "wss://resource.openai.azure.com/openai/v1/realtime?model=gpt-realtime-mini")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let audio = Data("PCM fixture".utf8).base64EncodedString()
        let data = Data("{\"type\":\"response.audio.delta\",\"delta\":\"\(audio)\"}".utf8)
        let event = try XCTUnwrap(AzureRealtimeEvent.decode(data))
        XCTAssertEqual(event.type, "response.audio.delta")
        XCTAssertEqual(event.audio, Data("PCM fixture".utf8))

        let transcript = try XCTUnwrap(AzureRealtimeEvent.decode(Data(#"{"type":"response.audio_transcript.delta","delta":"Olá"}"#.utf8)))
        XCTAssertEqual(transcript.textDelta, "Olá")

        let inputTranscript = try XCTUnwrap(AzureRealtimeEvent.decode(Data(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"teste de voz"}"#.utf8)))
        XCTAssertEqual(inputTranscript.inputTranscript, "teste de voz")

        let sessionData = try JSONEncoder().encode(AzureRealtimeClient.makeSessionUpdate(instructions: "Responda curto"))
        let session = try XCTUnwrap(JSONSerialization.jsonObject(with: sessionData) as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "session.update")
        let settings = try XCTUnwrap(session["session"] as? [String: Any])
        XCTAssertEqual(settings["type"] as? String, "realtime")
        XCTAssertEqual(settings["output_modalities"] as? [String], ["audio"])
        let audioSettings = try XCTUnwrap(settings["audio"] as? [String: Any])
        let inputSettings = try XCTUnwrap(audioSettings["input"] as? [String: Any])
        let inputFormat = try XCTUnwrap(inputSettings["format"] as? [String: Any])
        XCTAssertEqual(inputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(inputFormat["rate"] as? Int, 24_000)
        XCTAssertEqual((inputSettings["transcription"] as? [String: Any])?["model"] as? String, "whisper-1")
        XCTAssertTrue(inputSettings["turn_detection"] is NSNull)
        let outputSettings = try XCTUnwrap(audioSettings["output"] as? [String: Any])
        XCTAssertEqual(outputSettings["voice"] as? String, "alloy")
    }
    #endif
}

#if os(macOS)
private final class AzureTestRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?
    var request: URLRequest? { lock.withLock { storedRequest } }
    var body: Data? { lock.withLock { storedBody } }
    func record(_ request: URLRequest) {
        let body: Data?
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var value = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                value.append(buffer, count: count)
            }
            body = value
        } else {
            body = nil
        }
        lock.withLock { storedRequest = request; storedBody = body }
    }
}

private final class AzureTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Result { let response: HTTPURLResponse; let data: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: ((URLRequest) throws -> Result)?
    static var handler: ((URLRequest) throws -> Result)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let result = try handler(request)
            client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
#endif

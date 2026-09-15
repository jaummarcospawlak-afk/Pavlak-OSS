import XCTest
@testable import Pavlek

final class OpenAICredentialValidatorTests: XCTestCase {
    func testRedactsCredentialEchoFromAuthenticationError() {
        let data = Data(#"{"error":{"message":"Incorrect API key provided: secret-value","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
        let error = OpenAIAPIError.response(statusCode: 401, data: data, requestID: nil)

        XCTAssertEqual(error.apiMessage, "Authentication failed.")
        XCTAssertFalse(error.diagnosticMessage.contains("secret-value"))
    }

    func testPreservesStructuredAuthenticationFailureAndRequestID() throws {
        let data = Data(#"{"error":{"message":"Invalid credential","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
        let error = OpenAIAPIError.response(statusCode: 401, data: data, requestID: "req_test")

        XCTAssertEqual(error.category, .authentication)
        XCTAssertEqual(error.statusCode, 401)
        XCTAssertEqual(error.apiMessage, "Authentication failed.")
        XCTAssertEqual(error.apiType, "invalid_request_error")
        XCTAssertEqual(error.apiCode, "invalid_api_key")
        XCTAssertEqual(error.requestID, "req_test")
        XCTAssertFalse(error.userMessage.contains("Invalid credential"))
    }

    func testSeparatesAuthorizationQuotaRateLimitAndModelAvailability() {
        XCTAssertEqual(apiError(status: 401, code: "invalid_api_key").category, .authentication)
        XCTAssertEqual(apiError(status: 403, code: "project_permission_denied").category, .authorization)
        XCTAssertEqual(apiError(status: 429, code: "insufficient_quota").category, .quota)
        XCTAssertEqual(apiError(status: 429, code: "rate_limit_exceeded").category, .rateLimit)
        XCTAssertEqual(apiError(status: 404, code: "model_not_found").category, .modelUnavailable)
        XCTAssertEqual(apiError(status: 503, code: "server_error").category, .serviceUnavailable)
    }

    func testAcceptsOpaqueCodesThatAreNotStrings() {
        let data = Data(#"{"error":{"message":"Rejected","type":"request_error","code":42}}"#.utf8)
        XCTAssertEqual(OpenAIAPIError.response(statusCode: 400, data: data, requestID: nil).apiCode, "42")
    }

    func testValidationUsesMinimalPrivateResponsesPOST() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return Self.httpResult(
                for: request,
                status: 200,
                requestID: "req_validation",
                body: #"{"id":"resp_validation","object":"response","status":"completed"}"#
            )
        }
        defer { MockURLProtocol.handler = nil }

        let endpoint = URL(string: "https://api.openai.com/v1/responses")!
        let validator = OpenAICredentialValidator(
            session: makeMockSession(),
            responsesEndpoint: endpoint,
            isLocalOnly: { false }
        )
        let validation = try await validator.validate("  opaque-test-value\n")

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-test-value")
        XCTAssertFalse(OpenAIRequestFactory.lastDiagnostics?.safeDescription.contains("opaque-test-value") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(recorder.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["model", "input", "store", "max_output_tokens"]))
        XCTAssertEqual(json["model"] as? String, "gpt-5")
        XCTAssertEqual(json["input"] as? String, OpenAICredentialValidator.validationInput)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["max_output_tokens"] as? Int, OpenAICredentialValidator.validationMaxOutputTokens)
        XCTAssertEqual(validation.responseID, "resp_validation")
        XCTAssertEqual(validation.statusCode, 200)
        XCTAssertEqual(validation.requestID, "req_validation")
    }

    func testValidationRejectsSuccessfulHTTPWithoutValidResponseObject() async throws {
        MockURLProtocol.handler = { request in
            Self.httpResult(
                for: request,
                status: 200,
                requestID: "req_invalid",
                body: #"{"id":"","object":"list","status":"completed"}"#
            )
        }
        defer { MockURLProtocol.handler = nil }
        let validator = OpenAICredentialValidator(session: makeMockSession(), isLocalOnly: { false })

        do {
            _ = try await validator.validate("opaque-test-value")
            XCTFail("A resposta inválida não pode validar a credencial.")
        } catch let error as OpenAIAPIError {
            XCTAssertEqual(error.category, .invalidResponse)
            XCTAssertEqual(error.statusCode, 200)
        }
    }

    func testValidationRejectsMissingCredentialBeforeNetworkRequest() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return Self.httpResult(for: request, status: 500, body: "{}")
        }
        defer { MockURLProtocol.handler = nil }
        let validator = OpenAICredentialValidator(session: makeMockSession(), isLocalOnly: { false })

        do {
            _ = try await validator.validate(" \n ")
            XCTFail("A credencial ausente deve ser recusada localmente.")
        } catch let error as OpenAIKeyStoreError {
            guard case .emptyCredential = error else { return XCTFail("Erro local incorreto: \(error)") }
        }
        XCTAssertNil(recorder.request)
    }

    func testValidationPropagatesResponsesAPIErrorClassification() async throws {
        MockURLProtocol.handler = { request in
            Self.httpResult(
                for: request,
                status: 429,
                requestID: "req_quota",
                body: #"{"error":{"message":"raw message must not escape","type":"api_error","code":"insufficient_quota"}}"#
            )
        }
        defer { MockURLProtocol.handler = nil }
        let validator = OpenAICredentialValidator(session: makeMockSession(), isLocalOnly: { false })

        do {
            _ = try await validator.validate("opaque-test-value")
            XCTFail("A quota indisponível não pode validar a credencial.")
        } catch let error as OpenAIAPIError {
            XCTAssertEqual(error.category, .quota)
            XCTAssertFalse(error.diagnosticMessage.contains("raw message"))
            XCTAssertEqual(error.requestID, "req_quota")
        }
    }

    func testNetworkAndTLSMessagesAreDistinct() {
        let network = OpenAIAPIError(category: .network, statusCode: nil, apiMessage: "offline", apiType: "url_error", apiCode: "-1009", requestID: nil)
        let tls = OpenAIAPIError(category: .tls, statusCode: nil, apiMessage: "certificate", apiType: "url_error", apiCode: "-1200", requestID: nil)
        XCTAssertNotEqual(network.userMessage, tls.userMessage)
        XCTAssertFalse(network.userMessage.contains("offline"))
        XCTAssertFalse(tls.userMessage.contains("certificate"))
    }

    func testLocalOnlyBlocksConfiguredCredentialBeforeAnyNetworkSend() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return Self.httpResult(for: request, status: 200, body: #"{"id":"must_not_run","object":"response","status":"completed"}"#)
        }
        defer { MockURLProtocol.handler = nil }
        let validator = OpenAICredentialValidator(
            session: makeMockSession(),
            isLocalOnly: { true }
        )

        do {
            _ = try await validator.validate("configured-opaque-key")
            XCTFail("O Modo local deve bloquear a validação antes do transporte HTTP.")
        } catch let error as OpenAIUsagePolicyError {
            XCTAssertEqual(error, .localOnly)
        }

        XCTAssertNil(recorder.request)
    }

    func testErrorReportsDoNotPersistOpenAIResponseMessage() {
        let error = OpenAIAPIError(
            category: .authentication,
            statusCode: 401,
            apiMessage: "Incorrect API key provided: secret-value",
            apiType: "invalid_request_error",
            apiCode: "invalid_api_key",
            requestID: "req_test"
        )

        let description = PavlakErrorReporter.safeTechnicalDescription(for: error)

        XCTAssertTrue(description.contains("statusCode: 401"))
        XCTAssertTrue(description.contains("apiCode: invalid_api_key"))
        XCTAssertTrue(description.contains("requestID: req_test"))
        XCTAssertFalse(description.contains("secret-value"))
        XCTAssertFalse(description.contains("Incorrect API key"))
    }

    private func apiError(status: Int, code: String) -> OpenAIAPIError {
        let data = Data("{\"error\":{\"message\":\"failure\",\"type\":\"api_error\",\"code\":\"\(code)\"}}".utf8)
        return OpenAIAPIError.response(statusCode: status, data: data, requestID: nil)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResult(for request: URLRequest, status: Int, requestID: String? = nil, body: String) -> MockURLProtocol.Result {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let requestID { headers["x-request-id"] = requestID }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return .init(response: response, data: Data(body.utf8))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? { lock.withLock { storedRequest } }
    var body: Data? { lock.withLock { storedBody } }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        lock.withLock {
            storedRequest = request
            storedBody = body
        }
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Result {
        let response: HTTPURLResponse
        let data: Data
    }

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
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

import XCTest
@testable import Pavlek

final class OpenAIRequestFactoryTests: XCTestCase {
    func testGETAlwaysIncludesBearerAuthorization() {
        let request = OpenAIRequestFactory.make(
            url: URL(string: "https://api.openai.com/v1/models")!, method: .get, apiKey: "opaque-value"
        )
        let diagnostics = OpenAIRequestFactory.diagnostics(for: request, apiKey: "opaque-value")
        XCTAssertTrue(diagnostics.hasAuthorizationHeader)
        XCTAssertTrue(diagnostics.startsWithBearer)
        XCTAssertTrue(diagnostics.hasNonEmptyKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-value")
    }

    func testPOSTAlwaysIncludesJSONContentType() {
        let request = OpenAIRequestFactory.make(
            url: URL(string: "https://api.openai.com/v1/responses")!, method: .post,
            apiKey: "opaque-value", body: Data("{}".utf8)
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-value")
    }

    func testAzureAuthenticationUsesAPIKeyHeaderWithoutBearer() {
        let request = OpenAIRequestFactory.make(
            url: URL(string: "https://resource.openai.azure.com/openai/v1/responses")!,
            method: .post,
            apiKey: "opaque-value",
            authentication: .apiKey
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "opaque-value")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}

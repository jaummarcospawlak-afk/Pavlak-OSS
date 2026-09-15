import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PavlakCore

final class MemoryStore: PavlakAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func save(_ apiKey: String) throws { lock.withLock { value = apiKey } }
    func load() throws -> String? { lock.withLock { value } }
    func delete() throws { lock.withLock { value = nil } }
}

actor CapturingTransport: PavlakHTTPTransport {
    private(set) var request: URLRequest?
    let response: PavlakHTTPResponse

    init(status: Int, body: String = "{}") {
        self.response = PavlakHTTPResponse(statusCode: status, data: Data(body.utf8))
    }

    func send(_ request: URLRequest) async throws -> PavlakHTTPResponse {
        self.request = request
        return response
    }

    func capturedAuthorization() -> String? {
        request?.value(forHTTPHeaderField: "Authorization")
    }
}

@Test func validationUsesBearerAndSavesKey() async throws {
    let store = MemoryStore()
    let transport = CapturingTransport(status: 200)
    let service = PavlakOpenAIConnectionService(store: store, transport: transport)

    let result = try await service.connect(apiKey: "  synthetic-test-key  ")

    #expect(result.status == .ready)
    #expect(await transport.capturedAuthorization() == "Bearer synthetic-test-key")
    #expect(try store.load() == "synthetic-test-key")
}

@Test func unauthorizedKeyIsNotSaved() async {
    let store = MemoryStore()
    let body = #"{"error":{"message":"Incorrect API key"}}"#
    let transport = CapturingTransport(status: 401, body: body)
    let service = PavlakOpenAIConnectionService(store: store, transport: transport)

    await #expect(throws: PavlakError.self) {
        _ = try await service.connect(apiKey: "bad-key")
    }
    let stored = try? store.load()
    #expect(stored == nil)
}

@Test func restrictedKeyIsAuthenticatedAndSaved() async throws {
    let store = MemoryStore()
    let transport = CapturingTransport(status: 403, body: #"{"error":{"message":"Restricted"}}"#)
    let service = PavlakOpenAIConnectionService(store: store, transport: transport)

    let result = try await service.connect(apiKey: "restricted-key")

    #expect(result.status == .authenticatedButRestricted)
    #expect(try store.load() == "restricted-key")
}

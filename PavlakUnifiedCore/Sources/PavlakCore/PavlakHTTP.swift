import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PavlakHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    public var requestID: String? {
        headers.first { $0.key.caseInsensitiveCompare("x-request-id") == .orderedSame }?.value
    }
}

public protocol PavlakHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> PavlakHTTPResponse
}

public struct PavlakURLSessionTransport: PavlakHTTPTransport, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> PavlakHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PavlakError.invalidHTTPResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }

        return PavlakHTTPResponse(
            statusCode: http.statusCode,
            data: data,
            headers: headers
        )
    }
}

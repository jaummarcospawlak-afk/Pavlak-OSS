import Foundation
import os

struct OpenAIRequestDiagnostics: Equatable, Sendable {
    let hasAuthorizationHeader: Bool
    let startsWithBearer: Bool
    let hasNonEmptyKey: Bool

    var safeDescription: String {
        "Authorization presente: \(hasAuthorizationHeader ? "sim" : "não") • " +
        "começa com Bearer: \(startsWithBearer ? "sim" : "não") • " +
        "chave não vazia: \(hasNonEmptyKey ? "sim" : "não")"
    }
}

enum OpenAIRequestFactory {
    enum Method: String { case get = "GET", post = "POST" }
    enum Authentication: Sendable { case bearer, apiKey }
    private static let logger = Logger(subsystem: "com.pavlek.macos.demo", category: "OpenAIHTTP")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latestDiagnostics: OpenAIRequestDiagnostics?

    static var lastDiagnostics: OpenAIRequestDiagnostics? { lock.withLock { latestDiagnostics } }

    static func make(url: URL, method: Method, apiKey: String, body: Data? = nil,
                     accept: String = "application/json", timeout: TimeInterval = 30,
                     authentication: Authentication = .bearer) -> URLRequest {
        // Chaves copiadas de campos multilinha podem carregar CR/LF invisíveis.
        // Isso não valida formato: apenas produz um valor HTTP seguro e equivalente.
        let headerCredential = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        switch authentication {
        case .bearer:
            request.setValue("Bearer \(headerCredential)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            request.setValue(headerCredential, forHTTPHeaderField: "api-key")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if method == .post {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = timeout
        audit(request, apiKey: headerCredential)
        return request
    }

    static func diagnostics(for request: URLRequest, apiKey: String) -> OpenAIRequestDiagnostics {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        return .init(
            hasAuthorizationHeader: authorization != nil,
            startsWithBearer: authorization?.hasPrefix("Bearer ") == true,
            hasNonEmptyKey: !apiKey.isEmpty
        )
    }

    private static func audit(_ request: URLRequest, apiKey: String) {
        let value = diagnostics(for: request, apiKey: apiKey)
        lock.withLock { latestDiagnostics = value }
        logger.info("\(value.safeDescription, privacy: .public)")
    }
}

/// Único transporte HTTP usado por todas as chamadas à OpenAI no Pavlak.
/// A fábrica acima garante o Bearer; este cliente centraliza execução e erros.
final class OpenAIClient: @unchecked Sendable {
    static let shared = OpenAIClient()
    private let session: URLSession
    private let isLocalOnly: @Sendable () -> Bool

    init(
        session: URLSession = .shared,
        isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly }
    ) {
        self.session = session
        self.isLocalOnly = isLocalOnly
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        do {
            let (data, response) = try await session.data(for: request)
            guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
            guard let http = response as? HTTPURLResponse else { throw invalidResponse() }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenAIAPIError.response(statusCode: http.statusCode, data: data,
                                              requestID: http.value(forHTTPHeaderField: "x-request-id"))
            }
            return (data, http)
        } catch let error as OpenAIAPIError {
            throw error
        } catch let error as OpenAIUsagePolicyError {
            throw error
        } catch let error as URLError {
            throw transportError(error)
        } catch {
            throw OpenAIAPIError(category: .network, statusCode: nil,
                                 apiMessage: error.localizedDescription, apiType: "transport_error",
                                 apiCode: nil, requestID: nil)
        }
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard !isLocalOnly() else { throw OpenAIUsagePolicyError.localOnly }
            guard let http = response as? HTTPURLResponse else { throw invalidResponse() }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw OpenAIAPIError.response(statusCode: http.statusCode, data: data,
                                              requestID: http.value(forHTTPHeaderField: "x-request-id"))
            }
            return (bytes, http)
        } catch let error as OpenAIAPIError {
            throw error
        } catch let error as OpenAIUsagePolicyError {
            throw error
        } catch let error as URLError {
            throw transportError(error)
        } catch {
            throw OpenAIAPIError(category: .network, statusCode: nil,
                                 apiMessage: error.localizedDescription, apiType: "transport_error",
                                 apiCode: nil, requestID: nil)
        }
    }

    private func invalidResponse() -> OpenAIAPIError {
        OpenAIAPIError(category: .invalidResponse, statusCode: nil, apiMessage: nil,
                       apiType: nil, apiCode: nil, requestID: nil)
    }

    private func transportError(_ error: URLError) -> OpenAIAPIError {
        let tlsCodes: Set<URLError.Code> = [
            .secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired
        ]
        return OpenAIAPIError(category: tlsCodes.contains(error.code) ? .tls : .network,
                              statusCode: nil, apiMessage: error.localizedDescription,
                              apiType: "url_error", apiCode: String(error.errorCode), requestID: nil)
    }
}

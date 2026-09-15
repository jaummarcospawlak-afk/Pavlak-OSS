import Foundation
import Security
import CryptoKit
import Combine

enum CloudFailure: Error, LocalizedError, Equatable {
    case configuration, credential, consent, budget, limit, response, cancelled
    var errorDescription: String? {
        switch self {
        case .configuration: "Configuração alterada ou destino inválido. Revise a conexão."
        case .credential: "Insira a credencial deste destino diretamente nas configurações do Pavlek."
        case .consent: "Envio à nuvem não autorizado."
        case .budget: "Envio bloqueado pelo teto local. Ative o acompanhamento no portal Azure ou configure o teto e as estimativas em IA."
        case .limit: "O limite local de tamanho, etapas ou duração foi atingido."
        case .response: "O provedor não concluiu a solicitação. Nenhum detalhe privado foi registrado."
        case .cancelled: "Operação encerrada."
        }
    }
}

/// No legacy OpenAI credential is ever used for an Azure destination.
enum CloudCredentialStore {
    private static let service = "com.pavlek.azure.scoped.v1"
    private struct AzureCache {
        var loadedScopes: Set<String> = []
        var credentials: [String: String] = [:]
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache = AzureCache()

    static func account(for configuration: PavlakAIConfiguration) -> String {
        SHA256.hash(data: Data(configuration.credentialScope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func identity(_ configuration: PavlakAIConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account(for: configuration)]
    }
    static func save(_ secret: String, configuration: PavlakAIConfiguration) throws {
        guard configuration.validationError() == nil else { throw CloudFailure.configuration }
        if configuration.provider == .openAI { try OpenAIKeyStore.save(secret); return }
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CloudFailure.credential }
        let query = identity(configuration)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status != errSecSuccess {
            guard status == errSecItemNotFound else { throw CloudFailure.credential }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudFailure.credential }
        }
        cacheLock.withLock {
            cache.loadedScopes.insert(configuration.credentialScope)
            cache.credentials[configuration.credentialScope] = value
        }
    }
    static func load(configuration: PavlakAIConfiguration) async -> String? {
        guard configuration.validationError() == nil else { return nil }
        if configuration.provider == .openAI {
            await OpenAIKeyStore.loadFromKeychain()
            return OpenAIKeyStore.load()
        }
        if let cached = cacheLock.withLock({ cache.credentials[configuration.credentialScope] }) { return cached }
        let value = await Task.detached {
            var query = identity(configuration)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil as String? }
            return String(data: data, encoding: .utf8)
        }.value
        cacheLock.withLock {
            cache.loadedScopes.insert(configuration.credentialScope)
            if let value { cache.credentials[configuration.credentialScope] = value }
        }
        return value
    }
    static func hasCredential(configuration: PavlakAIConfiguration) -> Bool {
        guard configuration.provider == .azureOpenAI else { return OpenAIKeyStore.hasKey }
        return cacheLock.withLock { cache.credentials[configuration.credentialScope] != nil }
    }
    static func remove(configuration: PavlakAIConfiguration) {
        guard configuration.validationError() == nil else { return }
        if configuration.provider == .openAI { OpenAIKeyStore.remove(); return }
        SecItemDelete(identity(configuration) as CFDictionary)
        cacheLock.withLock {
            cache.loadedScopes.insert(configuration.credentialScope)
            cache.credentials.removeValue(forKey: configuration.credentialScope)
        }
    }
}

enum PavlakAIConnectionStatus {
    static var currentConfiguration: PavlakAIConfiguration { PavlakAIConfigurationStore.load() }

    static func hasCredential(for configuration: PavlakAIConfiguration) -> Bool {
        switch configuration.provider {
        case .openAI: OpenAIKeyStore.hasValidatedKey
        case .azureOpenAI: CloudCredentialStore.hasCredential(configuration: configuration)
        }
    }

    static var isReady: Bool {
        let configuration = currentConfiguration
        return configuration.validationError() == nil && hasCredential(for: configuration)
    }
}

/// Ephemeral session: no disk cache, cookies, redirects or credential-bearing logs.
final class CloudSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CloudHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: CloudSessionDelegate(), delegateQueue: nil)
    }()
    static func request(configuration: PavlakAIConfiguration, credential: String, body: Data?, realtime: Bool = false) throws -> URLRequest {
        guard configuration.validationError() == nil,
              let url = realtime ? configuration.realtimeURL : configuration.responsesURL else { throw CloudFailure.configuration }
        guard !credential.isEmpty, !credential.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CloudFailure.credential }
        var request = URLRequest(url: url)
        request.httpMethod = realtime ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.usesBearerAuthentication ? "Bearer \(credential)" : credential,
                         forHTTPHeaderField: configuration.usesBearerAuthentication ? "Authorization" : "api-key")
        return request
    }
}

struct CloudLimits: Codable, Equatable, Sendable {
    /// When false, the app does not reserve against a local dollar ceiling.
    /// Provider billing remains finite and unknown tariffs are never treated as
    /// free or as an infinite credit balance.
    var localBudgetEnabled: Bool = true
    var dailyUSD: Double = 0
    // User-confirmed conservative rates, not a claim about Azure billing/pricing.
    var textUSDPerMillionTokens: Double = 0
    var voiceUSDPerMinute: Double = 0
    var outputTokens: Int = 512
    var cycles: Int = 4
    var voiceSeconds: Int = 60
    static let maxInputBytes = 32_000
    private enum CodingKeys: String, CodingKey {
        case localBudgetEnabled, dailyUSD, textUSDPerMillionTokens, voiceUSDPerMinute,
             outputTokens, cycles, voiceSeconds
    }
    init(localBudgetEnabled: Bool = true, dailyUSD: Double = 0,
         textUSDPerMillionTokens: Double = 0, voiceUSDPerMinute: Double = 0,
         outputTokens: Int = 512, cycles: Int = 4, voiceSeconds: Int = 60) {
        self.localBudgetEnabled = localBudgetEnabled
        self.dailyUSD = dailyUSD
        self.textUSDPerMillionTokens = textUSDPerMillionTokens
        self.voiceUSDPerMinute = voiceUSDPerMinute
        self.outputTokens = outputTokens
        self.cycles = cycles
        self.voiceSeconds = voiceSeconds
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            localBudgetEnabled: try values.decodeIfPresent(Bool.self, forKey: .localBudgetEnabled) ?? true,
            dailyUSD: try values.decodeIfPresent(Double.self, forKey: .dailyUSD) ?? 0,
            textUSDPerMillionTokens: try values.decodeIfPresent(Double.self, forKey: .textUSDPerMillionTokens) ?? 0,
            voiceUSDPerMinute: try values.decodeIfPresent(Double.self, forKey: .voiceUSDPerMinute) ?? 0,
            outputTokens: try values.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 512,
            cycles: try values.decodeIfPresent(Int.self, forKey: .cycles) ?? 4,
            voiceSeconds: try values.decodeIfPresent(Int.self, forKey: .voiceSeconds) ?? 60
        )
    }
    var valid: Bool {
        dailyUSD.isFinite && (0...100).contains(dailyUSD) &&
        textUSDPerMillionTokens.isFinite && (0...1_000).contains(textUSDPerMillionTokens) &&
        voiceUSDPerMinute.isFinite && (0...100).contains(voiceUSDPerMinute) &&
        (32...2_000).contains(outputTokens) && (1...6).contains(cycles) && (10...120).contains(voiceSeconds)
    }
}

/// Reservations persist BEFORE a network attempt and are never refunded on failures/cancellation.
/// These are conservative local estimates, not a provider billing meter or cross-device budget.
final class CloudBudget: @unchecked Sendable {
    static let shared = CloudBudget(defaults: .standard)
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let limitsKey = "Pavlek.cloud.limits.v1"
    private let ledgerKey = "Pavlek.cloud.ledger.v1"
    struct Ledger: Codable, Sendable {
        var day: String
        var reservedUSD: Double = 0
        var requests: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var voiceSeconds: Int = 0
    }
    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults; self.now = now
    }
    var limits: CloudLimits { lock.withLock { readLimits() } }
    func save(_ value: CloudLimits) throws {
        guard value.valid else { throw CloudFailure.limit }
        try lock.withLock { defaults.set(try JSONEncoder().encode(value), forKey: limitsKey) }
    }
    private func readLimits() -> CloudLimits {
        guard let data = defaults.data(forKey: limitsKey), let value = try? JSONDecoder().decode(CloudLimits.self, from: data), value.valid else { return .init() }
        return value
    }
    private func readLedger() -> Ledger {
        let day = String(ISO8601DateFormatter().string(from: now()).prefix(10))
        guard let data = defaults.data(forKey: ledgerKey), let value = try? JSONDecoder().decode(Ledger.self, from: data), value.day == day,
              value.reservedUSD.isFinite, value.reservedUSD >= 0 else { return .init(day: day) }
        return value
    }
    var summary: Ledger { lock.withLock { readLedger() } }
    func reserve(inputBytes: Int, voice: Bool = false) throws {
        try lock.withLock {
            let limits = readLimits()
            guard limits.valid, inputBytes >= 0, inputBytes <= CloudLimits.maxInputBytes else { throw CloudFailure.budget }
            guard limits.localBudgetEnabled else {
                var ledger = readLedger()
                ledger.requests += 1
                defaults.set(try JSONEncoder().encode(ledger), forKey: ledgerKey)
                return
            }
            guard limits.dailyUSD > 0 else { throw CloudFailure.budget }
            if voice {
                guard limits.voiceUSDPerMinute > 0 else { throw CloudFailure.budget }
            } else {
                guard limits.textUSDPerMillionTokens > 0 else { throw CloudFailure.budget }
            }
            var ledger = readLedger()
            // UTF-8 byte count is used as a conservative input-token bound.
            let textEstimate = voice ? 0 : Double(inputBytes + limits.outputTokens) * limits.textUSDPerMillionTokens / 1_000_000
            let amount = textEstimate + (voice ? Double(limits.voiceSeconds) / 60 * limits.voiceUSDPerMinute : 0)
            guard amount.isFinite, ledger.reservedUSD + amount <= limits.dailyUSD else { throw CloudFailure.budget }
            ledger.reservedUSD += amount; ledger.requests += 1
            defaults.set(try JSONEncoder().encode(ledger), forKey: ledgerKey)
        }
    }
    func record(input: Int, output: Int, voiceSeconds: Int = 0) {
        lock.withLock {
            var ledger = readLedger()
            ledger.inputTokens += max(0, min(input, 10_000_000))
            ledger.outputTokens += max(0, min(output, 10_000_000))
            ledger.voiceSeconds += max(0, min(voiceSeconds, 120))
            if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: ledgerKey) }
        }
    }
}

@MainActor
final class CloudConsent: ObservableObject {
    static let shared = CloudConsent()
    struct Request: Identifiable {
        let id: UUID
        let provider: String
        let content: String
    }
    @Published private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?
    func ask(content: String, configuration: PavlakAIConfiguration) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        let id = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                pending = .init(id: id, provider: configuration.provider.displayName + " · " + (configuration.effectiveModelName ?? ""), content: content)
            }
        } onCancel: {
            Task { @MainActor in if self.pending?.id == id { self.resolve(false) } }
        }
        return accepted && !Task.isCancelled
    }
    func resolve(_ allowed: Bool) {
        let current = continuation
        continuation = nil; pending = nil
        current?.resume(returning: allowed)
    }
}

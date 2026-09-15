import Foundation
import Security
import CryptoKit

enum OpenAIKeyStore {
    private static let service = "com.pavlak.openai"
    private static let account = "api-key"
    // Versioned because a legacy validation only listed models; v1 requires a successful Responses API probe.
    private static let validationAccount = "validated-responses-v1-credential-digest"

    private struct SessionCache {
        var isLoaded = false
        var credential: String?
        var validationDigest: Data?
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache = SessionCache()
    nonisolated(unsafe) private static var initialLoadTask: Task<(String?, Data?), Never>?

    /// These properties are memory-only snapshots and are safe to use while SwiftUI renders.
    static var hasKey: Bool { cached().credential != nil }
    static var hasValidatedKey: Bool {
        let snapshot = cached()
        guard let credential = snapshot.credential, let savedDigest = snapshot.validationDigest else { return false }
        return savedDigest == digest(credential)
    }

    static func load() -> String? { cached().credential }

    /// Performs the only Keychain reads for this process, away from the main actor.
    static func loadFromKeychain() async {
        guard !cached().isLoaded else { return }
        let task = cacheLock.withLock { () -> Task<(String?, Data?), Never> in
            if let initialLoadTask { return initialLoadTask }
            let task = Task.detached(priority: .userInitiated) {
                (readCredentialFromKeychain(), loadDataFromKeychain(account: validationAccount))
            }
            initialLoadTask = task
            return task
        }
        let loaded = await task.value
        cacheLock.withLock {
            initialLoadTask = nil
            guard !cache.isLoaded else { return }
            cache = SessionCache(isLoaded: true, credential: loaded.0, validationDigest: loaded.1)
        }
    }

    private static func readCredentialFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIKeyStoreError.emptyCredential }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        try upsert(data: Data(trimmed.utf8), identity: identity)
        delete(account: validationAccount)
        cacheLock.withLock { cache = SessionCache(isLoaded: true, credential: trimmed, validationDigest: nil) }
    }

    static func markValidated(_ credential: String) throws {
        guard cached().credential == credential else { throw OpenAIKeyStoreError.credentialChanged }
        let value = digest(credential)
        try saveData(value, account: validationAccount)
        cacheLock.withLock { cache.validationDigest = value }
    }

    static func markUnvalidated() {
        delete(account: validationAccount)
        cacheLock.withLock { cache.validationDigest = nil }
    }

    static func remove() {
        delete(account: account); delete(account: validationAccount)
        cacheLock.withLock { cache = SessionCache(isLoaded: true, credential: nil, validationDigest: nil) }
    }

    private static func digest(_ credential: String) -> Data { Data(SHA256.hash(data: Data(credential.utf8))) }

    private static func loadDataFromKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveData(_ data: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        try upsert(data: data, identity: identity)
    }

    private static func upsert(data: Data, identity: [String: Any]) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OpenAIKeyStoreError.keychainFailure }
        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OpenAIKeyStoreError.keychainFailure }
    }

    private static func delete(account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    private static func cached() -> SessionCache { cacheLock.withLock { cache } }
}

enum OpenAIKeyStoreError: LocalizedError {
    case emptyCredential, keychainFailure, credentialChanged
    var errorDescription: String? {
        switch self {
        case .emptyCredential: "Informe a credencial da OpenAI."
        case .keychainFailure: "Não foi possível salvar a chave no Chaveiro do macOS."
        case .credentialChanged: "A credencial foi alterada durante a validação. Tente novamente."
        }
    }
}

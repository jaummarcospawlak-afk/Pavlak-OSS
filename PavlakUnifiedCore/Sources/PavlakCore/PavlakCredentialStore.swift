import Foundation
#if canImport(Security)
import Security
#endif

public protocol PavlakAPIKeyStoring: Sendable {
    func save(_ apiKey: String) throws
    func load() throws -> String?
    func delete() throws
}

public enum PavlakSecretStoreError: Error, LocalizedError, Sendable, Equatable {
    case unexpectedStatus(Int32)
    case invalidStoredData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Falha no Keychain do macOS (status \(status))."
        case .invalidStoredData:
            return "A chave salva no Keychain não pôde ser lida."
        }
    }
}

#if canImport(Security)
public final class PavlakKeychainStore: PavlakAPIKeyStoring, @unchecked Sendable {
    private struct Slot: Hashable {
        let service: String
        let account: String
    }

    private let canonical = Slot(service: "com.pavlak.openai", account: "api_key")
    private let legacySlots = [
        Slot(service: "com.pavlak.openai", account: "openai_service_account_api_key"),
        Slot(service: "Pavlek.LocalPrototype", account: "OPENAI_API_KEY"),
        Slot(service: "Pavlak", account: "openai_api_key")
    ]

    public init() {}

    public func save(_ apiKey: String) throws {
        try upsert(apiKey, into: canonical)
    }

    public func load() throws -> String? {
        if let value = try read(from: canonical) {
            return value
        }

        // Migração não destrutiva: copia a credencial antiga para o slot único
        // e preserva o item original até o usuário escolher “Desconectar”.
        for slot in legacySlots {
            if let value = try read(from: slot), !value.isEmpty {
                try upsert(value, into: canonical)
                return value
            }
        }

        return nil
    }

    public func delete() throws {
        try delete(slot: canonical)
        for slot in legacySlots {
            try delete(slot: slot)
        }
    }

    private func read(from slot: Slot) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: slot.service,
            kSecAttrAccount: slot.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PavlakSecretStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PavlakSecretStoreError.invalidStoredData
        }
        return value
    }

    private func upsert(_ value: String, into slot: Slot) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: slot.service,
            kSecAttrAccount: slot.account
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (key, attribute) in attributes {
                addQuery[key] = attribute
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PavlakSecretStoreError.unexpectedStatus(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw PavlakSecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    private func delete(slot: Slot) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: slot.service,
            kSecAttrAccount: slot.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PavlakSecretStoreError.unexpectedStatus(status)
        }
    }
}
#else
public final class PavlakKeychainStore: PavlakAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init() {}

    public func save(_ apiKey: String) throws {
        lock.lock()
        value = apiKey
        lock.unlock()
    }

    public func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func delete() throws {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
#endif

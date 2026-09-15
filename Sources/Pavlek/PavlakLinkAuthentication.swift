import CryptoKit
import Foundation
import Security

struct PavlakLinkAuthentication: Codable, Equatable, Sendable {
    let nonce: String
    let tag: String
}

enum PavlakLinkAuthenticator {
    static let maximumClockSkew: TimeInterval = 300

    static func sign(_ message: PavlakLinkMessage, secret: Data, nonce: String = UUID().uuidString) -> PavlakLinkMessage {
        let tag = authenticationTag(for: message, nonce: nonce, secret: secret)
        return PavlakLinkMessage(
            requestID: message.requestID, sourceDevice: message.sourceDevice, targetDevice: message.targetDevice,
            action: message.action, query: message.query, payload: message.payload, status: message.status,
            result: message.result, sentAt: message.sentAt,
            authentication: .init(nonce: nonce, tag: tag)
        )
    }

    static func verify(_ message: PavlakLinkMessage, secret: Data, now: Date = Date()) -> Bool {
        guard let authentication = message.authentication,
              abs(now.timeIntervalSince(message.sentAt)) <= maximumClockSkew,
              let supplied = Data(base64Encoded: authentication.tag) else { return false }
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: canonicalData(for: message, nonce: authentication.nonce),
            using: SymmetricKey(data: secret)
        ))
        return supplied.count == expected.count && zip(supplied, expected).reduce(true) { $0 && ($1.0 == $1.1) }
    }

    private static func authenticationTag(for message: PavlakLinkMessage, nonce: String, secret: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: canonicalData(for: message, nonce: nonce),
            using: SymmetricKey(data: secret)
        )).base64EncodedString()
    }

    private static func canonicalData(for message: PavlakLinkMessage, nonce: String) -> Data {
        let fields = [
            message.requestID.uuidString.lowercased(), message.sourceDevice.rawValue,
            message.targetDevice.rawValue, message.action.rawValue, message.query,
            message.payload ?? "", message.status.rawValue, message.result ?? "",
            String(format: "%.3f", message.sentAt.timeIntervalSince1970), nonce
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }
}

enum PavlakLinkPairingStore {
    private static let service = "com.pavlek.link.pairing"
    private static let account = "local-pairing-secret-v2"
    private static let legacyAccount = "local-pairing-secret-v1"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func save(code: String) throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 16, let data = normalized.data(using: .utf8) else {
            throw PavlakLinkError.invalidPairingCode
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PavlakLinkError.pairingStorageFailure }
        } else if status != errSecSuccess {
            throw PavlakLinkError.pairingStorageFailure
        }
    }

    static func remove() {
        for targetAccount in [account, legacyAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: targetAccount
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

enum PavlakLinkDeviceIdentity {
    private static let service = "com.pavlak.link.device-identity"
    private static let account = "source-device-id-v1"

    static func loadOrCreate() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.lowercased()
        var insert = query
        insert.removeValue(forKey: kSecReturnData as String)
        insert.removeValue(forKey: kSecMatchLimit as String)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(insert as CFDictionary, nil)
        return value
    }

    static func stableID(deviceID: String, localID: String) -> String {
        let input = "\(deviceID)\u{1f}\(localID)"
        let hash = input.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "pavlak-file-\(String(hash, radix: 16))"
    }
}

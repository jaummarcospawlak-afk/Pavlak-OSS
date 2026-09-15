#if os(macOS)
import Foundation

struct PavlakConversationMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
}

struct PavlakConversationRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [PavlakConversationMessage]
}

struct PavlakProfileMatch: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

enum PavlakProfileStore {
    static let displayNameKey = "Pavlak.profile.displayName.v1"
    static let preferenceKey = "Pavlak.profile.preference.v1"

    static func matches(query: String, defaults: UserDefaults = .standard) -> [PavlakProfileMatch] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let values = [
            PavlakProfileMatch(id: "display-name", label: "Nome de exibição", value: defaults.string(forKey: displayNameKey) ?? ""),
            PavlakProfileMatch(id: "preference", label: "Preferência de resposta", value: defaults.string(forKey: preferenceKey) ?? "")
        ]
        return values.filter {
            let haystack = normalize($0.label + " " + $0.value)
            return !haystack.isEmpty && (haystack.contains(normalizedQuery) || normalizedQuery.split(separator: " ").allSatisfy { haystack.contains($0) })
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Small local history store for Pavlak conversations. It intentionally stores
/// only conversation text and timestamps; provider credentials and response
/// identifiers never belong in this record.
final class PavlakConversationStore: @unchecked Sendable {
    static let shared = PavlakConversationStore()

    private let defaults: UserDefaults
    private let key = "Pavlak.local.conversations.v1"
    private let lock = NSLock()
    private let maxConversations = 50
    private let maxMessagesPerConversation = 100
    private let maxTextLength = 12_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PavlakConversationRecord] {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let records = try? JSONDecoder().decode([PavlakConversationRecord].self, from: data) else {
                return []
            }
            return normalize(records)
        }
    }

    func save(_ records: [PavlakConversationRecord]) {
        lock.withLock {
            let normalized = normalize(records)
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: key)
        }
    }

    func upsert(_ record: PavlakConversationRecord) {
        var records = load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        save(records)
    }

    private func normalize(_ records: [PavlakConversationRecord]) -> [PavlakConversationRecord] {
        records.compactMap { record in
            let messages = record.messages.prefix(maxMessagesPerConversation).map { message in
                PavlakConversationMessage(id: message.id, role: message.role, text: sanitized(message.text))
            }
            guard !messages.isEmpty else { return nil }
            let fallbackTitle = messages.first(where: { $0.role == .user })?.text ?? "Conversa sem título"
            let title = sanitized(record.title).trimmingCharacters(in: .whitespacesAndNewlines)
            return PavlakConversationRecord(
                id: record.id,
                title: String((title.isEmpty ? fallbackTitle : title).prefix(120)),
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                messages: Array(messages)
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        .prefix(maxConversations)
        .map { $0 }
    }

    private func sanitized(_ value: String) -> String {
        var text = String(value.prefix(maxTextLength))
        // Avoid persisting the most recognizable provider-key forms if a user
        // accidentally pastes one into a conversation. This is not a secret
        // extractor and never logs or transmits the original value.
        text = text.replacingOccurrences(of: #"(?i)\bsk-[A-Za-z0-9_-]{16,}\b"#, with: "[credencial omitida]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(?:api[-_ ]?key|chave(?:\s+azure)?|token)\s*[:=]\s*[^\s,;]+"#, with: "[credencial omitida]", options: .regularExpression)
        return text
    }
}
#endif

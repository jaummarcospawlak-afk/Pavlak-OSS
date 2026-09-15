#if os(macOS)
import AppKit
import Foundation
import UserNotifications

struct PendingDocumentSchedule: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let fileURL: URL
    let scheduledAt: Date
}

enum DocumentScheduleParser {
    static func parse(_ command: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let normalized = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        guard normalized.contains("amanha"),
              normalized.contains("abr"),
              normalized.contains("arquivo") || normalized.contains("documento") || normalized.contains("este") else { return nil }

        let pattern = #"\b(?:as\s+)?([01]?\d|2[0-3])(?:\s*(?:h|:|h\s*)([0-5]\d)?)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let hourRange = Range(match.range(at: 1), in: normalized),
              let hour = Int(normalized[hourRange]) else { return nil }
        let minute: Int
        if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: normalized) {
            minute = Int(normalized[range]) ?? 0
        } else {
            minute = 0
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
    }
}

@MainActor
protocol DocumentScheduling: AnyObject {
    func schedule(_ request: PendingDocumentSchedule) async throws
}

@MainActor
final class LocalDocumentScheduler: DocumentScheduling {
    static let shared = LocalDocumentScheduler()
    static let categoryIdentifier = "PAVLAK_SCHEDULED_DOCUMENT"
    static let openActionIdentifier = "PAVLAK_OPEN_SCHEDULED_DOCUMENT"
    static let bookmarkKey = "securityScopedBookmark"

    func configureNotificationActions() {
        let action = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: "Abrir documento",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func schedule(_ request: PendingDocumentSchedule) async throws {
        let center = UNUserNotificationCenter.current()
        let authorized = try await center.requestAuthorization(options: [.alert, .sound])
        guard authorized else { throw DocumentScheduleError.notificationsDenied }
        let bookmark = try request.fileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let content = UNMutableNotificationContent()
        content.title = "Documento agendado"
        content.body = "\(request.fileName) está pronto. Use “Abrir documento” para abri-lo com sua interação."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.bookmarkKey: bookmark.base64EncodedString()]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: request.scheduledAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: trigger))
    }

    static func handle(actionIdentifier: String, encodedBookmark: String?) {
        guard actionIdentifier == openActionIdentifier else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let encoded = encodedBookmark,
              let data = Data(base64Encoded: encoded) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.open(url)
        if accessed { url.stopAccessingSecurityScopedResource() }
    }
}

enum DocumentScheduleError: LocalizedError {
    case notificationsDenied
    var errorDescription: String? { "As notificações não foram autorizadas. O agendamento não foi criado." }
}
#endif

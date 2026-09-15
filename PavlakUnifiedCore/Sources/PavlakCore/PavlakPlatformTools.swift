import Foundation

#if os(macOS)
import AppKit
import Combine
import UserNotifications

@MainActor
public final class PavlakWorkspaceManager: ObservableObject {
    public static let shared = PavlakWorkspaceManager()

    @Published public private(set) var selectedPath: String?
    private let bookmarkKey = "Pavlak.WorkspaceBookmark.v1"

    private init() {
        selectedPath = resolvedURL()?.path
    }

    @discardableResult
    public func chooseWorkspace() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Escolha a pasta que o Pavlak poderá consultar"
        panel.prompt = "Autorizar pasta"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            selectedPath = url.path
            return true
        } catch {
            selectedPath = nil
            return false
        }
    }

    public func clearWorkspace() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        selectedPath = nil
    }

    public func withAccess<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let url = resolvedURL() else { throw PavlakError.workspaceNotConfigured }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }

    private func resolvedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        if stale, let fresh = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }
}

@MainActor
enum PavlakSafariTool {
    static func open(urlString: String) async throws -> String {
        guard let url = normalizedURL(urlString) else {
            throw PavlakError.invalidArguments("URL inválida: \(urlString)")
        }
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw PavlakError.operationFailed("Safari não foi localizado neste Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: "Safari abriu: \(url.absoluteString)") }
            }
        }
    }

    static func search(query: String) async throws -> String {
        guard var components = URLComponents(string: "https://www.google.com/search") else {
            throw PavlakError.operationFailed("Não foi possível montar a pesquisa.")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw PavlakError.operationFailed("Não foi possível montar a URL da pesquisa.")
        }
        return try await open(urlString: url.absoluteString)
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), direct.scheme != nil { return direct }
        return URL(string: "https://\(trimmed)")
    }
}

@MainActor
enum PavlakMacTool {
    static func openApplication(named name: String) async throws -> String {
        let normalized = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "pt_BR")
        ).lowercased()

        let bundleIdentifiers: [String: String] = [
            "safari": "com.apple.Safari",
            "finder": "com.apple.finder",
            "pages": "com.apple.iWork.Pages",
            "xcode": "com.apple.dt.Xcode",
            "fotos": "com.apple.Photos",
            "photos": "com.apple.Photos",
            "calendario": "com.apple.iCal",
            "calendar": "com.apple.iCal",
            "contatos": "com.apple.AddressBook",
            "contacts": "com.apple.AddressBook",
            "notas": "com.apple.Notes",
            "notes": "com.apple.Notes",
            "mail": "com.apple.mail",
            "email": "com.apple.mail",
            "ajustes do sistema": "com.apple.systempreferences",
            "ajustes": "com.apple.systempreferences",
            "configuracoes": "com.apple.systempreferences",
            "settings": "com.apple.systempreferences"
        ]

        let appURL: URL?
        if let bundleIdentifier = bundleIdentifiers[normalized] {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        } else if let path = NSWorkspace.shared.fullPath(forApplication: name) {
            appURL = URL(fileURLWithPath: path)
        } else {
            appURL = nil
        }

        guard let appURL else {
            throw PavlakError.operationFailed("Aplicativo não encontrado: \(name)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: "Aplicativo aberto: \(name)") }
            }
        }
    }

    static func notify(title: String, body: String) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw PavlakError.permissionDenied("Notificações não foram autorizadas.") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return "Notificação enviada: \(title)"
    }
}

@MainActor
enum PavlakFileTool {
    static func find(query: String, maxResults: Int) throws -> String {
        let limit = max(1, min(maxResults, 30))
        let terms = meaningfulTerms(query)
        let matches: [(score: Int, path: String)] = try PavlakWorkspaceManager.shared.withAccess { root in
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { return [] }

            var candidates: [(Int, String)] = []
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isHidden != true else { continue }

                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let searchable = relative.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "pt_BR")
                ).lowercased()
                let name = url.deletingPathExtension().lastPathComponent.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "pt_BR")
                ).lowercased()

                let matched = terms.filter { searchable.contains($0) }
                guard !matched.isEmpty else { continue }
                var score = matched.count * 10
                score += terms.filter { name.contains($0) }.count * 8
                if matched.count == terms.count { score += 20 }
                candidates.append((score, relative))
            }

            return candidates
                .sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0 }
                .prefix(limit)
                .map { ($0.0, $0.1) }
        }

        guard !matches.isEmpty else {
            return "Nenhum arquivo encontrado para “\(query)” na pasta autorizada."
        }
        return matches.enumerated().map { index, item in
            "\(index + 1). \(item.path)"
        }.joined(separator: "\n")
    }

    static func open(relativePath: String) throws -> String {
        try PavlakWorkspaceManager.shared.withAccess { root in
            let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
            let rootPath = root.standardizedFileURL.path
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
                throw PavlakError.permissionDenied("O caminho está fora da pasta autorizada.")
            }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw PavlakError.operationFailed("Arquivo não encontrado: \(relativePath)")
            }
            guard NSWorkspace.shared.open(candidate) else {
                throw PavlakError.operationFailed("O macOS não conseguiu abrir: \(relativePath)")
            }
            return "Arquivo aberto: \(relativePath)"
        }
    }

    private static func meaningfulTerms(_ query: String) -> [String] {
        let stopwords: Set<String> = [
            "o", "a", "os", "as", "um", "uma", "meu", "minha", "meus", "minhas",
            "arquivo", "documento", "de", "da", "do", "das", "dos", "em", "no", "na"
        ]
        return query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }
}

#else
public final class PavlakWorkspaceManager: @unchecked Sendable {
    public static let shared = PavlakWorkspaceManager()
    public private(set) var selectedPath: String?
    private init() {}
    @discardableResult public func chooseWorkspace() -> Bool { false }
    public func clearWorkspace() { selectedPath = nil }
}
#endif

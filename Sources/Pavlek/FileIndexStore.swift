#if os(macOS)
import Foundation

actor FileIndexStore {
    static let folderName = "Pavlak File Index"
    private(set) var snapshot = FileIndexSnapshot()
    let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = directory ?? support.appendingPathComponent(Self.folderName, isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("index-v1.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode(FileIndexSnapshot.self, from: data) { snapshot = saved }
    }

    /// Separate local and remote search services share this file. Refresh before
    /// reading so a newly authorized folder is visible without restarting the app.
    func current() -> FileIndexSnapshot {
        reloadFromDisk()
        return snapshot
    }

    private func reloadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode(FileIndexSnapshot.self, from: data) {
            snapshot = saved
        }
    }

    func resolve(_ root: AuthorizedFileRoot) throws -> URL {
        var stale = false
        let rootURL = try URL(
            resolvingBookmarkData: root.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw FileIndexError.staleAuthorization }
        return rootURL
    }

    func replace(root: AuthorizedFileRoot, files: [IndexedFile]) throws {
        reloadFromDisk()
        snapshot.roots.removeAll { $0.id == root.id }
        snapshot.roots.append(root)
        snapshot.files.removeAll { $0.rootID == root.id }
        snapshot.files.append(contentsOf: files)
        snapshot.updatedAt = Date()
        try persist()
    }

    func resolve(_ file: IndexedFile) throws -> URL {
        guard let root = snapshot.roots.first(where: { $0.id == file.rootID }) else { throw FileIndexError.rootUnavailable }
        let rootURL = try resolve(root)
        let url = rootURL.appendingPathComponent(file.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard FileIndexService.isDescendantOrSame(url, of: rootURL) else { throw FileIndexError.rootUnavailable }
        return url
    }

    private func persist() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

enum FileIndexError: LocalizedError {
    case rootUnavailable, staleAuthorization, unsupportedDocument, protectedDocument, emptyDocument
    var errorDescription: String? {
        switch self {
        case .rootUnavailable: "A pasta autorizada não está disponível."
        case .staleAuthorization: "A autorização da pasta expirou. Selecione-a novamente."
        case .unsupportedDocument: "O formato do documento não pôde ser lido."
        case .protectedDocument: "O documento é protegido e não foi desbloqueado pelo Pavlak."
        case .emptyDocument: "O documento selecionado não contém texto extraível."
        }
    }
}
#endif

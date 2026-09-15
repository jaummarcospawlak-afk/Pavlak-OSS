#if os(macOS)
import Foundation

struct PavlakSpotlightHit: Sendable {
    let path: String
    let name: String
    let modifiedAt: Date?
    let metadata: String
}
struct PavlakSpotlightResponse: Sendable {
    let hits: [PavlakSpotlightHit]
    let completed: Bool
    let detail: String
}

/// Queries only resolved, user-authorized directories. An empty scope must never
/// reach NSMetadataQuery because Apple's empty scope means the entire computer.
@MainActor
final class PavlakSpotlightSearch: NSObject {
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<PavlakSpotlightResponse, Never>?
    private var timeout: Task<Void, Never>?
    private var roots: [URL] = []

    func search(_ request: PavlakSearchRequest, directories: [URL], timeoutSeconds: Double = 3) async -> PavlakSpotlightResponse {
        guard !directories.isEmpty else { return .init(hits: [], completed: false, detail: "Spotlight não consultado: nenhuma pasta autorizada.") }
        guard continuation == nil else { return .init(hits: [], completed: false, detail: "Spotlight já está consultando.") }
        roots = directories
        let accessed = directories.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let terms = Array(Set(request.expandedPhrases + request.detailTerms)).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return .init(hits: [], completed: false, detail: "Spotlight não consultado: pedido sem termos.") }
        query.searchScopes = directories
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: terms.prefix(30).flatMap { term in
            ["kMDItemFSName", "kMDItemTextContent", "kMDItemKeywords"].map { key in
                NSPredicate(format: "%K ==[cd] %@", key, "*\(term)*")
            }
        })
        query.notificationBatchingInterval = 0.1
        NotificationCenter.default.addObserver(self, selector: #selector(didFinish), name: .NSMetadataQueryDidFinishGathering, object: query)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.finish(completed: false)
            }
            if !query.start() { finish(completed: false) }
        }
    }

    @objc private func didFinish(_ notification: Notification) { finish(completed: true) }

    private func finish(completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        query.disableUpdates()
        var hits: [PavlakSpotlightHit] = []
        for i in 0..<min(query.resultCount, 500) {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard roots.contains(where: { FileIndexService.isDescendantOrSame(url, of: $0) }) else { continue }
            let attributes = ["kMDItemTitle", "kMDItemKeywords", "kMDItemAuthors", "kMDItemContentType"].compactMap { key -> String? in
                if let values = item.value(forAttribute: key) as? [String] { return values.joined(separator: " ") }
                return item.value(forAttribute: key) as? String
            }
            hits.append(.init(path: url.path,
                              name: item.value(forAttribute: "kMDItemFSName") as? String ?? url.lastPathComponent,
                              modifiedAt: item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date,
                              metadata: attributes.joined(separator: " ")))
        }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        continuation.resume(returning: .init(hits: hits, completed: completed,
            detail: completed ? "Spotlight retornou \(hits.count) correspondência(s) nas pastas autorizadas; a busca local complementou o resultado." : "Spotlight não concluiu no prazo; a busca local foi mantida."))
    }
}
#endif

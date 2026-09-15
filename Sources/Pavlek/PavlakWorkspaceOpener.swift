#if os(macOS)
import AppKit
import Foundation

enum PavlakWorkspaceOpenError: LocalizedError, Equatable {
    case rejected

    var errorDescription: String? {
        "O macOS não conseguiu abrir o item solicitado."
    }
}

@MainActor
enum PavlakWorkspaceOpener {
    static func open(_ url: URL) throws {
        try open(url, using: { NSWorkspace.shared.open($0) })
    }

    static func open(_ url: URL, using opener: (URL) -> Bool) throws {
        guard opener(url) else { throw PavlakWorkspaceOpenError.rejected }
    }
}
#endif

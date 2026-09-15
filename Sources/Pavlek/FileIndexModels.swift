#if os(macOS)
import Foundation

struct IndexedFile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let rootID: String
    let name: String
    let relativePath: String
    let fileExtension: String
    let modifiedAt: Date?
}

struct AuthorizedFileRoot: Identifiable, Codable, Sendable {
    let id: String
    let displayName: String
    let bookmark: Data
}

struct FileIndexSnapshot: Codable, Sendable {
    var schemaVersion = 1
    var roots: [AuthorizedFileRoot] = []
    var files: [IndexedFile] = []
    var updatedAt: Date?
}

struct FileSearchCandidate: Identifiable, Sendable {
    let file: IndexedFile
    let score: Int
    var id: String { file.id }
}

struct RemoteFileRequest: Codable, Sendable {
    let command: String
    let originatingDeviceID: String?
    let createdAt: Date
}
#endif

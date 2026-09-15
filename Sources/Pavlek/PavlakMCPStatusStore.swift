#if os(macOS)
import Foundation

struct PavlakMCPStatusSnapshot: Codable, Sendable {
    let pavlakState: String
    let availableIntegrations: [String]
    let selectedDocumentCount: Int
    let currentOperation: String?
    let updatedAt: Date

    init(
        pavlakState: String,
        availableIntegrations: [String],
        selectedDocumentCount: Int,
        currentOperation: String?,
        updatedAt: Date = Date()
    ) {
        self.pavlakState = pavlakState
        self.availableIntegrations = availableIntegrations
        self.selectedDocumentCount = selectedDocumentCount
        self.currentOperation = currentOperation
        self.updatedAt = updatedAt
    }
}

actor PavlakMCPStatusStore {
    static let shared = PavlakMCPStatusStore()

    private let fileURL: URL
    private let encoder: JSONEncoder

    private init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base
            .appendingPathComponent("Pavlak", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("status.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func publish(_ snapshot: PavlakMCPStatusSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            Task { @MainActor in
                PavlakErrorReporter.shared.report(
                    module: "PavlakMCPStatusStore",
                    action: "publicar_estado",
                    message: "Não foi possível atualizar o estado de leitura do Pavlak.",
                    error: error,
                    result: "erro_recuperado"
                )
            }
        }
    }
}
#endif

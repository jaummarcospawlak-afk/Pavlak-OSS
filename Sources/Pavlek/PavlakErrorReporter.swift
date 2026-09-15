import Foundation
import OSLog

#if os(macOS)
import AppKit
#endif

struct PavlakErrorRecord: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let module: String
    let action: String
    let message: String
    let underlyingError: String
    let result: String
}

struct PavlakOperationRecord: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let module: String
    let action: String
}

@MainActor
final class PavlakErrorReporter: ObservableObject {
    static let shared = PavlakErrorReporter()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pavlek", category: "ErrorReporter")
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "Pavlak.ErrorReportsFolderBookmark.v1"
    private let pendingKey = "Pavlak.PendingOperations.v1"
    private let queuedKey = "Pavlak.QueuedErrorRecords.v1"
    private var initialized = false

    private init() { }

    func initialize() {
        guard !initialized else { return }
        initialized = true
        let interrupted = pendingOperations()
        savePending([])
        for operation in interrupted {
            let record = PavlakErrorRecord(
                id: UUID(), timestamp: Date(), module: operation.module, action: operation.action,
                message: "A operação não foi concluída antes do encerramento do aplicativo.",
                underlyingError: "Operação iniciada em \(operation.startedAt.formatted(.iso8601)) sem registro de conclusão.",
                result: "encerramento_anormal"
            )
            persistOrQueue(record)
        }
        flushQueuedRecords()
    }

    @discardableResult
    func begin(module: String, action: String) -> UUID {
        initialize()
        let operation = PavlakOperationRecord(id: UUID(), startedAt: Date(), module: module, action: action)
        var pending = pendingOperations()
        pending.append(operation)
        savePending(pending)
        logger.notice("Operação iniciada — módulo: \(module, privacy: .public), ação: \(action, privacy: .public), id: \(operation.id.uuidString, privacy: .public)")
        return operation.id
    }

    func finish(_ operationID: UUID, result: String) {
        var pending = pendingOperations()
        pending.removeAll { $0.id == operationID }
        savePending(pending)
        logger.info("Operação concluída — id: \(operationID.uuidString, privacy: .public), resultado: \(result, privacy: .public)")
    }

    func report(module: String, action: String, message: String, error: Error?, result: String) {
        initialize()
        let technical = Self.safeTechnicalDescription(for: error)
        let record = PavlakErrorRecord(
            id: UUID(), timestamp: Date(), module: module, action: action,
            message: message, underlyingError: technical, result: result
        )
        logger.error("\(module, privacy: .public) — \(action, privacy: .public): \(technical, privacy: .private)")
        persistOrQueue(record)
    }

    nonisolated static func safeTechnicalDescription(for error: Error?) -> String {
        guard let error else { return "Sem erro técnico adicional" }
        #if os(macOS)
        if let apiError = error as? OpenAIAPIError {
            var fields = ["category: \(apiError.category)"]
            if let statusCode = apiError.statusCode { fields.append("statusCode: \(statusCode)") }
            if let apiType = apiError.apiType { fields.append("apiType: \(apiType)") }
            if let apiCode = apiError.apiCode { fields.append("apiCode: \(apiCode)") }
            if let requestID = apiError.requestID { fields.append("requestID: \(requestID)") }
            return "OpenAIAPIError(" + fields.joined(separator: ", ") + ")"
        }
        #endif
        return String(reflecting: error)
    }

    #if os(macOS)
    var requiresFolderSelection: Bool { resolveReportsFolder() == nil }

    func selectReportsFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Selecione a pasta Relatorios de Erro"
        panel.message = "O Pavlak salvará novos relatórios cronológicos somente nesta pasta."
        panel.prompt = "Selecionar"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: bookmarkKey)
            flushQueuedRecords()
            return true
        } catch {
            logger.error("Falha ao salvar bookmark da pasta de relatórios: \(String(reflecting: error), privacy: .private)")
            return false
        }
    }
    #endif

    func runInternalValidationError() {
        report(
            module: "PavlakErrorReporter", action: "validacao_interna",
            message: "Erro recuperável de teste gerado para validar o registro cronológico.",
            error: ValidationError.expected, result: "erro_recuperado"
        )
    }

    private func persistOrQueue(_ record: PavlakErrorRecord) {
        if !write(record) {
            var queued = queuedRecords()
            queued.append(record)
            defaults.set(try? JSONEncoder().encode(queued), forKey: queuedKey)
        }
    }

    private func flushQueuedRecords() {
        let queued = queuedRecords()
        guard !queued.isEmpty else { return }
        var remaining: [PavlakErrorRecord] = []
        for record in queued where !write(record) { remaining.append(record) }
        defaults.set(try? JSONEncoder().encode(remaining), forKey: queuedKey)
    }

    private func write(_ record: PavlakErrorRecord) -> Bool {
        #if os(macOS)
        guard let folder = resolveReportsFolder() else { return false }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let filename = "\(formatter.string(from: record.timestamp))-\(record.id.uuidString).json"
            try encoder.encode(record).write(to: folder.appendingPathComponent(filename), options: .withoutOverwriting)
            return true
        } catch {
            logger.error("Falha ao gravar relatório: \(String(reflecting: error), privacy: .private)")
            return false
        }
        #else
        return false
        #endif
    }

    #if os(macOS)
    private func resolveReportsFolder() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }
    #endif

    private func pendingOperations() -> [PavlakOperationRecord] {
        guard let data = defaults.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([PavlakOperationRecord].self, from: data)) ?? []
    }

    private func savePending(_ operations: [PavlakOperationRecord]) {
        defaults.set(try? JSONEncoder().encode(operations), forKey: pendingKey)
    }

    private func queuedRecords() -> [PavlakErrorRecord] {
        guard let data = defaults.data(forKey: queuedKey) else { return [] }
        return (try? JSONDecoder().decode([PavlakErrorRecord].self, from: data)) ?? []
    }

    private enum ValidationError: Error { case expected }
}

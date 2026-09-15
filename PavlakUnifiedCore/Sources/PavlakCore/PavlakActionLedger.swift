import Foundation

public actor PavlakActionLedger {
    public static let shared = PavlakActionLedger()

    private var records: [PavlakActionRecord] = []
    private let capacity: Int
    private let logDirectory: URL?

    public init(capacity: Int = 500, logDirectory: URL? = PavlakActionLedger.defaultLogDirectory()) {
        self.capacity = max(50, capacity)
        self.logDirectory = logDirectory
    }

    public func append(action: PavlakAction, result: String, succeeded: Bool) {
        append(
            tool: action.toolName.rawValue,
            arguments: action.argumentsForLog,
            result: result,
            succeeded: succeeded
        )
    }

    public func append(
        tool: String,
        arguments: [String: String],
        result: String,
        succeeded: Bool
    ) {
        let record = PavlakActionRecord(
            tool: tool,
            arguments: arguments,
            result: String(result.prefix(2_000)),
            succeeded: succeeded
        )
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        persist(record)
    }

    public func recent(limit: Int = 20) -> [PavlakActionRecord] {
        Array(records.suffix(max(1, min(limit, 100))).reversed())
    }

    private func persist(_ record: PavlakActionRecord) {
        guard let logDirectory else { return }
        do {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let url = logDirectory.appendingPathComponent("acoes-\(formatter.string(from: record.date)).jsonl")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(record)
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // O log nunca pode interromper uma ação do usuário.
        }
    }

    public static func defaultLogDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("Pavlak/Registros", isDirectory: true)
    }
}

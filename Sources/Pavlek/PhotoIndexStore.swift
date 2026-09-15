import Foundation

/// Source of truth for the iOS photo index. Core Spotlight is a disposable projection.
actor PhotoIndexStore {
    static let folderName = "Pavlak Photo Index"
    static let primaryFilename = "index-v1.json"
    static let backupFilename = "index-v1.backup.json"
    static let journalFilename = "index-v1.pending.json"

    private(set) var snapshot: PhotoIndexSnapshot
    let fileURL: URL
    let backupURL: URL
    let journalURL: URL
    let directoryURL: URL
    private let fileManager: FileManager
    private var didLoad = false

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        deviceID: String = UUID().uuidString
    ) {
        self.fileManager = fileManager
        let support = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.folderName, isDirectory: true)
        directoryURL = support
        fileURL = support.appendingPathComponent(Self.primaryFilename)
        backupURL = support.appendingPathComponent(Self.backupFilename)
        journalURL = support.appendingPathComponent(Self.journalFilename)
        snapshot = PhotoIndexSnapshot()
        snapshot.sourceDeviceID = deviceID
    }

    func currentSnapshot() -> PhotoIndexSnapshot {
        loadIfNeeded()
        return snapshot
    }

    func knownIdentifiers() -> Set<String> {
        loadIfNeeded()
        return Set(snapshot.assets.map(\.sourceLocalIdentifier))
    }

    func record(forSourceIdentifier id: String) -> IndexedPhoto? {
        loadIfNeeded()
        return snapshot.assets.first { $0.sourceLocalIdentifier == id }
    }

    func beginUpdate(
        placeholders: [IndexedPhoto],
        visibleSourceIdentifiers: Set<String>,
        authorization: PhotoIndexAuthorizationScope,
        at date: Date = Date()
    ) throws {
        loadIfNeeded()
        var candidate = snapshot
        candidate.authorizationScope = authorization
        candidate.updateState = .inProgress
        candidate.lastIncrementalUpdate = date
        merge(placeholders, into: &candidate)
        if authorization == .limited {
            candidate.assets.removeAll { !visibleSourceIdentifiers.contains($0.sourceLocalIdentifier) }
        }
        try persist(candidate, restrictedScope: authorization == .limited)
    }

    @discardableResult
    func completeUpdate(
        records: [IndexedPhoto],
        visibleSourceIdentifiers: Set<String>,
        authorization: PhotoIndexAuthorizationScope,
        duration: TimeInterval?,
        at date: Date = Date()
    ) throws -> Int {
        loadIfNeeded()
        var candidate = snapshot
        let removed = authorization.canRead
            ? candidate.assets.lazy.filter { !visibleSourceIdentifiers.contains($0.sourceLocalIdentifier) }.count
            : candidate.assets.count
        merge(records, into: &candidate)
        if authorization.canRead {
            candidate.assets.removeAll { !visibleSourceIdentifiers.contains($0.sourceLocalIdentifier) }
        } else {
            // Revocation removes queryable metadata/OCR from the local index; originals remain in Photos.
            candidate.assets = []
        }
        candidate.authorizationScope = authorization
        candidate.updateState = .idle
        candidate.lastIncrementalUpdate = date
        candidate.lastCompletedUpdate = date
        candidate.generation += 1
        if candidate.initialIndexDuration == nil { candidate.initialIndexDuration = duration }
        candidate.recoveryNotice = nil
        try persist(candidate, restrictedScope: authorization == .limited)
        return removed
    }

    func applyAuthorization(
        _ authorization: PhotoIndexAuthorizationScope,
        visibleSourceIdentifiers: Set<String>? = nil,
        at date: Date = Date()
    ) throws {
        loadIfNeeded()
        if !authorization.canRead {
            try purgeDerivedData(authorization: authorization, at: date)
            return
        }
        if authorization == .limited, snapshot.authorizationScope != .limited {
            try purgeDerivedData(authorization: authorization, at: date)
            return
        }
        if authorization == .limited, let visibleSourceIdentifiers {
            var candidate = snapshot
            candidate.assets.removeAll { !visibleSourceIdentifiers.contains($0.sourceLocalIdentifier) }
            candidate.authorizationScope = .limited
            candidate.lastIncrementalUpdate = date
            try persist(candidate, restrictedScope: true)
            return
        }
        guard snapshot.authorizationScope != authorization else { return }
        var candidate = snapshot
        candidate.authorizationScope = authorization
        candidate.lastIncrementalUpdate = date
        try persist(candidate)
    }

    /// Removes only Pavlak-owned derived photo-index files. PhotoKit originals are never touched.
    /// This path deliberately does not rotate the former primary into the backup, because doing so
    /// could reintroduce OCR or metadata after access is revoked.
    func purgeDerivedData(
        authorization: PhotoIndexAuthorizationScope,
        at date: Date = Date()
    ) throws {
        loadIfNeeded()
        var empty = PhotoIndexSnapshot()
        empty.sourceDeviceID = snapshot.sourceDeviceID
        empty.generation = snapshot.generation + 1
        empty.authorizationScope = authorization
        empty.lastIncrementalUpdate = date
        empty.lastCompletedUpdate = date
        empty.updateState = .idle
        empty.recoveryNotice = "Dados derivados da Fototeca removidos após mudança de autorização."

        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for name in names where name == Self.primaryFilename
            || name == Self.backupFilename
            || name == Self.journalFilename
            || name.hasPrefix("index-v1.corrupt-") {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(empty).write(to: fileURL, options: .atomic)
        snapshot = empty
    }

    func byteCount() -> Int64 {
        loadIfNeeded()
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Loading the persisted index is deliberately deferred until the actor is
    /// first used. PhotoIndexer is a MainActor object; doing this work in its
    /// initializer made launch synchronously read and decode the entire index.
    private func loadIfNeeded() {
        guard !didLoad else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        snapshot = Self.load(
            fileManager: fileManager,
            primaryURL: fileURL,
            backupURL: backupURL,
            journalURL: journalURL,
            fallbackDeviceID: snapshot.sourceDeviceID
        )
        didLoad = true
    }

    private func merge(_ records: [IndexedPhoto], into candidate: inout PhotoIndexSnapshot) {
        var keyed = Dictionary(uniqueKeysWithValues: candidate.assets.map { ($0.id, $0) })
        records.forEach { keyed[$0.id] = $0 }
        candidate.assets = Array(keyed.values).sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
    }

    private func persist(_ candidate: PhotoIndexSnapshot, restrictedScope: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(candidate)
        try data.write(to: journalURL, options: .atomic)
        if restrictedScope {
            try? fileManager.removeItem(at: backupURL)
            let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
            for name in names where name.hasPrefix("index-v1.corrupt-") {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        } else if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
        if restrictedScope {
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try? fileManager.removeItem(at: journalURL)
        snapshot = candidate
    }

    private static func load(
        fileManager: FileManager,
        primaryURL: URL,
        backupURL: URL,
        journalURL: URL,
        fallbackDeviceID: String
    ) -> PhotoIndexSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let candidates: [(URL, String)] = [
            (journalURL, "Atualização interrompida recuperada do diário transacional."),
            (primaryURL, ""),
            (backupURL, "Índice principal inconsistente; cópia de segurança recuperada.")
        ]
        for (url, notice) in candidates where fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  var decoded = try? decoder.decode(PhotoIndexSnapshot.self, from: data),
                  decoded.schemaVersion <= PhotoIndexSnapshot.currentSchemaVersion else {
                if url == primaryURL { preserveCorrupt(fileManager: fileManager, url: url) }
                continue
            }
            decoded = migrate(decoded, fallbackDeviceID: fallbackDeviceID)
            decoded = repair(decoded)
            if !notice.isEmpty { decoded.recoveryNotice = notice }
            return decoded
        }
        var empty = PhotoIndexSnapshot()
        empty.sourceDeviceID = fallbackDeviceID
        if fileManager.fileExists(atPath: primaryURL.path) {
            empty.recoveryNotice = PhotoIndexError.inconsistentIndex.localizedDescription
        }
        return empty
    }

    private static func migrate(_ value: PhotoIndexSnapshot, fallbackDeviceID: String) -> PhotoIndexSnapshot {
        var migrated = value
        let deviceID = value.sourceDeviceID.isEmpty || value.sourceDeviceID == "legacy-device"
            ? fallbackDeviceID : value.sourceDeviceID
        migrated.sourceDeviceID = deviceID
        migrated.schemaVersion = PhotoIndexSnapshot.currentSchemaVersion
        migrated.storageAuthority = .transactionalJSON
        migrated.assets = value.assets.map { item in
            let stableID = item.id.hasPrefix("pavlak-photo-")
                ? item.id
                : PhotoStableIdentifier.make(deviceID: deviceID, assetLocalIdentifier: item.sourceLocalIdentifier)
            var state = item.processingState
            if state == .processing { state = .interrupted }
            return IndexedPhoto(
                id: stableID, sourceLocalIdentifier: item.sourceLocalIdentifier, sourceDeviceID: deviceID,
                sourceDevice: item.sourceDevice, sourceKind: item.sourceKind, contentType: item.contentType,
                creationDate: item.creationDate, modificationDate: item.modificationDate,
                width: item.width, height: item.height, originalFilename: item.originalFilename,
                albumAssociations: item.albumAssociations, originalEvidence: item.originalEvidence,
                category: item.category, normalizedOCRText: item.normalizedOCRText,
                extractedTextEvidence: item.extractedTextEvidence,
                classificationEvidence: item.classificationEvidence,
                contentAvailability: item.contentAvailability, processingState: state,
                processingError: item.processingError, indexedAt: item.indexedAt,
                sourceFingerprint: item.sourceFingerprint
            )
        }
        if migrated.updateState == .inProgress { migrated.updateState = .interrupted }
        return migrated
    }

    private static func repair(_ value: PhotoIndexSnapshot) -> PhotoIndexSnapshot {
        var repaired = value
        var seen = Set<String>()
        repaired.assets = value.assets
            .sorted { $0.indexedAt > $1.indexedAt }
            .filter { seen.insert($0.id).inserted && !$0.sourceLocalIdentifier.isEmpty }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return repaired
    }

    private static func preserveCorrupt(fileManager: FileManager, url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let preserved = url.deletingLastPathComponent().appendingPathComponent("index-v1.corrupt-\(stamp).json")
        try? fileManager.copyItem(at: url, to: preserved)
    }
}

import XCTest
@testable import Pavlek

final class PhotoIndexStoreTests: XCTestCase {
    func testInitializationDefersDiskLoadUntilActorAccess() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = PhotoIndexStore(directory: directory, deviceID: "iphone-deferred")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let loaded = PhotoIndexStore(directory: directory, deviceID: "iphone-deferred")
        let snapshot = await loaded.currentSnapshot()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(snapshot.sourceDeviceID, "iphone-deferred")
    }

    func testMigratesRealV1ShapeAndSeparatesEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"schemaVersion":1,"assets":[{"id":"legacy/local-id","creationDate":"2026-01-02T03:04:05Z","mediaType":"Foto","width":1200,"height":900,"originalFilename":"conta.jpg","category":"Documentos","normalizedOCRText":"conta energia","indexedAt":"2026-01-03T03:04:05Z"}],"lastIncrementalUpdate":"2026-01-03T03:04:05Z"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent(PhotoIndexStore.primaryFilename))

        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-fixture")
        let snapshot = await store.currentSnapshot()
        let item = try XCTUnwrap(snapshot.assets.first)

        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.sourceDeviceID, "iphone-fixture")
        XCTAssertEqual(item.id, PhotoStableIdentifier.make(deviceID: "iphone-fixture", assetLocalIdentifier: "legacy/local-id"))
        XCTAssertEqual(item.sourceLocalIdentifier, "legacy/local-id")
        XCTAssertEqual(item.originalEvidence.provider, "PhotoKit")
        XCTAssertEqual(item.normalizedOCRText, "conta energia")
        XCTAssertNil(item.extractedTextEvidence, "Texto legado não pode ser promovido silenciosamente a evidência estruturada nova.")
        XCTAssertEqual(item.category, .document)
    }

    func testPersistsAndReopensAuthoritativeSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = makeRecord(localID: "asset-a", fingerprint: "v1", text: "contrato locacao")
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-fixture")
        _ = try await store.completeUpdate(records: [record], visibleSourceIdentifiers: ["asset-a"], authorization: .limited, duration: 1.2)

        let reopened = PhotoIndexStore(directory: directory, deviceID: "different-fallback")
        let snapshot = await reopened.currentSnapshot()

        XCTAssertEqual(snapshot.sourceDeviceID, "iphone-fixture")
        XCTAssertEqual(snapshot.assets, [record])
        XCTAssertEqual(snapshot.authorizationScope, .limited)
        XCTAssertEqual(snapshot.storageAuthority, .transactionalJSON)
        XCTAssertEqual(snapshot.generation, 1)
    }

    func testRecoversInterruptedJournalAndMarksProcessingItemInterrupted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var snapshot = PhotoIndexSnapshot()
        snapshot.sourceDeviceID = "iphone-journal"
        snapshot.updateState = .inProgress
        var record = makeRecord(localID: "asset-journal", fingerprint: "v1", text: "")
        record.processingState = .processing
        snapshot.assets = [record]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent(PhotoIndexStore.journalFilename))

        let recovered = await PhotoIndexStore(directory: directory, deviceID: "fallback").currentSnapshot()

        XCTAssertEqual(recovered.updateState, .interrupted)
        XCTAssertEqual(recovered.assets.first?.processingState, .interrupted)
        XCTAssertTrue(recovered.recoveryNotice?.contains("diário") == true)
    }

    func testCorruptPrimaryFallsBackToBackupWithoutDestroyingCorruptBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-backup")
        let record = makeRecord(localID: "asset-a", fingerprint: "v1", text: "texto")
        _ = try await store.completeUpdate(records: [record], visibleSourceIdentifiers: ["asset-a"], authorization: .authorized, duration: nil)
        _ = try await store.completeUpdate(records: [record], visibleSourceIdentifiers: ["asset-a"], authorization: .authorized, duration: nil)
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: directory.appendingPathComponent(PhotoIndexStore.primaryFilename), options: .atomic)

        let recovered = await PhotoIndexStore(directory: directory, deviceID: "fallback").currentSnapshot()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        XCTAssertEqual(recovered.assets.first?.sourceLocalIdentifier, "asset-a")
        XCTAssertTrue(recovered.recoveryNotice?.contains("cópia de segurança") == true)
        XCTAssertTrue(names.contains { $0.hasPrefix("index-v1.corrupt-") })
    }

    func testIncrementalInsertChangeDeleteLimitedScopeAndRevocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-incremental")
        let first = makeRecord(localID: "a", fingerprint: "v1", text: "original")
        let second = makeRecord(localID: "b", fingerprint: "v1", text: "segundo")
        _ = try await store.completeUpdate(records: [first, second], visibleSourceIdentifiers: ["a", "b"], authorization: .authorized, duration: nil)
        let changed = makeRecord(localID: "a", fingerprint: "v2", text: "alterado")
        let removed = try await store.completeUpdate(records: [changed], visibleSourceIdentifiers: ["a"], authorization: .limited, duration: nil)

        var snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.assets.count, 1)
        XCTAssertEqual(snapshot.assets.first?.sourceFingerprint, "v2")
        XCTAssertEqual(snapshot.assets.first?.normalizedOCRText, "alterado")
        XCTAssertEqual(snapshot.authorizationScope, .limited)
        XCTAssertEqual(removed, 1)

        try await store.applyAuthorization(.denied)
        snapshot = await store.currentSnapshot()
        XCTAssertTrue(snapshot.assets.isEmpty)
        XCTAssertEqual(snapshot.authorizationScope, .denied)
    }

    func testRevocationPurgesEveryDerivedRecoveryCopyAndCannotRestoreOldData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-purge")
        let record = makeRecord(localID: "private-asset", fingerprint: "v1", text: "texto derivado")
        _ = try await store.completeUpdate(
            records: [record], visibleSourceIdentifiers: ["private-asset"],
            authorization: .authorized, duration: nil
        )
        _ = try await store.completeUpdate(
            records: [record], visibleSourceIdentifiers: ["private-asset"],
            authorization: .authorized, duration: nil
        )
        try Data("pending-private".utf8).write(to: directory.appendingPathComponent(PhotoIndexStore.journalFilename))
        try Data("corrupt-private".utf8).write(to: directory.appendingPathComponent("index-v1.corrupt-fixture.json"))

        try await store.applyAuthorization(.denied)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [PhotoIndexStore.primaryFilename])
        let revoked = await store.currentSnapshot()
        XCTAssertTrue(revoked.assets.isEmpty)
        XCTAssertEqual(revoked.authorizationScope, .denied)

        let reopened = PhotoIndexStore(directory: directory, deviceID: "fallback")
        let recovered = await reopened.currentSnapshot()
        XCTAssertTrue(recovered.assets.isEmpty)
        XCTAssertEqual(recovered.authorizationScope, .denied)
    }

    func testLimitedScopeBackupCannotContainItemsFromPreviousFullAccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-limited")
        let allowed = makeRecord(localID: "allowed", fingerprint: "v1", text: "permitido")
        let removed = makeRecord(localID: "removed", fingerprint: "v1", text: "fora do escopo")
        _ = try await store.completeUpdate(
            records: [allowed, removed], visibleSourceIdentifiers: ["allowed", "removed"],
            authorization: .authorized, duration: nil
        )
        try Data("old-corrupt".utf8).write(to: directory.appendingPathComponent("index-v1.corrupt-old.json"))

        _ = try await store.completeUpdate(
            records: [allowed], visibleSourceIdentifiers: ["allowed"],
            authorization: .limited, duration: nil
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let primary = try decoder.decode(
            PhotoIndexSnapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent(PhotoIndexStore.primaryFilename))
        )
        let backup = try decoder.decode(
            PhotoIndexSnapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent(PhotoIndexStore.backupFilename))
        )
        XCTAssertEqual(primary.assets.map(\.sourceLocalIdentifier), ["allowed"])
        XCTAssertEqual(backup.assets.map(\.sourceLocalIdentifier), ["allowed"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains("index-v1.corrupt-old.json"))
    }

    func testLimitedStartupReconciliationSanitizesExistingPrimaryAndBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-limited-reopen")
        let visible = makeRecord(localID: "visible", fingerprint: "v1", text: "permitido")
        let deselected = makeRecord(localID: "deselected", fingerprint: "v1", text: "removido")
        _ = try await store.completeUpdate(
            records: [visible, deselected], visibleSourceIdentifiers: ["visible", "deselected"],
            authorization: .limited, duration: nil
        )

        try await store.applyAuthorization(.limited, visibleSourceIdentifiers: ["visible"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for filename in [PhotoIndexStore.primaryFilename, PhotoIndexStore.backupFilename] {
            let saved = try decoder.decode(
                PhotoIndexSnapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent(filename))
            )
            XCTAssertEqual(saved.assets.map(\.sourceLocalIdentifier), ["visible"])
        }
    }

    func testUnavailableLocalContentRemainsExplicitlyUnprocessed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoIndexStore(directory: directory, deviceID: "iphone-cloud")
        var pending = makeRecord(localID: "cloud", fingerprint: "v1", text: "")
        pending.category = .pendingCloud
        pending.contentAvailability = .cloudOnly
        pending.processingState = .waitingForLocalContent
        pending.extractedTextEvidence = nil
        _ = try await store.completeUpdate(records: [pending], visibleSourceIdentifiers: ["cloud"], authorization: .authorized, duration: nil)

        let snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.pendingContentCount, 1)
        XCTAssertEqual(snapshot.assets.first?.processingState, .waitingForLocalContent)
        XCTAssertNil(snapshot.assets.first?.extractedTextEvidence)
        XCTAssertNotEqual(snapshot.assets.first?.processingState, .processed)
    }

    func testContextualQueryReturnsStableOriginAndSeparatedEvidence() {
        var snapshot = PhotoIndexSnapshot()
        snapshot.sourceDeviceID = "iphone-fixture"
        let record = makeRecord(localID: "conta-energia", fingerprint: "v1", text: "Fatura de energia 123 kWh")
        snapshot.assets = [record]

        let match = PhotoIndexQueryEngine.search(query: "localize minha conta de energia", in: snapshot).first

        XCTAssertEqual(match?.id, record.id)
        XCTAssertEqual(match?.sourceLocalIdentifier, "conta-energia")
        XCTAssertEqual(match?.sourceDeviceID, "iphone-fixture")
        XCTAssertEqual(match?.sourceDevice, .iPhone)
        XCTAssertEqual(match?.sourceKind, .photoLibrary)
        XCTAssertTrue(match?.evidenceSummary.contains("metadados originais PhotoKit") == true)
        XCTAssertTrue(match?.evidenceSummary.contains("texto extraído por Vision OCR") == true)
        XCTAssertTrue(match?.evidenceSummary.contains("classificação inferida") == true)
        XCTAssertTrue(match?.canPreviewLocally == true)
    }

    func testContextualQueryDoesNotPromoteLegacyTextWithoutExtractionEvidence() {
        var snapshot = PhotoIndexSnapshot()
        var legacyOnly = makeRecord(localID: "legacy", fingerprint: "v1", text: "segredo legado")
        legacyOnly.extractedTextEvidence = nil
        legacyOnly.normalizedOCRText = "segredo legado"
        legacyOnly = IndexedPhoto(
            id: legacyOnly.id, sourceLocalIdentifier: legacyOnly.sourceLocalIdentifier,
            sourceDeviceID: legacyOnly.sourceDeviceID, sourceDevice: legacyOnly.sourceDevice,
            sourceKind: legacyOnly.sourceKind, contentType: legacyOnly.contentType,
            creationDate: legacyOnly.creationDate, modificationDate: legacyOnly.modificationDate,
            width: legacyOnly.width, height: legacyOnly.height, originalFilename: "imagem.jpg",
            albumAssociations: [], originalEvidence: legacyOnly.originalEvidence,
            category: legacyOnly.category, normalizedOCRText: legacyOnly.normalizedOCRText,
            extractedTextEvidence: nil, classificationEvidence: legacyOnly.classificationEvidence,
            contentAvailability: legacyOnly.contentAvailability, processingState: legacyOnly.processingState,
            processingError: legacyOnly.processingError, indexedAt: legacyOnly.indexedAt,
            sourceFingerprint: legacyOnly.sourceFingerprint
        )
        snapshot.assets = [legacyOnly]

        XCTAssertTrue(PhotoIndexQueryEngine.search(query: "segredo", in: snapshot).isEmpty)
    }

    func testQueryDoesNotReturnInProgressOrInterruptedRecords() {
        var snapshot = PhotoIndexSnapshot()
        var record = makeRecord(localID: "processing", fingerprint: "v1", text: "contrato")
        record.processingState = .processing
        snapshot.assets = [record]
        XCTAssertTrue(PhotoIndexQueryEngine.search(query: "contrato", in: snapshot).isEmpty)

        record.processingState = .interrupted
        snapshot.assets = [record]
        XCTAssertTrue(PhotoIndexQueryEngine.search(query: "contrato", in: snapshot).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoIndexTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRecord(localID: String, fingerprint: String, text: String) -> IndexedPhoto {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deviceID = "iphone-fixture"
        let normalized = text.lowercased()
        return IndexedPhoto(
            id: PhotoStableIdentifier.make(deviceID: deviceID, assetLocalIdentifier: localID),
            sourceLocalIdentifier: localID, sourceDeviceID: deviceID,
            contentType: "public.jpeg", creationDate: now, modificationDate: now,
            width: 100, height: 200, originalFilename: "\(localID).jpg",
            albumAssociations: [.init(albumLocalIdentifier: "album-1", title: "Documentos", observedAt: now, provider: "PhotoKit")],
            originalEvidence: .init(provider: "PhotoKit", observedAt: now, assetLocalIdentifier: localID),
            category: .document, normalizedOCRText: normalized,
            extractedTextEvidence: .init(text: text, normalizedText: normalized, extractor: "Vision OCR", extractedAt: now),
            classificationEvidence: .init(category: .document, classifier: "fixture", basis: "document contour", confidence: 1, classifiedAt: now),
            contentAvailability: .local, processingState: .processed,
            indexedAt: now, sourceFingerprint: fingerprint
        )
    }
}

final class PavlakLinkAuthenticationTests: XCTestCase {
    func testAcceptsAuthenticMessageAndRejectsTamperingOrStaleReplay() {
        let secret = Data("shared-secret-123".utf8)
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let message = PavlakLinkMessage(
            requestID: UUID(), sourceDevice: .mac, targetDevice: .iPhone,
            action: .photoSearch, query: "contrato", payload: nil,
            status: .requested, result: nil, sentAt: sentAt
        )
        let signed = PavlakLinkAuthenticator.sign(message, secret: secret, nonce: "nonce-1")
        XCTAssertTrue(PavlakLinkAuthenticator.verify(signed, secret: secret, now: sentAt))

        let tampered = PavlakLinkMessage(
            requestID: signed.requestID, sourceDevice: signed.sourceDevice, targetDevice: signed.targetDevice,
            action: signed.action, query: "outro conteúdo", payload: signed.payload,
            status: signed.status, result: signed.result, sentAt: signed.sentAt,
            authentication: signed.authentication
        )
        XCTAssertFalse(PavlakLinkAuthenticator.verify(tampered, secret: secret, now: sentAt))
        XCTAssertFalse(PavlakLinkAuthenticator.verify(signed, secret: secret, now: sentAt.addingTimeInterval(301)))
    }

    func testTLS13PSKDerivationIsDeterministicAndPairingSpecific() {
        let first = PavlakLinkTLS.derivedKey(secret: Data("pairing-code-a".utf8))
        let repeated = PavlakLinkTLS.derivedKey(secret: Data("pairing-code-a".utf8))
        let other = PavlakLinkTLS.derivedKey(secret: Data("pairing-code-b".utf8))

        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, other)
        XCTAssertFalse(PavlakLinkTLS.identity.isEmpty)
    }
}

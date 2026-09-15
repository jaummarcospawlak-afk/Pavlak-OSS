#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class PavlakDocumentFlowTests: XCTestCase {
    private func fixture() throws -> (URL, FileIndexService) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PavlekFlow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, FileIndexService(store: FileIndexStore(directory: directory.appendingPathComponent("index"))))
    }

    func testABCRealFilesAndContextualResidence() async throws {
        let (base, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let docs = base.appendingPathComponent("Documentos")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "Conta de água. Endereço: Rua Fictícia 123.".write(to: docs.appendingPathComponent("digitalizacao.txt"), atomically: true, encoding: .utf8)
        try "Contrato fictício de prestação de serviços".write(to: docs.appendingPathComponent("contrato.txt"), atomically: true, encoding: .utf8)
        try "Ingresso para evento de teste".write(to: docs.appendingPathComponent("ingresso.txt"), atomically: true, encoding: .utf8)
        await index.index(directory: docs)
        XCTAssertNil(index.errorMessage, index.errorMessage ?? "")
        for (command, expected) in [
            ("Pavlak, encontre meu comprovante de residência", "digitalizacao.txt"),
            ("Pavlak, encontre meu contrato", "contrato.txt"),
            ("Pavlak, encontre o ingresso de hoje", "ingresso.txt")
        ] {
            let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize(command))
            let response = await PavlakFileSearchProvider(index: index).search(query)
            let ranked = LocalUnifiedSearchRanker.rank(query: query, records: response.records)
            XCTAssertEqual(ranked.first?.title, expected, command)
            let scoped = await index.authorizedSnapshot()
            let selected = try XCTUnwrap(scoped.files.first { $0.name == expected })
            let resolved = try await index.resolveForPreview(selected)
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolved.path))
            resolved.stopAccessingSecurityScopedResource()
        }
    }

    func testDNoResults() async throws {
        let (base, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let docs = base.appendingPathComponent("Vazia")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        await index.index(directory: docs)
        XCTAssertNil(index.errorMessage, index.errorMessage ?? "")
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu contrato inexistente"))
        let response = await PavlakFileSearchProvider(index: index).search(query)
        XCTAssertTrue(response.records.isEmpty)
        XCTAssertTrue(response.status.wasConsulted)
    }

    func testENoPermissionDoesNotReadExistingFiles() async throws {
        let (base, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try "Contrato privado".write(to: base.appendingPathComponent("contrato.txt"), atomically: true, encoding: .utf8)
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu contrato"))
        let response = await PavlakFileSearchProvider(index: index).search(query)
        XCTAssertTrue(response.records.isEmpty)
        guard case .blocked = response.status else { return XCTFail("Must require authorization") }
    }

    func testMovedFileFailsWithoutOpeningAndSymlinkCannotEscapeRoot() async throws {
        let (base, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let docs = base.appendingPathComponent("Allowed")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let original = docs.appendingPathComponent("contrato.txt")
        try "Contrato".write(to: original, atomically: true, encoding: .utf8)
        try "Não autorizado".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("escape.txt"), withDestinationURL: base.appendingPathComponent("outside.txt"))
        await index.index(directory: docs)
        XCTAssertNil(index.errorMessage, index.errorMessage ?? "")
        XCTAssertFalse(index.snapshot.files.contains { $0.name == "escape.txt" })
        let file = try XCTUnwrap(index.snapshot.files.first { $0.name == "contrato.txt" })
        try FileManager.default.moveItem(at: original, to: base.appendingPathComponent("moved.txt"))
        do { _ = try await index.resolveForPreview(file); XCTFail("Moved file should fail") }
        catch { XCTAssertNotNil(error as? FileIndexError) }
    }

    func testAllAuthorizedFoldersAreSharedWithRemoteSearchWithoutRestart() async throws {
        let (base, local) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        // Create the remote service BEFORE the new authorizations are saved.
        let remote = FileIndexService(store: FileIndexStore(directory: base.appendingPathComponent("index")))
        await remote.reload()
        let folders = ["Escritorio", "Arquivo antigo", "Volume compartilhado"]
        for name in folders {
            let folder = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Contrato fictício".write(to: folder.appendingPathComponent("contrato.txt"), atomically: true, encoding: .utf8)
            await local.index(directory: folder)
            XCTAssertNil(local.errorMessage)
        }
        let request = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu contrato"))
        let result = await PavlakFileSearchProvider(index: remote).search(request)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(Set(remote.snapshot.roots.map(\.displayName)), Set(folders))
        let scoped = await remote.authorizedSnapshot()
        for file in scoped.files {
            let url = try await remote.resolveForPreview(file)
            defer { url.stopAccessingSecurityScopedResource() }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Contrato fictício")
        }
        // A write by an older service must preserve other registered roots.
        let extra = base.appendingPathComponent("Outra pasta")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        await remote.index(directory: extra)
        await local.reload()
        XCTAssertEqual(local.snapshot.roots.count, 4)
    }

    func testRemoteSearchUsesContentAndReportsMissingPermission() async throws {
        let (base, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = FileRecoveryViewModel(index: index)
        let message = PavlakLinkMessage(requestID: UUID(), sourceDevice: .iPhone, targetDevice: .mac,
                                       action: .fileSearch, query: "Encontre meu comprovante de residência",
                                       payload: nil, status: .requested, result: nil, sentAt: Date())
        let denied = await model.handleLink(message)
        XCTAssertEqual(denied.status, .failure)
        let docs = base.appendingPathComponent("Escritorio")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "Conta de água para endereço fictício".write(to: docs.appendingPathComponent("scan.txt"), atomically: true, encoding: .utf8)
        await index.index(directory: docs)
        let response = await model.handleLink(message)
        XCTAssertEqual(response.status, .success)
        let data = try XCTUnwrap(response.result?.data(using: .utf8))
        let candidates = try JSONDecoder().decode([PavlakLinkFileCandidate].self, from: data)
        XCTAssertEqual(candidates.first?.name, "scan.txt")
        XCTAssertEqual(candidates.first?.sourceLocation, "Escritorio")
    }

    func testDateRanksMatchingModificationWithoutClaimingEventDate() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre o ingresso de hoje"))
        let today = Date()
        let old = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -5, to: today))
        let records = [old, today].enumerated().map { n, date in
            LocalSearchRecord(id: "\(n)", source: .authorizedFiles, title: "ingresso.txt", date: date,
                              nameText: "ingresso", contentOrOCRText: "", metadataText: "txt")
        }
        let results = LocalUnifiedSearchRanker.rank(query: query, records: records)
        XCTAssertEqual(results.first?.sourceID, "1")
        XCTAssertTrue(results.first?.reason.contains("não confirma a data do evento") == true)
    }
}
#endif

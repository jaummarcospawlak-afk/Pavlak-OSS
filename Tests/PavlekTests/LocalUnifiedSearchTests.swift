#if os(macOS)
import XCTest
@testable import Pavlek

final class LocalUnifiedSearchTests: XCTestCase {
    func testRecognizesPropertyRegistrationCommandWithDetails() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Pavlak, encontre a matrícula da Fazenda Água Doce"))
        XCTAssertEqual(query.documentKind, .propertyRegistration)
        XCTAssertEqual(query.requestedPhrase, "matricula")
        XCTAssertEqual(query.detailTerms, ["fazenda", "agua", "doce"])
    }

    func testRecognizesTheFourStageOneDocumentKinds() {
        XCTAssertEqual(LocalUnifiedSearchQuery.recognize("Localize a certidão de matrícula")?.documentKind, .propertyRegistration)
        XCTAssertEqual(LocalUnifiedSearchQuery.recognize("Busque meu contrato")?.documentKind, .contract)
        XCTAssertEqual(LocalUnifiedSearchQuery.recognize("Procure o comprovante de pagamento")?.documentKind, .receipt)
        XCTAssertEqual(LocalUnifiedSearchQuery.recognize("Encontre minha certidão de casamento")?.documentKind, .marriageCertificate)
    }

    func testUsesMostSpecificDocumentPhrase() {
        let query = LocalUnifiedSearchQuery.recognize("Encontre o comprovante de pagamento do contrato BancoExemplo")
        XCTAssertEqual(query?.documentKind, .receipt)
        XCTAssertEqual(query?.requestedPhrase, "comprovante de pagamento")
        XCTAssertEqual(query?.detailTerms, ["bancoexemplo"])
    }

    func testDoesNotRoutePhotosOrUnrelatedDocumentsThroughStageOneSearch() {
        XCTAssertNil(LocalUnifiedSearchQuery.recognize("Procure no álbum Documentos"))
        XCTAssertNil(LocalUnifiedSearchQuery.recognize("Encontre minha foto do contrato"))
        XCTAssertEqual(LocalUnifiedSearchQuery.recognize("Encontre meu talão de água")?.documentKind, .residence)
    }

    func testPortugueseAccentsAreNormalized() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("PÁVLAK, LOCALIZE A MATRÍCULA"))
        XCTAssertEqual(query.normalized, "pavlak localize a matricula")
    }

    func testStageOneScopeAllowsOnlyTheTwoNamedTestTrees() {
        let home = URL(fileURLWithPath: "/tmp/PavlakTestHome", isDirectory: true)
        let documents = home.appendingPathComponent("Documents/Pavlak", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads/Pavlak", isDirectory: true)

        XCTAssertTrue(FileIndexService.isDescendantOrSame(
            documents.appendingPathComponent("subpasta/documento.pdf"), of: documents
        ))
        XCTAssertTrue(FileIndexService.isDescendantOrSame(downloads, of: downloads))
        XCTAssertFalse(FileIndexService.isDescendantOrSame(
            home.appendingPathComponent("Documents/Pavlak-privado/documento.pdf"), of: documents
        ))
        XCTAssertFalse(FileIndexService.isDescendantOrSame(
            home.appendingPathComponent("Desktop/Pavlak/documento.pdf"), of: documents
        ))
    }

    func testRankingAccountsForExactNameTextAndMetadataSeparately() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre o comprovante de pagamento do BancoExemplo"))
        let records = [
            fixture(id: "name", title: "Comprovante de pagamento BancoExemplo.pdf", name: "Comprovante de pagamento BancoExemplo.pdf"),
            fixture(id: "text", title: "digitalização.pdf", content: "Documento: comprovante de pagamento BancoExemplo"),
            fixture(id: "metadata", title: "comprovante.pdf", name: "comprovante.pdf", metadata: "Bancos/BancoExemplo/comprovante.pdf")
        ]

        let ranked = LocalUnifiedSearchRanker.rank(query: query, records: records)
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.sourceID, $0) })

        XCTAssertGreaterThan(byID["name"]?.score.exactPhrase ?? 0, 0)
        XCTAssertGreaterThan(byID["name"]?.score.name ?? 0, 0)
        XCTAssertGreaterThan(byID["text"]?.score.contentOrOCR ?? 0, 0)
        XCTAssertGreaterThan(byID["metadata"]?.score.metadata ?? 0, 0)
        XCTAssertEqual(ranked.first?.sourceID, "name")
    }

    func testRequiresRequestedDetailWhenCommandIncludesOne() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre o contrato do BancoExemplo"))
        let records = [
            fixture(id: "unrelated", title: "Contrato antigo.pdf", name: "Contrato antigo.pdf"),
            fixture(id: "match", title: "Contrato BancoExemplo.pdf", name: "Contrato BancoExemplo.pdf")
        ]
        XCTAssertEqual(LocalUnifiedSearchRanker.rank(query: query, records: records).map(\.sourceID), ["match"])
    }

    func testCanExplainTypeInNameAndRequestedDetailInFolder() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre o contrato do BancoExemplo"))
        let record = fixture(
            id: "cross-field", title: "Contrato.pdf", name: "Contrato.pdf", metadata: "Bancos/BancoExemplo"
        )

        let result = try XCTUnwrap(LocalUnifiedSearchRanker.rank(query: query, records: [record]).first)

        XCTAssertTrue(result.reason.contains("tipo “contrato” no nome"))
        XCTAssertTrue(result.reason.contains("detalhe “bancoexemplo” na pasta ou nos metadados"))
    }

    func testReturnsAtMostFiveExplainableFileCandidates() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meus contratos"))
        let records = (0..<8).map { fixture(id: "\($0)", title: "Contrato \($0).pdf", name: "Contrato \($0).pdf") }
        let results = LocalUnifiedSearchRanker.rank(query: query, records: records)

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.source == .authorizedFiles })
        XCTAssertTrue(results.allSatisfy { $0.reason.contains("selecionar não abre nem altera") })
    }

    func testBlockedFilesPreventAbsenceClaim() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu contrato"))
        let report = LocalUnifiedSearchReport(
            query: query,
            results: [],
            sourceStatuses: [.authorizedFiles: .blocked("Nenhuma pasta autorizada")]
        )
        XCTAssertFalse(report.canReportTotalAbsence)
        XCTAssertEqual(report.incompleteSources.first?.0, .authorizedFiles)
    }

    func testTotalAbsenceRequiresEveryEligibleSourceToBeConsulted() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu comprovante"))
        let complete = LocalUnifiedSearchReport(
            query: query,
            results: [],
            sourceStatuses: [.authorizedFiles: .consulted(resultCount: 0)]
        )
        XCTAssertTrue(complete.canReportTotalAbsence)
    }

    private func fixture(
        id: String,
        title: String,
        name: String = "",
        content: String = "",
        metadata: String = ""
    ) -> LocalSearchRecord {
        .init(
            id: id,
            source: .authorizedFiles,
            title: title,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            nameText: name,
            contentOrOCRText: content,
            metadataText: metadata
        )
    }
}
#endif

#if os(macOS)
import XCTest
@testable import Pavlek

final class PavlakPhotoDocumentTests: XCTestCase {
    @MainActor
    func testResidencePhotoFoundFromOCRWithoutFilenameAndUnrelatedImagesRejected() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu comprovante de residência"))
        let photos = [
            MacPhotoSearchResult(id: "bill", albumTitle: "Documentos", filename: "IMG_001.jpg", creationDate: nil, score: 1, recognizedText: "Conta de água. Endereço: Rua Fictícia 123."),
            MacPhotoSearchResult(id: "party", albumTitle: "Festa", filename: "IMG_002.jpg", creationDate: nil, score: 1, recognizedText: "Ingresso festa sábado"),
            MacPhotoSearchResult(id: "generic", albumTitle: "Documentos", filename: "IMG_003.jpg", creationDate: nil, score: 1, recognizedText: "Endereço de entrega. Nome e telefone."),
            MacPhotoSearchResult(id: "unreadable", albumTitle: "Documentos", filename: "IMG_004.jpg", creationDate: nil, score: 1, recognizedText: "")
        ]
        let results = LocalUnifiedSearchRanker.rank(query: query, records: PavlakOrchestrator.photoRecords(photos))
        XCTAssertEqual(results.map(\.sourceID), ["bill"])
        XCTAssertEqual(results.first?.source, .authorizedPhotos)
        XCTAssertTrue(results.first?.reason.contains("conta de agua") == true)
        XCTAssertTrue(results.first?.reason.contains("candidato") == true)
    }

    @MainActor
    func testRequestedAddressDisambiguatesDocumentsAndKeepsOrigin() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu comprovante de residência Palmeiras"))
        let photos = ["Palmeiras", "Acácias"].enumerated().map { n, address in
            MacPhotoSearchResult(id: "\(n)", albumTitle: "Contas", filename: "scan.jpg", creationDate: nil, score: 1,
                                 recognizedText: "Conta de energia. Endereço: Rua \(address)")
        }
        let records = PavlakOrchestrator.photoRecords(photos)
        XCTAssertEqual(records.first?.metadataText, "Contas")
        XCTAssertEqual(LocalUnifiedSearchRanker.rank(query: query, records: records).map(\.sourceID), ["0"])
    }

    func testBlockedPhotosPreventFalseTotalAbsence() throws {
        let query = try XCTUnwrap(LocalUnifiedSearchQuery.recognize("Encontre meu contrato"))
        let report = LocalUnifiedSearchReport(query: query, results: [], sourceStatuses: [
            .authorizedFiles: .consulted(resultCount: 0), .authorizedPhotos: .blocked("Sem autorização")
        ])
        XCTAssertFalse(report.canReportTotalAbsence)
    }
}
#endif

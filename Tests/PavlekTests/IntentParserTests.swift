import XCTest
@testable import Pavlek

final class IntentParserTests: XCTestCase {
    func testParsesGalleryRequest() {
        let result = IntentParser.parse("Pavlek, verifique em minha galeria o que eu estava fazendo ontem")
        XCTAssertEqual(result.source, .photos)
        XCTAssertEqual(result.object, "Fotos da galeria")
        XCTAssertEqual(result.period, "Ontem")
        XCTAssertEqual(result.action, "Localizar e apresentar resultados")
    }

    func testParsesPDFSummaryRequest() {
        let result = IntentParser.parse("Resuma os PDFs que recebi esta semana")
        XCTAssertEqual(result.source, .files)
        XCTAssertEqual(result.object, "Documentos PDF")
        XCTAssertEqual(result.period, "Esta semana")
        XCTAssertEqual(result.action, "Resumir conteúdo encontrado")
    }

    func testRoutesRentalContractToFiles() {
        let result = PavlakIntentRouter.parse("localize meu contrato de locação")
        XCTAssertEqual(result.source, .files)
        XCTAssertEqual(result.object, "Contrato de locação")
        XCTAssertEqual(result.action, "Localizar e apresentar resultados")
    }

    func testNarrowsEnergyBillSearchToPhotoDocuments() {
        let result = PavlakIntentRouter.parse("ache meu talão de energia na galeria")
        XCTAssertEqual(result.source, .photos)
        XCTAssertEqual(result.object, "Conta de energia")
        XCTAssertEqual(result.searchScopes, ["Documentos"])
    }

    func testExtractsSharePersonAndCurrentPhoto() {
        let result = PavlakIntentRouter.parse("mande esta foto para Marina")
        XCTAssertEqual(result.source, .photos)
        XCTAssertEqual(result.object, "Foto atual")
        XCTAssertEqual(result.action, "Preparar compartilhamento")
        XCTAssertEqual(result.person, "Marina")
        XCTAssertEqual(result.destination, "Marina")
    }

    func testRoutesWebAddressToSafari() {
        let result = PavlakIntentRouter.parse("abra https://openai.com no Safari")
        XCTAssertEqual(result.source, .web)
        XCTAssertEqual(result.object, "Página web")
        XCTAssertEqual(result.destination, "https://openai.com")
    }
}

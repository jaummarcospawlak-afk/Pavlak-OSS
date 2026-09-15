#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class FileIndexSearchTests: XCTestCase {
    private let files = [
        IndexedFile(
            id: "test-folder-file", rootID: "desktop", name: "anotacoes.txt",
            relativePath: "Teste Pavlak/anotacoes.txt", fileExtension: "txt", modifiedAt: nil
        ),
        IndexedFile(
            id: "lease", rootID: "desktop", name: "Contrato de Locação.pdf",
            relativePath: "Contratos/Contrato de Locação.pdf", fileExtension: "pdf", modifiedAt: nil
        ),
        IndexedFile(
            id: "water", rootID: "desktop", name: "Talão de Água Agosto.pdf",
            relativePath: "Contas/Talão de Água Agosto.pdf", fileExtension: "pdf", modifiedAt: nil
        )
    ]

    func testSearchUsesRequestedFolderNameInsteadOfReturningGenericContracts() {
        let results = FileIndexService.search(command: "Pavlak, localize a pasta Teste Pavlak", in: files)

        XCTAssertEqual(results.map(\.id), ["test-folder-file"])
    }

    func testSearchFindsAnyDocumentNameWithAccentNormalization() {
        let results = FileIndexService.search(command: "Procure meu talão de água", in: files)

        XCTAssertEqual(results.first?.id, "water")
        XCTAssertFalse(results.contains { $0.id == "lease" })
    }

    func testSearchKeepsExistingContractUseCase() {
        let results = FileIndexService.search(command: "Localize o contrato de locação", in: files)

        XCTAssertEqual(results.first?.id, "lease")
    }

    func testSearchFindsDocumentByEmbeddedTextWhenNameIsGeneric() {
        let generic = IndexedFile(
            id: "generic", rootID: "desktop", name: "digitalizacao-00486.pdf",
            relativePath: "Digitalizados/digitalizacao-00486.pdf", fileExtension: "pdf", modifiedAt: nil
        )

        let results = FileIndexService.search(
            command: "Localize o contrato de financiamento C31230405",
            in: files + [generic],
            contentsByFileID: ["generic": "Cédula de crédito e contrato de financiamento C31230405"]
        )

        XCTAssertEqual(results.first?.id, "generic")
    }

    func testSearchFindsOCRTextWithAccentNormalization() {
        let scan = IndexedFile(
            id: "scan", rootID: "desktop", name: "IMG_1087.pdf",
            relativePath: "Escaneados/IMG_1087.pdf", fileExtension: "pdf", modifiedAt: nil
        )

        let results = FileIndexService.search(
            command: "Procure meu comprovante de residência",
            in: files + [scan],
            contentsByFileID: ["scan": "COMPROVANTE DE RESIDÊNCIA — titular Marina Teste"]
        )

        XCTAssertEqual(results.first?.id, "scan")
    }

    func testRecognizesSupervisedCopyCommandAndDestination() {
        XCTAssertEqual(
            DocumentSearchViewModel.copyDestinationHint(from: "salve este arquivo em dossie profissional"),
            "dossie profissional"
        )
        XCTAssertEqual(
            DocumentSearchViewModel.copyDestinationHint(from: "copie para pasta de teste"),
            "pasta de teste"
        )
    }

    func testDoesNotTreatOrdinarySearchAsCopyCommand() {
        XCTAssertNil(DocumentSearchViewModel.copyDestinationHint(from: "localize meu contrato"))
    }

    func testRoutesUnknownDocumentTypeToAuthorizedLocalFiles() {
        XCTAssertTrue(DocumentSearchViewModel.isGenericLocalFileSearch("pavlak localize meu comprovante de residencia"))
        XCTAssertFalse(DocumentSearchViewModel.isGenericLocalFileSearch("localize o album viagens na galeria"))
    }
}
#endif

#if os(macOS)
import XCTest
@testable import Pavlek

final class SpeechCommandComposerTests: XCTestCase {
    func testUsesTranscriptAsCommandWhenFieldIsEmpty() {
        XCTAssertEqual(
            SpeechCommandComposer.compose(baseCommand: "", transcript: "Localize meu contrato"),
            "Localize meu contrato"
        )
    }

    func testAppendsTranscriptWithoutDiscardingExistingCommand() {
        XCTAssertEqual(
            SpeechCommandComposer.compose(baseCommand: "Compare os documentos", transcript: "e destaque os valores"),
            "Compare os documentos e destaque os valores"
        )
    }

    func testTrimsRecognitionWhitespace() {
        XCTAssertEqual(
            SpeechCommandComposer.compose(baseCommand: "  Procure nas fotos  ", transcript: "  do mês passado\n"),
            "Procure nas fotos do mês passado"
        )
    }

    func testEmptyTranscriptLeavesCommandUntouched() {
        XCTAssertEqual(
            SpeechCommandComposer.compose(baseCommand: "Comando existente  ", transcript: " \n "),
            "Comando existente  "
        )
    }
}
#endif

import XCTest
@testable import Pavlek

final class IOSCommandRoutingTests: XCTestCase {
    func testExplicitSearchCanLeaveConversationWithoutSendingQuestion() {
        for text in ["Encontre meu contrato", "Pavlak, localize minha identidade", "Pavlek busque o ingresso"] {
            XCTAssertTrue(IOSCommandRouting.isSearch(text), text)
            XCTAssertFalse(IOSCommandRouting.isQuestion(text), text)
        }
        for text in ["Quem assinou?", "Resuma o contrato", "não encontre meu contrato", ""] {
            XCTAssertFalse(IOSCommandRouting.isSearch(text), text)
        }
    }

    func testOpeningCommandsRequireAnExactInstruction() {
        XCTAssertEqual(IOSCommandRouting.openPosition("Abra o primeiro"), 0)
        XCTAssertEqual(IOSCommandRouting.openPosition("ABRIR O QUINTO"), 4)
        XCTAssertNil(IOSCommandRouting.openPosition("não abra o primeiro"))
        XCTAssertNil(IOSCommandRouting.openPosition("resuma o primeiro contrato"))
        XCTAssertTrue(IOSCommandRouting.opensSelection("abra esse"))
        XCTAssertFalse(IOSCommandRouting.opensSelection("não abra esse"))
    }

    func testQuestionsAndSearchRequestsRemainDistinct() {
        for text in ["Qual é o titular?", "Quem assinou?", "Resuma esse documento", "Olá"] {
            XCTAssertTrue(IOSCommandRouting.isQuestion(text), text)
        }
        for text in ["Encontre meu contrato", "Localize o comprovante", "Procure ingresso", ""] {
            XCTAssertFalse(IOSCommandRouting.isQuestion(text), text)
        }
    }
}

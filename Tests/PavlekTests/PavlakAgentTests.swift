#if os(macOS)
import XCTest
import Foundation
@testable import Pavlek

@MainActor
final class PavlakAgentTests: XCTestCase {
    func testAgentExposesOnlyTheFiveApprovedTools() {
        XCTAssertEqual(PavlakAgent.supportedToolNames, [
            "search_files", "search_photos", "search_photo_album", "open_item", "get_active_context"
        ])
    }

    func testVisibleAgentStatesUseRealRequestedLabels() {
        XCTAssertEqual(PavlakAgent.State.thinking.label, "Pensando…")
        XCTAssertEqual(PavlakAgent.State.searchingPhotos.label, "Pesquisando Fotos…")
        XCTAssertEqual(PavlakAgent.State.found(4).label, "Encontrados 4 resultados")
        XCTAssertEqual(PavlakAgent.State.analyzing.label, "Analisando…")
        XCTAssertEqual(PavlakAgent.State.completed.label, "Concluído")
    }

    func testLocalOnlyRejectsConversationWithoutStartingOpenAIWork() {
        let agent = PavlakAgent(isLocalOnly: { true })

        agent.send("Analise estes documentos")

        XCTAssertEqual(agent.messages.count, 2)
        XCTAssertEqual(agent.messages.last?.role, .assistant)
        XCTAssertEqual(agent.messages.last?.text, OpenAIUsagePolicy.localOnlyMessage)
        XCTAssertEqual(agent.state, .failed(OpenAIUsagePolicy.localOnlyMessage))
        XCTAssertFalse(agent.isRunning)
    }

    func testWorkspaceOpenerPropagatesARejectedOpen() {
        XCTAssertThrowsError(try PavlakWorkspaceOpener.open(URL(fileURLWithPath: "/tmp/inexistente"), using: { _ in false })) { error in
            XCTAssertEqual(error as? PavlakWorkspaceOpenError, .rejected)
        }
    }
}
#endif

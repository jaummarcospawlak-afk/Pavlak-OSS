#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class PavlakHubTests: XCTestCase {
    func testConversationStorePersistsHistoryWithoutRecognizableCredentials() throws {
        let suiteName = "PavlakHubTests.Store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PavlakConversationStore(defaults: defaults)
        let record = PavlakConversationRecord(
            id: UUID(), title: "Busca de estudo", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), messages: [
                .init(id: UUID(), role: .user, text: "Encontre meu estudo"),
                .init(id: UUID(), role: .assistant, text: "api-key: synthetic-test-value")
            ]
        )

        store.save([record])
        let loaded = try XCTUnwrap(store.load().first)

        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertFalse(loaded.messages[1].text.contains("synthetic-test-value"))
        XCTAssertFalse(loaded.messages[1].text.contains("api-key: synthetic-test-value"))
        XCTAssertTrue(loaded.messages[1].text.contains("[credencial omitida]"))
    }

    func testWorkspaceLoadsAndRestoresLocalConversation() throws {
        let suiteName = "PavlakHubTests.Restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PavlakConversationStore(defaults: defaults)
        let record = PavlakConversationRecord(
            id: UUID(), title: "Conversa sobre matrícula", createdAt: Date(), updatedAt: Date(), messages: [
                .init(id: UUID(), role: .user, text: "Procure minha matrícula"),
                .init(id: UUID(), role: .assistant, text: "Encontrei um candidato local.")
            ]
        )
        store.save([record])

        let workspace = PavlakWorkspaceState(
            hasValidatedOpenAI: { false },
            conversationStore: store
        )
        XCTAssertEqual(workspace.conversations.map(\.id), [record.id])

        workspace.restoreConversation(record)

        XCTAssertEqual(workspace.currentConversationID, record.id)
        XCTAssertEqual(workspace.agent.messages.map(\.text), record.messages.map(\.text))
        XCTAssertEqual(workspace.agent.state, .completed)
        XCTAssertTrue(workspace.documentSearch.activeContracts.isEmpty)
    }

    func testHubSearchMatchesConversationAndUsesLocalStudiesQuery() async throws {
        let suiteName = "PavlakHubTests.Search.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PavlakConversationStore(defaults: defaults)
        let record = PavlakConversationRecord(
            id: UUID(), title: "Aula de álgebra", createdAt: Date(), updatedAt: Date(), messages: [
                .init(id: UUID(), role: .user, text: "Organizar meu material de álgebra")
            ]
        )
        store.save([record])
        let unified = LocalUnifiedSearchViewModel { query in
            LocalUnifiedSearchReport(query: query, results: [], sourceStatuses: [.authorizedFiles: .consulted(resultCount: 0)])
        }
        let workspace = PavlakWorkspaceState(
            unifiedSearch: unified,
            hasValidatedOpenAI: { false },
            conversationStore: store
        )

        workspace.command = "álgebra"
        workspace.submitHubSearch()
        XCTAssertEqual(workspace.hubConversationMatches.map(\.id), [record.id])

        workspace.command = "história do Brasil"
        workspace.searchStudies()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(unified.lastSubmittedQuery?.documentKind, .file)
        XCTAssertTrue(workspace.agent.messages.isEmpty)
        XCTAssertEqual(workspace.resultOrigin, .localUnified)
    }
}
#endif

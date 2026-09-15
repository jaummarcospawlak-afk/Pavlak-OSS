#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class PavlakWorkspaceStateTests: XCTestCase {
    func testWorkspaceStartsWithEmptyCommandField() {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { false })

        XCTAssertEqual(workspace.command, "")
        XCTAssertEqual(workspace.documentSearch.command, "")
    }

    func testWorkspaceOwnsCommandAttachmentsOriginOperationAndHistory() {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { false })
        let attachment = URL(fileURLWithPath: "/tmp/contrato-a.pdf")
        workspace.addAttachments([attachment])
        workspace.command = "Localize meu arquivo de locação"
        workspace.submit()

        XCTAssertTrue(workspace.attachments.isEmpty)
        XCTAssertEqual(workspace.resultOrigin, .localUnified)
        XCTAssertEqual(workspace.operation, .searchingLocal)
        XCTAssertEqual(workspace.history.last?.kind, .command)
        XCTAssertEqual(workspace.history.last?.value, "Localize meu arquivo de locação")
    }

    func testWorkspaceKeepsPhotoModeAndAlbumOperationTogether() {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { false })
        workspace.command = "Procure meu RG no álbum Documentos"
        workspace.submit()

        XCTAssertTrue(workspace.isPhotoMode)
        XCTAssertEqual(workspace.resultOrigin, .photos)
        XCTAssertEqual(workspace.operation, .searchingPhotos(album: "Documentos"))
        XCTAssertEqual(workspace.history.count, 1)
    }

    func testExactAlbumCommandUsesLocalPhotosEvenWhenOpenAIIsAvailable() {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { true })
        workspace.command = "Procure no álbum Documentos"
        workspace.submit()

        XCTAssertTrue(workspace.isPhotoMode)
        XCTAssertEqual(workspace.resultOrigin, .photos)
        XCTAssertEqual(workspace.operation, .searchingPhotos(album: "Documentos"))
        XCTAssertTrue(workspace.agent.messages.isEmpty)
    }

    func testDocumentKindSearchRunsOnlyLocallyBeforeOpenAI() throws {
        let unified = LocalUnifiedSearchViewModel { query in
            LocalUnifiedSearchReport(
                query: query,
                results: [],
                sourceStatuses: [.authorizedFiles: .consulted(resultCount: 0)]
            )
        }
        let workspace = PavlakWorkspaceState(unifiedSearch: unified, hasValidatedOpenAI: { true })
        let attachment = URL(fileURLWithPath: "/tmp/fixture-sintetica.pdf")
        workspace.addAttachments([attachment])
        workspace.command = "Pavlak, encontre o comprovante do BancoExemplo"

        workspace.submit()

        XCTAssertTrue(workspace.isUnifiedSearchMode)
        XCTAssertEqual(workspace.resultOrigin, .localUnified)
        XCTAssertEqual(workspace.operation, .searchingLocal)
        XCTAssertEqual(unified.lastSubmittedQuery?.documentKind, .receipt)
        XCTAssertEqual(unified.lastSubmittedQuery?.detailTerms, ["bancoexemplo"])
        XCTAssertTrue(workspace.attachments.isEmpty)
        XCTAssertTrue(workspace.agent.messages.isEmpty)
    }

    func testLocalModeKeepsConfiguredOpenAIOutOfSpecializedLocalSearch() throws {
        let suiteName = "PavlekTests.LocalMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let mode = PavlakExecutionMode(defaults: defaults)
        let unified = LocalUnifiedSearchViewModel { query in
            LocalUnifiedSearchReport(
                query: query,
                results: [],
                sourceStatuses: [.authorizedFiles: .consulted(resultCount: 0)]
            )
        }
        let workspace = PavlakWorkspaceState(
            unifiedSearch: unified,
            hasValidatedOpenAI: { true },
            executionMode: mode
        )
        workspace.command = "Encontre meu contrato de locação"

        workspace.submit()

        XCTAssertTrue(mode.isLocalOnly)
        XCTAssertEqual(workspace.resultOrigin, .localUnified)
        XCTAssertEqual(unified.lastSubmittedQuery?.documentKind, .contract)
        XCTAssertTrue(workspace.agent.messages.isEmpty)
    }

    func testUnsupportedLocalModeRequestExplainsNoOpenAICallSynchronously() throws {
        let suiteName = "PavlekTests.LocalUnsupported.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let mode = PavlakExecutionMode(defaults: defaults)
        let workspace = PavlakWorkspaceState(
            hasValidatedOpenAI: { true },
            executionMode: mode
        )
        workspace.command = "Escreva uma análise estratégica livre"

        workspace.submit()

        XCTAssertEqual(workspace.resultOrigin, .localDocuments)
        XCTAssertEqual(workspace.documentSearch.state, .failed(OpenAIUsagePolicy.localOnlyMessage))
        XCTAssertEqual(workspace.documentSearch.assistantResponse, OpenAIUsagePolicy.localOnlyMessage)
        XCTAssertTrue(workspace.agent.messages.isEmpty)
    }

    func testScopedSearchClearsPreexistingExternalContextAndAttachments() async {
        let unified = LocalUnifiedSearchViewModel { query in
            LocalUnifiedSearchReport(
                query: query,
                results: [],
                sourceStatuses: [.authorizedFiles: .consulted(resultCount: 0)]
            )
        }
        let workspace = PavlakWorkspaceState(unifiedSearch: unified, hasValidatedOpenAI: { false })
        let externalFile = IndexedFile(
            id: "outside", rootID: "external-root", name: "Documento externo.pdf",
            relativePath: "Fora/Documento externo.pdf", fileExtension: "pdf", modifiedAt: Date()
        )
        workspace.documentSearch.selectWithoutOpening(FileSearchCandidate(file: externalFile, score: 90))
        workspace.addAttachments([URL(fileURLWithPath: "/fora-do-escopo/anexo.pdf")])
        await Task.yield()
        await Task.yield()
        workspace.command = "Encontre minha certidão de casamento"

        workspace.submit()

        XCTAssertTrue(workspace.isUnifiedSearchMode)
        XCTAssertTrue(workspace.attachments.isEmpty)
        XCTAssertTrue(workspace.documentSearch.activeContracts.isEmpty)
        XCTAssertNil(workspace.documentSearch.selected)
        XCTAssertNil(workspace.documentSearch.previewURL)
        XCTAssertEqual(workspace.activeSelection, .none)
        XCTAssertTrue(workspace.activeObjects.isEmpty)
        XCTAssertTrue(workspace.results.isEmpty)
        XCTAssertTrue(workspace.agent.activeContext.isEmpty)
        XCTAssertTrue(workspace.agent.fileResults.isEmpty)

        await Task.yield()
        await Task.yield()
        XCTAssertNil(workspace.documentSearch.selected)
        XCTAssertTrue(workspace.documentSearch.activeContracts.isEmpty)
        XCTAssertEqual(workspace.activeSelection, .none)
        XCTAssertTrue(workspace.activeObjects.isEmpty)
    }

    func testReadOnlyCandidateSelectionDoesNotResolveOrOpenFile() {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { false })
        let file = IndexedFile(
            id: "receipt-1", rootID: "authorized", name: "Comprovante.pdf",
            relativePath: "Comprovantes/Comprovante.pdf", fileExtension: "pdf", modifiedAt: Date()
        )

        workspace.documentSearch.selectWithoutOpening(FileSearchCandidate(file: file, score: 80))

        XCTAssertEqual(workspace.documentSearch.selected?.id, file.id)
        XCTAssertNil(workspace.documentSearch.previewURL)
        XCTAssertEqual(workspace.documentSearch.state, .results)
    }

    func testClearingSelectionDoesNotDiscardActiveContext() async {
        let workspace = PavlakWorkspaceState(hasValidatedOpenAI: { false })
        let file = IndexedFile(
            id: "contract-1", rootID: "desktop", name: "Contrato.pdf",
            relativePath: "Desktop/Contrato.pdf", fileExtension: "pdf", modifiedAt: Date()
        )
        let candidate = FileSearchCandidate(file: file, score: 1)

        await workspace.activateFile(candidate)
        workspace.clearActiveSelection()

        XCTAssertEqual(workspace.activeSelection, .none)
        XCTAssertEqual(workspace.activeObjects, [.file(candidate.id)])
        XCTAssertEqual(workspace.resultOrigin, .files)
    }
}
#endif

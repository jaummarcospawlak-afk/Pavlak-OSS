#if os(macOS)
import Foundation

@MainActor
final class PavlakWorkflowEngine: ObservableObject {
    enum Phase: Equatable { case idle, locating, selecting, extracting, summarizing, readyToCreate, creating, finished, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var workflow: PavlakWorkflow?
    @Published private(set) var candidates: [FileSearchCandidate] = []
    @Published var selectedCandidateID: String?
    @Published private(set) var summary = ""
    @Published private(set) var outputURL: URL?

    private let router = ToolRouter(photos: PhotoLibraryService())
    var isActive: Bool { phase != .idle }
    var summaryToolName: String { router.workflowSummaryToolName }

    static func matches(_ command: String) -> Bool {
        let value = command.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return value.contains("contrato") && value.contains("resumo") && (value.contains("organizada") || value.contains("organizado") || value.contains("versao"))
    }

    func start(command: String) {
        let ids = (0..<5).map { _ in UUID() }
        workflow = PavlakWorkflow(id: UUID(), objective: command, steps: [
            WorkflowStep(id: ids[0], title: "Localizar contrato", tool: "Pavlak File Index", input: command, result: nil, nextStepID: ids[1], status: .running),
            WorkflowStep(id: ids[1], title: "Confirmar documento", tool: "Seleção do usuário", input: "Candidatos ranqueados", result: nil, nextStepID: ids[2], status: .pending),
            WorkflowStep(id: ids[2], title: "Extrair conteúdo", tool: "PDFKit / Vision", input: "Documento confirmado", result: nil, nextStepID: ids[3], status: .pending),
            WorkflowStep(id: ids[3], title: "Gerar resumo", tool: summaryToolName, input: "Texto extraído", result: nil, nextStepID: ids[4], status: .pending),
            WorkflowStep(id: ids[4], title: "Criar versão organizada", tool: "Documento RTF do macOS", input: "Resumo aprovado", result: nil, nextStepID: nil, status: .pending)
        ])
        phase = .locating; candidates = []; summary = ""; outputURL = nil
        Task {
            let found = await router.workflowSearchFiles(query: command)
            guard !found.isEmpty else { fail(WorkflowEngineError.noCandidate); return }
            candidates = found
            selectedCandidateID = found.first?.id
            completeStep(0, result: "\(found.count) candidato(s)")
            beginStep(1); phase = .selecting
        }
    }

    func confirmAndProcess() {
        guard phase == .selecting, let candidate = candidates.first(where: { $0.id == selectedCandidateID }) else { fail(WorkflowEngineError.invalidTransition); return }
        completeStep(1, result: candidate.file.name); beginStep(2); phase = .extracting
        Task {
            do {
                let text = try await router.workflowExtract(candidate: candidate)
                guard !text.isEmpty else { throw FileIndexError.emptyDocument }
                completeStep(2, result: "Texto extraído")
                beginStep(3); phase = .summarizing
                summary = try await router.workflowSummarize(title: candidate.file.name, text: text)
                guard !summary.isEmpty else { throw FileIndexError.emptyDocument }
                completeStep(3, result: "Resumo gerado")
                phase = .readyToCreate
            } catch { fail(error) }
        }
    }

    func createOrganizedVersion() {
        guard phase == .readyToCreate,
              let candidate = candidates.first(where: { $0.id == selectedCandidateID }), !summary.isEmpty else { fail(WorkflowEngineError.invalidTransition); return }
        beginStep(4); phase = .creating
        do {
            outputURL = try router.workflowCreateDocument(sourceName: candidate.file.name, summary: summary)
            completeStep(4, result: outputURL?.lastPathComponent ?? "Documento criado")
            phase = .finished
        } catch WorkflowEngineError.cancelled { phase = .readyToCreate; resetStep(4) }
        catch { fail(error) }
    }

    func reset() { phase = .idle; workflow = nil; candidates = []; selectedCandidateID = nil; summary = ""; outputURL = nil }

    private func beginStep(_ index: Int) { guard workflow?.steps.indices.contains(index) == true else { return }; workflow?.steps[index].status = .running }
    private func completeStep(_ index: Int, result: String) { guard workflow?.steps.indices.contains(index) == true else { return }; workflow?.steps[index].result = result; workflow?.steps[index].status = .completed }
    private func resetStep(_ index: Int) { guard workflow?.steps.indices.contains(index) == true else { return }; workflow?.steps[index].status = .pending }
    private func fail(_ error: Error) {
        if let index = workflow?.steps.firstIndex(where: { $0.status == .running }) { workflow?.steps[index].status = .failed; workflow?.steps[index].result = error.localizedDescription }
        phase = .failed(error.localizedDescription)
        PavlakErrorReporter.shared.report(module: "WorkflowEngine", action: "executar_workflow", message: "O fluxo não pôde ser concluído.", error: error, result: "erro_recuperado")
    }
}
#endif

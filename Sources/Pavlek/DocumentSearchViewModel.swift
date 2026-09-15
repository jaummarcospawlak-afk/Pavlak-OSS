#if os(macOS)
import Foundation
import AppKit
import Combine
import PDFKit

@MainActor
final class DocumentSearchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, orchestrating, results, entity, selected, failed(String) }
    private enum NavigationPoint: Equatable { case idle, results, entity, document(String) }

    @Published var command = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var candidates: [FileSearchCandidate] = []
    @Published private(set) var selected: FileSearchCandidate?
    @Published private(set) var previewURL: URL?
    @Published private(set) var presentation: DocumentPresentationCapability = .metadataOnly
    @Published private(set) var resultEntity: PavlakResultEntity?
    @Published private(set) var lastRequest: PavlakExecutionRequest?
    @Published private(set) var assistantResponse: String?
    @Published private(set) var isProcessingDocument = false
    @Published private(set) var activeContracts: [FileSearchCandidate] = []

    let index: FileIndexService
    let orchestrator: OpenAIOrchestrator
    private let capabilities = MacCapabilityService()
    private let summarizer = DocumentSummarizerFactory.make()
    private var securityScopedURL: URL?
    private var cachedText: [String: String] = [:]
    private var history: [NavigationPoint] = [.idle]
    private var historyPosition = 0
    private var orchestratorObservation: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var contextIsSuspended = false
    @Published private(set) var attachments: [URL] = []

    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { historyPosition + 1 < history.count }

    init() {
        let index = FileIndexService()
        self.index = index
        self.orchestrator = OpenAIOrchestrator(index: index)
        orchestratorObservation = orchestrator.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func search() {
        contextIsSuspended = false
        let normalized = Self.normalize(command)
        if handleContextualCommand(normalized) { return }
        if attachments.count >= 2 && normalized.contains("nom") && (normalized.contains("dois") || normalized.contains("ambos")) {
            compareNamesInAttachments()
            return
        }
        if PavlakAIConnectionStatus.isReady && !OpenAIUsagePolicy.isLocalOnly {
            releasePreviewAccess()
            state = .orchestrating; candidates = []; selected = nil; previewURL = nil; resultEntity = nil; assistantResponse = nil
            orchestrator.setActiveCandidates(activeContracts)
            orchestrator.run(command, attachments: attachments)
            attachments = []
            return
        }
        releasePreviewAccess()
        state = .searching; candidates = []; selected = nil; previewURL = nil; resultEntity = nil; assistantResponse = nil
        searchTask = Task {
            await index.reload()
            guard !contextIsSuspended, !Task.isCancelled else { return }
            PavlakConnectorRegistry.shared.noteAuthorizedFolders(!index.snapshot.roots.isEmpty)
            do {
                let request = try PavlakExecutionPipeline.shared.prepare(command)
                lastRequest = request
                if request.toolAction == "web.open" {
                    guard let value = request.intent.destination, let url = Self.webURL(value) else { throw PavlakPipelineError.noTool }
                    resultEntity = PavlakResultEntity(
                        id: url.absoluteString, kind: .page, title: url.host ?? url.absoluteString,
                        type: "Página web", location: url.absoluteString, date: nil, actions: [.open],
                        context: context(for: request, referenceID: url.absoluteString)
                    )
                    state = .entity
                    record(.entity)
                    return
                }
                guard request.toolAction == "files.search" else { throw PavlakPipelineError.noTool }
            } catch {
                // Generic locate/find requests are valid local Finder searches even when the
                // intent parser does not know the requested document type yet.
                guard Self.isGenericLocalFileSearch(normalized) else {
                    state = .failed(OpenAIUsagePolicy.isLocalOnly ? OpenAIUsagePolicy.localOnlyMessage : error.localizedDescription)
                    PavlakErrorReporter.shared.report(module: "ExecutionPipeline", action: "preparar_solicitacao", message: "A solicitação não pôde ser associada a uma conexão disponível.", error: error, result: "erro_recuperado")
                    return
                }
            }
            // Prefer the cheap metadata index first. Folder names are represented in each
            // file's relative path, so queries such as “pasta TESTE Pavlak” should return
            // immediately instead of OCR'ing every authorized document before showing UI.
            let metadataMatches = index.search(command: command)
            let found = metadataMatches.isEmpty
                ? await index.searchIncludingContent(command: command)
                : metadataMatches
            guard !contextIsSuspended, !Task.isCancelled else { return }
            guard !found.isEmpty else { state = .failed("Não encontrei um documento correspondente nas pastas autorizadas."); return }
            candidates = Array(found.prefix(8))
            state = .results
            record(.results)
            if let first = candidates.first, first.score >= 30,
               (candidates.count == 1 || first.score - candidates[1].score >= 10) {
                await select(first)
            }
        }
    }

    func addAttachments(_ urls: [URL]) { attachments.append(contentsOf: urls.filter { !attachments.contains($0) }.prefix(max(0, 6 - attachments.count))) }
    func removeAttachment(_ url: URL) { attachments.removeAll { $0 == url } }

    func clearContextForScopedSearch() {
        contextIsSuspended = true
        searchTask?.cancel()
        searchTask = nil
        releasePreviewAccess()
        candidates = []
        selected = nil
        previewURL = nil
        presentation = .metadataOnly
        resultEntity = nil
        lastRequest = nil
        assistantResponse = nil
        activeContracts = []
        attachments = []
        orchestrator.clearContextForScopedSearch()
        state = .idle
    }

    func activateLocalOnlyMode() {
        orchestrator.activateLocalOnlyMode()
        if state == .orchestrating {
            assistantResponse = OpenAIUsagePolicy.localOnlyMessage
            state = .failed(OpenAIUsagePolicy.localOnlyMessage)
        }
    }

    func presentLocalOnlyUnavailable() {
        releasePreviewAccess()
        assistantResponse = OpenAIUsagePolicy.localOnlyMessage
        state = .failed(OpenAIUsagePolicy.localOnlyMessage)
    }

    func isActive(_ candidate: FileSearchCandidate) -> Bool { activeContracts.contains { $0.id == candidate.id } }

    func toggleActive(_ candidate: FileSearchCandidate) {
        if isActive(candidate) { activeContracts.removeAll { $0.id == candidate.id } }
        else { activeContracts.append(candidate) }
        orchestrator.setActiveCandidates(activeContracts)
    }

    func removeActive(_ candidate: FileSearchCandidate) {
        activeContracts.removeAll { $0.id == candidate.id }
        orchestrator.setActiveCandidates(activeContracts)
    }

    func runOnActiveContracts(_ instruction: String) {
        command = instruction
        if PavlakAIConnectionStatus.isReady && !OpenAIUsagePolicy.isLocalOnly { search() }
        else {
            assistantResponse = OpenAIUsagePolicy.isLocalOnly
                ? "A comparação ampla não está disponível no Modo local. Nenhuma chamada à OpenAI foi feita; os arquivos selecionados continuam ativos."
                : "Conecte a OpenAI para analisar ou comparar vários contratos. Os arquivos selecionados continuam ativos."
            if selected != nil { state = .selected }
        }
    }

    func openResultEntity() {
        guard let value = resultEntity?.context?.referenceID, let url = URL(string: value) else { return }
        do {
            try PavlakWorkspaceOpener.open(url)
        } catch {
            state = .failed("Não foi possível abrir o endereço solicitado.")
            PavlakErrorReporter.shared.report(module: "DocumentSearch", action: "abrir_endereco", message: "Não foi possível abrir o endereço solicitado.", error: error, result: "erro_recuperado")
        }
    }

    func select(_ candidate: FileSearchCandidate, recordHistory: Bool = true) async {
        releasePreviewAccess()
        do {
            let url = try await index.resolveForPreview(candidate.file)
            let inspected = capabilities.inspect(fileURL: url)
            selected = candidate
            if !activeContracts.contains(where: { $0.id == candidate.id }) { activeContracts.append(candidate) }
            orchestrator.setActiveCandidates(activeContracts)
            previewURL = url
            securityScopedURL = url
            presentation = inspected.presentation
            state = .selected
            assistantResponse = nil
            if recordHistory { record(.document(candidate.id)) }
        } catch {
            state = .failed("Não foi possível abrir o documento selecionado.")
            PavlakErrorReporter.shared.report(module: "DocumentSearch", action: "visualizar_documento", message: "Não foi possível apresentar o documento selecionado.", error: error, result: "erro_recuperado")
        }
    }

    /// Keeps a search candidate available in the side panel without resolving, previewing,
    /// opening, moving, or otherwise changing the underlying file.
    func selectWithoutOpening(_ candidate: FileSearchCandidate) {
        releasePreviewAccess()
        selected = candidate
        if !activeContracts.contains(where: { $0.id == candidate.id }) { activeContracts.append(candidate) }
        orchestrator.setActiveCandidates(activeContracts)
        previewURL = nil
        presentation = .metadataOnly
        state = .results
        assistantResponse = nil
    }

    func open(_ candidate: FileSearchCandidate) async {
        do {
            let url = try await index.resolveForPreview(candidate.file)
            defer { url.stopAccessingSecurityScopedResource() }
            try PavlakWorkspaceOpener.open(url)
        } catch {
            state = .failed("Não foi possível abrir o documento selecionado.")
            PavlakErrorReporter.shared.report(module: "DocumentSearch", action: "abrir_documento", message: "Não foi possível abrir o documento selecionado.", error: error, result: "erro_recuperado")
        }
    }

    func reset() {
        releasePreviewAccess(); state = .idle; candidates = []; selected = nil; previewURL = nil; resultEntity = nil; lastRequest = nil; assistantResponse = nil
        record(.idle)
    }

    func showResults() {
        releasePreviewAccess(); selected = nil; previewURL = nil; assistantResponse = nil; state = .results
        record(.results)
    }

    func goBack() { navigate(to: historyPosition - 1) }
    func goForward() { navigate(to: historyPosition + 1) }

    func summarizeCurrent() {
        guard let selected else { return }
        isProcessingDocument = true
        assistantResponse = nil
        let operation = PavlakErrorReporter.shared.begin(module: "DocumentSession", action: "resumir_documento")
        Task {
            do {
                let text = try await documentText(for: selected)
                assistantResponse = try await summarizer.summarize(title: selected.file.name, text: text)
                PavlakErrorReporter.shared.finish(operation, result: "resumo_apresentado")
            } catch {
                assistantResponse = "Não foi possível resumir este documento."
                PavlakErrorReporter.shared.finish(operation, result: "erro_recuperado")
                PavlakErrorReporter.shared.report(module: "DocumentSession", action: "resumir_documento", message: "Não foi possível produzir o resumo do documento selecionado.", error: error, result: "erro_recuperado")
            }
            isProcessingDocument = false
        }
    }

    func askCurrent(_ question: String) {
        guard let selected, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isProcessingDocument = true
        assistantResponse = nil
        let operation = PavlakErrorReporter.shared.begin(module: "DocumentSession", action: "perguntar_documento")
        Task {
            do {
                let text = try await documentText(for: selected)
                assistantResponse = Self.answer(question: question, from: text)
                PavlakErrorReporter.shared.finish(operation, result: "resposta_apresentada")
            } catch {
                assistantResponse = "Não foi possível consultar o conteúdo deste documento."
                PavlakErrorReporter.shared.finish(operation, result: "erro_recuperado")
                PavlakErrorReporter.shared.report(module: "DocumentSession", action: "perguntar_documento", message: "Não foi possível responder usando o documento selecionado.", error: error, result: "erro_recuperado")
            }
            isProcessingDocument = false
        }
    }

    func shareCurrent() {
        guard let url = previewURL, let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func revealCurrent() {
        guard let url = previewURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyCurrentLocation() {
        guard let url = previewURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func releasePreviewAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    func context(for referenceID: String) -> PavlakResultContext? {
        guard let lastRequest else { return nil }
        return context(for: lastRequest, referenceID: referenceID)
    }

    private func context(for request: PavlakExecutionRequest, referenceID: String) -> PavlakResultContext {
        PavlakResultContext(requestID: request.id, intent: request.intent, connectorID: request.connectorID, toolAction: request.toolAction, referenceID: referenceID)
    }

    private func handleContextualCommand(_ value: String) -> Bool {
        if value == "volte" || value == "voltar" { goBack(); return true }
        if value == "avance" || value == "avancar" { goForward(); return true }
        if (value == "abra o primeiro" || value == "abrir o primeiro"), let first = candidates.first {
            Task { await open(first) }
            return true
        }
        if let destinationHint = Self.copyDestinationHint(from: value) {
            guard selected != nil else {
                state = .failed("Selecione primeiro um dos resultados. Depois repita o pedido para copiar o arquivo.")
                return true
            }
            copyCurrentInteractively(destinationHint: destinationHint)
            return true
        }
        guard let selected else { return false }
        if value == "abra" || value == "abrir" { Task { await open(selected) }; return true }
        if PavlakAIConnectionStatus.isReady && !OpenAIUsagePolicy.isLocalOnly && activeContracts.count > 1 { return false }
        if value.contains("resuma") || value == "resumo" { summarizeCurrent(); return true }
        if value.contains("compartilh") { shareCurrent(); return true }
        if value.contains("compare") {
            assistantResponse = "Para comparar, selecione dois documentos. O documento atual continua ativo."
            return true
        }
        if value.hasSuffix("?") || value.hasPrefix("pergunte") || value.hasPrefix("qual ") || value.hasPrefix("quem ") || value.hasPrefix("quando ") {
            askCurrent(command); return true
        }
        return false
    }

    static func copyDestinationHint(from normalizedCommand: String) -> String? {
        let copyVerbs = ["copie", "copiar", "salve", "salvar"]
        guard copyVerbs.contains(where: { normalizedCommand.hasPrefix($0 + " ") || normalizedCommand == $0 }) else { return nil }
        for separator in [" para ", " em ", " na pasta ", " no diretorio "] {
            if let range = normalizedCommand.range(of: separator) {
                let hint = normalizedCommand[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return hint.isEmpty ? "pasta escolhida" : hint
            }
        }
        return "pasta escolhida"
    }

    static func isGenericLocalFileSearch(_ normalizedCommand: String) -> Bool {
        let verbs = ["ache", "buscar", "busque", "encontre", "localize", "pesquise", "procure"]
        guard verbs.contains(where: { normalizedCommand.contains($0) }) else { return false }
        let nonFileTargets = ["album", "foto", "fotos", "galeria", "site", "pagina web", "http://", "https://"]
        return !nonFileTargets.contains(where: { normalizedCommand.contains($0) })
    }

    private func copyCurrentInteractively(destinationHint: String) {
        guard let sourceURL = previewURL else {
            state = .failed("O documento selecionado ainda não está disponível para cópia.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Escolha a pasta de destino"
        panel.message = "Destino solicitado: \(destinationHint). O Pavlak copiará o arquivo e preservará o original."
        panel.prompt = "Escolher esta pasta"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else {
            assistantResponse = "Cópia cancelada. O arquivo original não foi alterado."
            return
        }

        let requestedURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        let destinationURL = Self.availableCopyDestination(for: requestedURL)
        let confirmation = NSAlert()
        confirmation.messageText = "Confirmar cópia?"
        confirmation.informativeText = "Origem:\n\(sourceURL.path)\n\nDestino:\n\(destinationURL.path)\n\nO original será preservado."
        confirmation.addButton(withTitle: "Copiar")
        confirmation.addButton(withTitle: "Cancelar")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            assistantResponse = "Cópia cancelada. O arquivo original não foi alterado."
            return
        }

        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            assistantResponse = "Cópia concluída em \(destinationURL.path). O original foi preservado."
            PavlakErrorReporter.shared.report(module: "DocumentSession", action: "copiar_documento", message: "Documento copiado após confirmação do usuário.", error: nil, result: "concluido")
        } catch {
            state = .failed("Não foi possível copiar o documento para a pasta escolhida.")
            PavlakErrorReporter.shared.report(module: "DocumentSession", action: "copiar_documento", message: "A cópia confirmada não foi concluída.", error: error, result: "erro_recuperado")
        }
    }

    private static func availableCopyDestination(for requestedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requestedURL.path) else { return requestedURL }
        let directory = requestedURL.deletingLastPathComponent()
        let ext = requestedURL.pathExtension
        let base = requestedURL.deletingPathExtension().lastPathComponent
        for number in 2...999 {
            let filename = ext.isEmpty ? "\(base) (cópia \(number))" : "\(base) (cópia \(number)).\(ext)"
            let candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(requestedURL.lastPathComponent)")
    }

    private func compareNamesInAttachments() {
        let urls = Array(attachments.prefix(2))
        state = .orchestrating
        assistantResponse = nil
        isProcessingDocument = true
        Task {
            defer { isProcessingDocument = false }
            do {
                let texts = try urls.map { url -> String in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try Self.extractAttachmentText(url)
                }
                let names = AttachmentNameComparator.commonNames(in: texts)
                if names.isEmpty {
                    assistantResponse = "Não encontrei nomes de pessoas que apareçam claramente nos dois documentos anexados."
                } else {
                    assistantResponse = "Nomes encontrados nos dois documentos:\n\n" + names.map { "• \($0)" }.joined(separator: "\n")
                }
            } catch {
                assistantResponse = "Não foi possível ler os dois documentos anexados."
                PavlakErrorReporter.shared.report(module: "DocumentSession", action: "comparar_nomes_anexos", message: "A comparação local dos anexos não foi concluída.", error: error, result: "erro_recuperado")
            }
        }
    }

    private static func extractAttachmentText(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let text = PDFDocument(url: url)?.string, !text.isEmpty { return text }
        if ["txt", "md"].contains(ext) { return try String(contentsOf: url, encoding: .utf8) }
        if let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string, !text.isEmpty { return text }
        throw FileIndexError.unsupportedDocument
    }


    private func record(_ point: NavigationPoint) {
        if history.indices.contains(historyPosition), history[historyPosition] == point { return }
        if historyPosition + 1 < history.count { history.removeSubrange((historyPosition + 1)..<history.count) }
        history.append(point)
        historyPosition = history.count - 1
        objectWillChange.send()
    }

    private func navigate(to position: Int) {
        guard history.indices.contains(position) else { return }
        historyPosition = position
        let point = history[position]
        objectWillChange.send()
        switch point {
        case .idle:
            releasePreviewAccess(); selected = nil; previewURL = nil; assistantResponse = nil; state = .idle
        case .results:
            releasePreviewAccess(); selected = nil; previewURL = nil; assistantResponse = nil; state = .results
        case .entity:
            releasePreviewAccess(); selected = nil; previewURL = nil; assistantResponse = nil; state = .entity
        case .document(let id):
            guard let candidate = candidates.first(where: { $0.id == id }) else { return }
            Task { await select(candidate, recordHistory: false) }
        }
    }

    private func documentText(for candidate: FileSearchCandidate) async throws -> String {
        if let text = cachedText[candidate.id] { return text }
        let text = try await index.extractText(from: candidate)
        cachedText[candidate.id] = text
        return text
    }

    private static func answer(question: String, from text: String) -> String {
        let ignored = Set(["para", "como", "qual", "quais", "quem", "quando", "onde", "sobre", "este", "esta", "documento"])
        let terms = Set(normalize(question).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !ignored.contains($0) })
        let passages = text.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ".!?")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 25 }
        let ranked = passages.map { passage in
            (passage, terms.reduce(0) { $0 + (normalize(passage).contains($1) ? 1 : 0) })
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        guard !ranked.isEmpty else { return "Não encontrei no texto um trecho suficientemente relacionado à pergunta."
        }
        return "Trechos mais relacionados no documento:\n\n" + ranked.joined(separator: ".\n\n") + "."
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func webURL(_ value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        return URL(string: "https://\(value)")
    }
}
#endif

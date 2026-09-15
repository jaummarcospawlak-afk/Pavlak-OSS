#if os(macOS)
import AppKit
import Combine
import Foundation

struct PavlakChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
}

struct PavlakActiveItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case file, photo }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
}

@MainActor
final class PavlakAgent: ObservableObject {
    nonisolated static let supportedToolNames = ["search_files", "search_photos", "search_photo_album", "open_item", "get_active_context"]
    enum State: Equatable {
        case idle, thinking, searchingPhotos, searchingFiles, found(Int), analyzing, completed, failed(String)
        var label: String? {
            switch self {
            case .idle: nil
            case .thinking: "Pensando…"
            case .searchingPhotos: "Pesquisando Fotos…"
            case .searchingFiles: "Pesquisando arquivos…"
            case .found(let count): "Encontrados \(count) resultados"
            case .analyzing: "Analisando…"
            case .completed: "Concluído"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var messages: [PavlakChatMessage] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var activeContext: [PavlakActiveItem] = []
    @Published private(set) var fileResults: [FileSearchCandidate] = []

    let photos = MacPhotoAlbumSearchService()
    let index = FileIndexService()
    private let client: any PavlakResponsesClient
    private let isLocalOnly: @Sendable () -> Bool
    private var filesByID: [String: FileSearchCandidate] = [:]
    private var photoObservation: AnyCancellable?
    private var runningTask: Task<Void, Never>?
    private var contextIsSuspended = false
    private var cachedMessageID: UUID?
    private var cachedMessageIndex: Int?
    private static let conversationDefaultsKey = "PavlakAgent.openAIConversationID.v1"

    init(isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly },
         client: (any PavlakResponsesClient)? = nil) {
        self.isLocalOnly = isLocalOnly
        self.client = client ?? PavlakResponsesClientRouter(isLocalOnly: isLocalOnly)
        photoObservation = photos.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isRunning: Bool {
        switch state { case .thinking, .searchingPhotos, .searchingFiles, .found, .analyzing: true; default: false }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isRunning else { return }
        guard !isLocalOnly() else {
            messages.append(.init(id: UUID(), role: .user, text: value))
            messages.append(.init(id: UUID(), role: .assistant, text: OpenAIUsagePolicy.localOnlyMessage))
            state = .failed(OpenAIUsagePolicy.localOnlyMessage)
            return
        }
        contextIsSuspended = false
        messages.append(.init(id: UUID(), role: .user, text: value))
        state = .thinking
        runningTask = Task { await run(value) }
    }

    func selectPhoto(_ result: MacPhotoSearchResult) async { await photos.select(result) }

    func clearContextForScopedSearch() {
        contextIsSuspended = true
        runningTask?.cancel()
        runningTask = nil
        activeContext = []
        fileResults = []
        filesByID = [:]
        state = .idle
    }

    func activateLocalOnlyMode() {
        let wasRunning = isRunning
        contextIsSuspended = true
        runningTask?.cancel()
        runningTask = nil
        if wasRunning {
            messages.append(.init(id: UUID(), role: .assistant, text: OpenAIUsagePolicy.localOnlyMessage))
        }
        state = wasRunning ? .failed(OpenAIUsagePolicy.localOnlyMessage) : .idle
    }

    func restoreConversation(_ restoredMessages: [PavlakChatMessage]) {
        runningTask?.cancel()
        runningTask = nil
        contextIsSuspended = false
        messages = restoredMessages
        activeContext = []
        fileResults = []
        photos.clearResults()
        // Clear cached streaming index on restore
        cachedMessageID = nil
        cachedMessageIndex = nil
        state = restoredMessages.isEmpty ? .idle : .completed
    }

    func startNewConversation() {
        runningTask?.cancel()
        runningTask = nil
        contextIsSuspended = false
        messages = []
        activeContext = []
        fileResults = []
        photos.clearResults()
        // Clear cached streaming index on new conversation
        cachedMessageID = nil
        cachedMessageIndex = nil
        state = .idle
    }

    private func openFile(_ candidate: FileSearchCandidate) async throws {
        let url = try await index.resolveForPreview(candidate.file)
        defer { url.stopAccessingSecurityScopedResource() }
        try PavlakWorkspaceOpener.open(url)
    }

    private func run(_ input: String) async {
        let operation = PavlakErrorReporter.shared.begin(module: "PavlakAgent", action: "mensagem")
        do {
            let conversationID = try await conversationID()
            var nextInput: JSONValue = .string(input)
            var iterations = 0
            let maxCycles = PavlakAIConfigurationStore.load().provider == .azureOpenAI
                ? CloudBudget.shared.limits.cycles : 8
            while true {
                guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
                iterations += 1
                guard iterations <= maxCycles else { throw PavlakAgentError.stepLimit }
                let messageID = UUID()
                messages.append(.init(id: messageID, role: .assistant, text: ""))
                // Cache the index of the streaming assistant message to avoid linear searches per delta
                cachedMessageID = messageID
                cachedMessageIndex = messages.count - 1
                state = iterations == 1 ? .thinking : .analyzing
                let turn = try await client.stream(
                    input: nextInput, conversationID: conversationID,
                    instructions: instructions, tools: toolDefinitions
                ) { [weak self] delta in
                    await MainActor.run { [weak self] in
                        guard self?.contextIsSuspended == false else { return }
                        self?.append(delta, to: messageID)
                    }
                }
                guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
                if turn.calls.isEmpty {
                    if messages.last(where: { $0.id == messageID })?.text.isEmpty == true {
                        removeMessage(messageID)
                        throw PavlakAgentError.emptyResponse
                    }
                    state = .completed
                    PavlakErrorReporter.shared.finish(operation, result: "concluido")
                    return
                }
                if messages.last(where: { $0.id == messageID })?.text.isEmpty == true { removeMessage(messageID) }
                var outputs: [JSONValue] = []
                for call in turn.calls {
                    let output = await execute(call)
                    outputs.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(call.callID),
                        "output": .string(output)
                    ]))
                }
                state = .analyzing
                nextInput = .array(outputs)
            }
        } catch {
            if contextIsSuspended || Task.isCancelled {
                PavlakErrorReporter.shared.finish(operation, result: "cancelado_para_busca_restrita")
                return
            }
            let message = (error as? OpenAIAPIError)?.userMessage ?? error.localizedDescription
            messages.append(.init(id: UUID(), role: .assistant, text: message))
            state = .failed(message)
            PavlakErrorReporter.shared.finish(operation, result: "erro_recuperado")
            PavlakErrorReporter.shared.report(module: "PavlakAgent", action: "mensagem", message: "O agente não concluiu a conversa.", error: error, result: "erro_recuperado")
        }
    }

    private func execute(_ call: OpenAIFunctionCall) async -> String {
        do {
            guard !contextIsSuspended else { throw CancellationError() }
            guard let data = call.arguments.data(using: .utf8),
                  let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PavlakAgentError.invalidArguments
            }
            switch call.name {
            case "search_files":
                state = .searchingFiles
                let query = arguments["query"] as? String ?? ""
                let limit = arguments["max_results"] as? Int ?? 8
                return try await searchFiles(query: query, limit: limit)
            case "search_photos":
                state = .searchingPhotos
                let query = arguments["query"] as? String ?? ""
                await photos.search(query: query)
                return try photoResultJSON(query: query)
            case "search_photo_album":
                state = .searchingPhotos
                guard let album = arguments["album"] as? String else { throw PavlakAgentError.invalidArguments }
                let query = arguments["query"] as? String ?? ""
                await photos.search(query: query, inAlbum: album)
                return try photoResultJSON(query: query)
            case "open_item":
                guard let id = arguments["item_id"] as? String,
                      activeContext.contains(where: { $0.id == id }) else { throw PavlakAgentError.itemOutsideContext }
                if let photo = photos.results.first(where: { $0.id == id }) { await photos.open(photo) }
                else if let file = filesByID[id] { try await openFile(file) }
                else { throw PavlakAgentError.itemOutsideContext }
                return json(["status": "opened", "item_id": id])
            case "get_active_context": return activeContextJSON()
            default: throw PavlakAgentError.unsupportedTool(call.name)
            }
        } catch {
            return json(["status": "error", "message": error.localizedDescription])
        }
    }

    private func searchFiles(query: String, limit: Int) async throws -> String {
        await index.reload()
        PavlakConnectorRegistry.shared.noteAuthorizedFolders(!index.snapshot.roots.isEmpty)
        guard PavlakConnectorRegistry.shared.canExecute("files.search") else { throw AgentError.capabilityUnavailable("files.search") }
        let ranked = await index.searchIncludingContent(command: query, limit: limit)
        guard !contextIsSuspended else { throw CancellationError() }
        fileResults = Array(ranked.prefix(max(1, min(limit, 20))))
        filesByID = Dictionary(uniqueKeysWithValues: fileResults.map { ($0.id, $0) })
        activeContext = fileResults.map { .init(id: $0.id, kind: .file, title: $0.file.name, subtitle: $0.file.relativePath) }
        state = .found(fileResults.count)
        return json(["status": "ok", "query": query, "count": fileResults.count,
                     "items": fileResults.map { ["id": $0.id, "name": $0.file.name, "location": $0.file.relativePath] }])
    }

    private func photoResultJSON(query: String) throws -> String {
        guard !contextIsSuspended else { throw CancellationError() }
        if case .failed(let message) = photos.state { throw PavlakAgentError.toolFailure(message) }
        let results = photos.results
        activeContext = results.map { .init(id: $0.id, kind: .photo, title: $0.filename ?? "Foto", subtitle: "Álbum \($0.albumTitle)") }
        state = .found(results.count)
        return json(["status": "ok", "query": query, "album": photos.searchedAlbumName, "count": results.count,
                     "items": results.map { ["id": $0.id, "name": $0.filename ?? "Foto", "album": $0.albumTitle] }])
    }

    private func conversationID() async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: Self.conversationDefaultsKey), !saved.isEmpty { return saved }
        let created = try await client.createConversation()
        UserDefaults.standard.set(created, forKey: Self.conversationDefaultsKey)
        return created
    }

    private func append(_ delta: String, to id: UUID) {
        if let cachedID = cachedMessageID, cachedID == id, let idx = cachedMessageIndex,
           idx >= 0, idx < messages.count, messages[idx].id == id {
            messages[idx].text += delta
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
        // update cache to speedup future appends
        cachedMessageID = id
        cachedMessageIndex = index
    }
    private func removeMessage(_ id: UUID) {
        messages.removeAll { $0.id == id }
        if cachedMessageID == id {
            cachedMessageID = nil
            cachedMessageIndex = nil
        }
    }
    private func normalize(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")).lowercased() }
    private func activeContextJSON() -> String { json(["status": "ok", "count": activeContext.count, "items": activeContext.map { ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title, "subtitle": $0.subtitle] }]) }
    private func json(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) else { return "{\"status\":\"encoding_error\"}" }; return string }

    private var instructions: String { """
        Você é o PavlakAgent e responde em português do Brasil. Você nunca acessa nem executa ações do macOS diretamente.
        Use exclusivamente as ferramentas fornecidas. Para pesquisar um álbum nomeado, use search_photo_album; nunca substitua por busca geral.
        Para referências como “o primeiro”, “esse mesmo nome” ou “este documento”, consulte o contexto ativo e use seus IDs.
        Para “Abra o primeiro”, use open_item com o primeiro ID do contexto atual e não faça nova busca.
        Só afirme que encontrou ou abriu algo após receber sucesso da ferramenta. Seja conciso e mencione a quantidade real de resultados.
        """ }

    private var toolDefinitions: [OpenAIToolDefinition] {
        [
            tool("search_files", "Pesquisa arquivos somente nas pastas autorizadas pelo usuário.", ["query": .stringType, "max_results": .resultLimitType]),
            tool("search_photos", "Pesquisa fotos em toda a Fototeca autorizada usando metadados e OCR locais.", ["query": .stringType]),
            tool("search_photo_album", "Pesquisa fotos somente em um álbum real do PhotoKit.", ["query": .stringType, "album": .stringType]),
            tool("open_item", "Abre um item que já está no ActiveContext; nunca aceita itens externos ao contexto.", ["item_id": .stringType]),
            tool("get_active_context", "Retorna os resultados locais mantidos para comandos contextuais.", [:])
        ]
    }
    private func tool(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> OpenAIToolDefinition {
        .init(name: name, description: description, parameters: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }
}

private extension JSONValue {
    static var stringType: JSONValue { .object(["type": .string("string")]) }
    static var resultLimitType: JSONValue { .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)]) }
}

private enum PavlakAgentError: LocalizedError {
    case stepLimit, emptyResponse, invalidArguments, itemOutsideContext, unsupportedTool(String), toolFailure(String)
    var errorDescription: String? {
        switch self {
        case .stepLimit: "A solicitação excedeu o limite seguro de etapas."
        case .emptyResponse: "A OpenAI não retornou uma resposta final."
        case .invalidArguments: "A ferramenta recebeu argumentos inválidos."
        case .itemOutsideContext: "O item solicitado não pertence ao contexto ativo."
        case .unsupportedTool(let name): "A ferramenta \(name) não está disponível."
        case .toolFailure(let message): message
        }
    }
}
#endif

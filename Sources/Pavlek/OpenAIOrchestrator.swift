#if os(macOS)
import AppKit
import Foundation
import PDFKit
import Photos

struct OrchestratedDocument: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let location: String
    let candidate: FileSearchCandidate?
    let attachmentURL: URL?
}

@MainActor
final class OpenAIOrchestrator: ObservableObject {
    enum State: Equatable { case idle, reasoning, runningTool(String), finished, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var response = ""
    @Published private(set) var activeDocuments: [OrchestratedDocument] = []

    private let index: FileIndexService
    private let client: any PavlakResponsesClient
    private let photos = PhotoLibraryService()
    private let registry = PavlakConnectorRegistry.shared
    private var documents: [String: OrchestratedDocument] = [:]
    private var attachmentScopes: [URL] = []
    private var runningTask: Task<Void, Never>?
    private var contextIsSuspended = false

    init(index: FileIndexService, client: (any PavlakResponsesClient)? = nil) {
        self.index = index
        self.client = client ?? PavlakResponsesClientRouter()
    }

    deinit { for url in attachmentScopes { url.stopAccessingSecurityScopedResource() } }

    func run(_ command: String, attachments: [URL] = []) {
        guard !OpenAIUsagePolicy.isLocalOnly else {
            response = OpenAIUsagePolicy.localOnlyMessage
            state = .failed(OpenAIUsagePolicy.localOnlyMessage)
            return
        }
        contextIsSuspended = false
        state = .reasoning
        response = ""
        registerAttachments(attachments)
        let operation = PavlakErrorReporter.shared.begin(module: "OpenAIOrchestrator", action: "executar_solicitacao")
        runningTask = Task {
            do {
                guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
                let documentContext = activeDocuments.map { "\($0.id): \($0.name) [\($0.location)]" }.joined(separator: "\n")
                let input = documentContext.isEmpty ? command : "\(command)\n\nDocumentos mantidos no contexto local e disponíveis por identificador:\n\(documentContext)"
                var turn = try await client.start(input: input, instructions: instructions, tools: toolDefinitions)
                var iterations = 0
                let maxCycles = PavlakAIConfigurationStore.load().provider == .azureOpenAI
                    ? CloudBudget.shared.limits.cycles : 6
                while !turn.calls.isEmpty {
                    guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
                    iterations += 1
                    guard iterations <= maxCycles else { throw OrchestratorError.stepLimit }
                    var outputs: [OpenAIFunctionOutput] = []
                    for call in turn.calls {
                        state = .runningTool(call.name)
                        let output = await execute(call)
                        outputs.append(OpenAIFunctionOutput(callID: call.callID, output: output))
                    }
                    state = .reasoning
                    turn = try await client.continueTurn(previousResponseID: turn.id, outputs: outputs, instructions: instructions, tools: toolDefinitions)
                }
                guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
                guard let text = turn.text, !text.isEmpty else { throw OrchestratorError.emptyResponse }
                response = text
                state = .finished
                PavlakErrorReporter.shared.finish(operation, result: "resposta_apresentada")
            } catch {
                if contextIsSuspended || Task.isCancelled {
                    PavlakErrorReporter.shared.finish(operation, result: "cancelado_para_busca_restrita")
                    return
                }
                response = error.localizedDescription
                state = .failed(error.localizedDescription)
                PavlakErrorReporter.shared.finish(operation, result: "erro_recuperado")
                PavlakErrorReporter.shared.report(module: "OpenAIOrchestrator", action: "executar_solicitacao", message: "O orquestrador não concluiu a solicitação.", error: error, result: "erro_recuperado")
            }
        }
    }

    func setActiveCandidates(_ candidates: [FileSearchCandidate]) {
        let attachmentDocuments = activeDocuments.filter { $0.attachmentURL != nil }
        let candidateDocuments = candidates.map { candidate in
            let document = OrchestratedDocument(
                id: candidate.id, name: candidate.file.name, type: candidate.file.fileExtension.uppercased(),
                location: candidate.file.relativePath, candidate: candidate, attachmentURL: nil
            )
            documents[document.id] = document
            return document
        }
        activeDocuments = candidateDocuments + attachmentDocuments
    }

    func clearContextForScopedSearch() {
        contextIsSuspended = true
        runningTask?.cancel()
        runningTask = nil
        for url in attachmentScopes { url.stopAccessingSecurityScopedResource() }
        attachmentScopes = []
        documents = [:]
        activeDocuments = []
        response = ""
        state = .idle
    }

    func activateLocalOnlyMode() {
        let wasRunning: Bool
        switch state {
        case .reasoning, .runningTool: wasRunning = true
        case .idle, .finished, .failed: wasRunning = false
        }
        contextIsSuspended = true
        runningTask?.cancel()
        runningTask = nil
        if wasRunning {
            response = OpenAIUsagePolicy.localOnlyMessage
            state = .failed(OpenAIUsagePolicy.localOnlyMessage)
        }
    }

    func openDocument(_ document: OrchestratedDocument) async {
        do {
            try await openDocumentOrThrow(document)
        } catch {
            PavlakErrorReporter.shared.report(module: "OpenAIOrchestrator", action: "abrir_documento", message: "Não foi possível abrir o documento ativo.", error: error, result: "erro_recuperado")
        }
    }

    private func openDocumentOrThrow(_ document: OrchestratedDocument) async throws {
        guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
        let url: URL
        if let attachment = document.attachmentURL { url = attachment }
        else if let candidate = document.candidate { url = try await index.resolveForPreview(candidate.file) }
        else { throw OrchestratorError.unknownDocument }
        defer {
            if document.candidate != nil { url.stopAccessingSecurityScopedResource() }
        }
        guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
        try PavlakWorkspaceOpener.open(url)
    }

    private func execute(_ call: OpenAIFunctionCall) async -> String {
        do {
            guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
            guard let data = call.arguments.data(using: .utf8),
                  let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OrchestratorError.invalidArguments }
            switch call.name {
            case "files_search":
                return try await searchFiles(query: args["query"] as? String ?? "", limit: args["max_results"] as? Int ?? 8)
            case "documents_read":
                return try await readDocuments(ids: args["document_ids"] as? [String] ?? [], focus: args["focus"] as? String ?? "", maximum: args["max_characters_per_document"] as? Int ?? 6000)
            case "content_open":
                guard let id = args["document_id"] as? String, let document = documents[id] else { throw OrchestratorError.unknownDocument }
                try await openDocumentOrThrow(document)
                return json(["status": "opened", "document_id": id])
            case "finder_reveal":
                guard let id = args["document_id"] as? String, let document = documents[id] else { throw OrchestratorError.unknownDocument }
                let url = try await resolvedURL(for: document)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if document.candidate != nil { url.stopAccessingSecurityScopedResource() }
                return json(["status": "revealed", "document_id": id])
            case "content_share":
                guard let id = args["document_id"] as? String, let document = documents[id], let view = NSApp.keyWindow?.contentView else { throw OrchestratorError.unknownDocument }
                let url = try await resolvedURL(for: document)
                NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                if document.candidate != nil {
                    Task { try? await Task.sleep(for: .seconds(60)); url.stopAccessingSecurityScopedResource() }
                }
                return json(["status": "share_sheet_presented", "document_id": id])
            case "safari_open":
                guard registry.canExecute("web.open") else { throw AgentError.capabilityUnavailable("web.open") }
                guard let value = args["url"] as? String, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw OrchestratorError.invalidURL }
                try PavlakWorkspaceOpener.open(url)
                return json(["status": "opened", "url": value])
            case "safari_search":
                guard registry.canExecute("web.open") else { throw AgentError.capabilityUnavailable("web.open") }
                guard let query = args["query"] as? String,
                      var components = URLComponents(string: "https://www.google.com/search") else { throw OrchestratorError.invalidURL }
                components.queryItems = [URLQueryItem(name: "q", value: query)]
                guard let url = components.url else { throw OrchestratorError.invalidURL }
                try PavlakWorkspaceOpener.open(url)
                return json(["status": "opened_search", "query": query])
            case "photos_search":
                guard registry.canExecute("photos.search") else { return json(["status": "permission_required"]) }
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard status == .authorized || status == .limited else { return json(["status": "permission_required"]) }
                let query = args["query"] as? String ?? ""
                let period = PavlakIntentRouter.parse(query).period
                let result = try photos.locatePhotos(period: period)
                return json(["status": "ok", "matched_items": result.matchedItemCount, "accessible_items": result.accessibleItemCount])
            default: throw OrchestratorError.unsupportedTool(call.name)
            }
        } catch {
            PavlakErrorReporter.shared.report(module: "OpenAIOrchestrator", action: "executar_ferramenta_\(call.name)", message: "Uma ferramenta solicitada pelo orquestrador falhou de forma recuperável.", error: error, result: "erro_retornado_ao_modelo")
            return json(["status": "error", "message": error.localizedDescription])
        }
    }

    private func searchFiles(query: String, limit: Int) async throws -> String {
        await index.reload()
        registry.noteAuthorizedFolders(!index.snapshot.roots.isEmpty)
        guard registry.canExecute("files.search") else { throw AgentError.capabilityUnavailable("files.search") }
        let ranked = await index.searchIncludingContent(command: query, limit: limit)
        guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
        let selected = ranked.map { candidate -> [String: Any] in
            let file = candidate.file
            let document = OrchestratedDocument(id: file.id, name: file.name, type: file.fileExtension.uppercased(), location: file.relativePath, candidate: candidate, attachmentURL: nil)
            documents[file.id] = document
            return ["id": file.id, "name": file.name, "type": file.fileExtension, "location": file.relativePath, "score": candidate.score]
        }
        activeDocuments = selected.compactMap { documents[$0["id"] as? String ?? ""] }
        return json(["query": query, "count": selected.count, "documents": selected])
    }

    private func readDocuments(ids: [String], focus: String, maximum: Int) async throws -> String {
        let boundedIDs = Array(ids.prefix(6))
        var results: [[String: Any]] = []
        for id in boundedIDs {
            guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
            guard let document = documents[id] else { continue }
            let text: String
            if let candidate = document.candidate { text = try await index.extractText(from: candidate) }
            else if let url = document.attachmentURL { text = try Self.extractAttachment(url) }
            else { continue }
            let excerpt = Self.relevantExcerpt(text: text, focus: focus, maximum: max(500, min(maximum, 10_000)))
            results.append(["id": id, "name": document.name, "excerpt": excerpt, "characters_sent": excerpt.count])
        }
        guard !contextIsSuspended, !Task.isCancelled else { throw CancellationError() }
        activeDocuments = boundedIDs.compactMap { documents[$0] }
        return json(["focus": focus, "documents": results])
    }

    private func registerAttachments(_ urls: [URL]) {
        for url in urls.prefix(6) {
            if url.startAccessingSecurityScopedResource() { attachmentScopes.append(url) }
            let id = "attachment-\(Self.stableID(url.path))"
            documents[id] = OrchestratedDocument(id: id, name: url.lastPathComponent, type: url.pathExtension.uppercased(), location: "Anexo", candidate: nil, attachmentURL: url)
        }
        activeDocuments = urls.compactMap { url in documents["attachment-\(Self.stableID(url.path))"] }
    }

    private var instructions: String { """
        Você é o motor de interpretação e raciocínio do Pavlak. Responda em português do Brasil.
        Você não tem acesso direto ao macOS: toda busca, leitura ou abertura deve ocorrer somente pelas ferramentas fornecidas.
        Pesquise primeiro metadados. Leia no máximo os documentos candidatos necessários e solicite foco específico para minimizar dados.
        Nunca afirme que abriu, leu ou encontrou algo sem um resultado de ferramenta. Preserve os documentos úteis para perguntas seguintes.
        Quando comparar documentos, cite seus nomes e baseie a conclusão exclusivamente nos trechos retornados.
        """ }

    private var toolDefinitions: [OpenAIToolDefinition] {
        [
            tool("files_search", "Pesquisa metadados de arquivos nas pastas explicitamente autorizadas pelo usuário.", ["query": .stringType, "max_results": .resultLimitType]),
            tool("documents_read", "Extrai somente trechos relevantes de até seis documentos já encontrados ou anexados.", ["document_ids": .arrayStringType, "focus": .stringType, "max_characters_per_document": .characterLimitType]),
            tool("content_open", "Abre no macOS um documento já encontrado, somente quando o usuário pedir.", ["document_id": .stringType]),
            tool("finder_reveal", "Revela no Finder o arquivo original já encontrado, somente quando o usuário pedir.", ["document_id": .stringType]),
            tool("content_share", "Apresenta a folha nativa de compartilhamento para um documento escolhido; o usuário confirma o destino.", ["document_id": .stringType]),
            tool("safari_open", "Abre uma URL HTTP ou HTTPS no Safari quando solicitado.", ["url": .stringType]),
            tool("safari_search", "Abre no Safari uma pesquisa web solicitada pelo usuário.", ["query": .stringType]),
            tool("photos_search", "Consulta Fotos em modo somente leitura quando a permissão já estiver concedida.", ["query": .stringType])
        ]
    }

    private func tool(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> OpenAIToolDefinition {
        OpenAIToolDefinition(name: name, description: description, parameters: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }

    private func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{\"status\":\"encoding_error\"}" }
        return text
    }

    private func resolvedURL(for document: OrchestratedDocument) async throws -> URL {
        if let attachment = document.attachmentURL { return attachment }
        if let candidate = document.candidate { return try await index.resolveForPreview(candidate.file) }
        throw OrchestratorError.unknownDocument
    }

    private static func extractAttachment(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf", let text = PDFDocument(url: url)?.string, !text.isEmpty { return text }
        if ["txt", "md"].contains(url.pathExtension.lowercased()) { return try String(contentsOf: url, encoding: .utf8) }
        if let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string, !text.isEmpty { return text }
        throw FileIndexError.unsupportedDocument
    }

    private static func relevantExcerpt(text: String, focus: String, maximum: Int) -> String {
        let terms = searchTerms(focus)
        guard !terms.isEmpty else { return String(text.prefix(maximum)) }
        let blocks = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 20 }
        let ranked = blocks.map { block in (block, terms.reduce(0) { $0 + (normalize(block).contains($1) ? 1 : 0) }) }.sorted { $0.1 > $1.1 }
        var output = ""
        for (block, score) in ranked where score > 0 {
            guard output.count < maximum else { break }
            output += block + "\n"
        }
        return output.isEmpty ? String(text.prefix(min(maximum, 2000))) : String(output.prefix(maximum))
    }

    private static func searchTerms(_ value: String) -> [String] {
        let ignored = Set(["meu", "meus", "minha", "minhas", "com", "nome", "diga", "eles", "elas", "tem", "têm", "comum", "localize", "encontre", "documento", "documentos"])
        return normalize(value).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !ignored.contains($0) }
    }
    private static func normalize(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")) }
    private static func stableID(_ value: String) -> String { String(value.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) }
}

private extension JSONValue {
    static var stringType: JSONValue { .object(["type": .string("string")]) }
    static var resultLimitType: JSONValue { .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)]) }
    static var characterLimitType: JSONValue { .object(["type": .string("integer"), "minimum": .number(500), "maximum": .number(10000)]) }
    static var arrayStringType: JSONValue { .object(["type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .number(6)]) }
}

enum OrchestratorError: LocalizedError {
    case stepLimit, emptyResponse, invalidArguments, unknownDocument, invalidURL, unsupportedTool(String)
    var errorDescription: String? {
        switch self {
        case .stepLimit: "A solicitação exigiu etapas demais e foi interrompida com segurança."
        case .emptyResponse: "A OpenAI não retornou uma resposta final."
        case .invalidArguments: "A ferramenta recebeu parâmetros inválidos."
        case .unknownDocument: "O documento solicitado não está mais no contexto."
        case .invalidURL: "O endereço solicitado não é válido."
        case .unsupportedTool(let name): "A ferramenta \(name) não está disponível no Pavlak."
        }
    }
}
#endif

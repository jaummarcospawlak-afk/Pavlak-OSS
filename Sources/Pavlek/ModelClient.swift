import Foundation

protocol ModelClient: Sendable {
    var displayName: String { get }
    func interpret(_ command: String, tools: [String]) async throws -> AgentIntent
    func continueAfterTool(command: String, intent: AgentIntent, result: ToolResult) async throws -> String
}

struct LocalFallbackModelClient: ModelClient {
    let displayName = "Interpretação local"

    func interpret(_ command: String, tools: [String]) async throws -> AgentIntent {
        let parsed = IntentParser.parse(command)
        return AgentIntent(
            action: parsed.action,
            source: parsed.source.rawValue,
            object: parsed.object,
            period: parsed.period,
            toolName: parsed.source == .photos ? ToolRouter.photoSearchTool : "unsupported"
        )
    }

    func continueAfterTool(command: String, intent: AgentIntent, result: ToolResult) async throws -> String {
        guard result.matchedItemCount > 0 else {
            return "Não encontrei fotos no período “\(intent.period)”. Tente ampliar o período da busca."
        }
        let videos = result.photos.filter { $0.mediaType == "Vídeo" }.count
        let favorites = result.photos.filter(\.isFavorite).count
        return "Encontrei \(result.matchedItemCount) itens no período “\(intent.period)”. A amostra exibida inclui \(videos) vídeo(s) e \(favorites) favorito(s), ordenados do mais recente para o mais antigo."
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
actor AppleFoundationModelClient: ModelClient {
    nonisolated let displayName = "Apple Intelligence"
    private let session = LanguageModelSession(instructions: """
        Você é o núcleo do Pavlek, um assistente macOS orientado a ferramentas.
        Escolha somente ferramentas fornecidas. Nunca invente ferramentas e nunca peça ações de escrita.
        Responda em português do Brasil. Quando solicitado JSON, responda somente JSON válido.
        """)

    func interpret(_ command: String, tools: [String]) async throws -> AgentIntent {
        let response = try await session.respond(to: """
            Interprete o comando: \(command)
            Ferramentas permitidas: \(tools.joined(separator: ", "))
            Retorne JSON com exatamente: action, source, object, period, toolName.
            Use photos.search somente para localizar ou consultar fotos. Não há ferramentas de escrita.
            """)
        guard let data = extractJSON(from: response.content).data(using: .utf8),
              let intent = try? JSONDecoder().decode(AgentIntent.self, from: data),
              tools.contains(intent.toolName) else {
            throw AgentError.invalidModelResponse
        }
        return intent
    }

    func continueAfterTool(command: String, intent: AgentIntent, result: ToolResult) async throws -> String {
        let payload = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? "{}"
        let response = try await session.respond(to: """
            O Tool Router executou \(result.toolName) para o comando “\(command)”.
            Resultado estruturado: \(payload)
            Continue a ação com um resumo curto, factual e sem afirmar que analisou o conteúdo visual das fotos.
            """)
        return response.content
    }

    private func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }
}
#endif

enum ModelClientFactory {
    static func make() -> any ModelClient {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleFoundationModelClient()
        }
        #endif
        return LocalFallbackModelClient()
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PavlakToolCall: @unchecked Sendable {
    public let callID: String
    public let name: String
    public let arguments: [String: Any]

    public init(callID: String, name: String, arguments: [String: Any]) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public final class PavlakResponsesClient: @unchecked Sendable {
    public let model: String
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let connection: PavlakOpenAIConnectionService
    private let transport: any PavlakHTTPTransport

    public init(
        model: String = "gpt-5.6",
        connection: PavlakOpenAIConnectionService = .shared,
        transport: any PavlakHTTPTransport = PavlakURLSessionTransport()
    ) {
        self.model = model
        self.connection = connection
        self.transport = transport
    }

    public func createResponse(
        input: [Any],
        tools: [[String: Any]] = PavlakToolDefinitions.all
    ) async throws -> [String: Any] {
        let instructions = """
        Você é o motor de interpretação do Pavlak. O Pavlak coordena e executa as ferramentas locais.

        Regras obrigatórias:
        - Use ferramentas quando o pedido exigir uma ação real no dispositivo.
        - Use browser_search para pesquisa visível no Safari e web_search apenas para obter informação atual.
        - Acesse arquivos somente dentro da pasta que o usuário autorizou.
        - Nunca afirme que uma ação foi concluída sem o retorno positivo da ferramenta.
        - Não apague, mova, envie, compre, pague nem altere configurações.
        - Para pedidos de Fotos ou iPhone sem ferramenta disponível, explique a limitação; não substitua por file_find.
        - Responda em português, de modo direto.
        """

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "tools": tools,
            "parallel_tool_calls": false,
            "store": false
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try await connection.authorizedRequest(
            url: endpoint,
            method: "POST",
            body: data
        )
        let response = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            let message = PavlakOpenAIConnectionService.errorMessage(from: response.data)
            switch response.statusCode {
            case 401:
                throw PavlakError.authenticationFailed(message)
            case 403:
                throw PavlakError.permissionDenied(message)
            case 429:
                throw PavlakError.rateLimited(message)
            default:
                throw PavlakError.api(
                    statusCode: response.statusCode,
                    message: message,
                    requestID: response.requestID
                )
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw PavlakError.invalidResponse
        }
        return object
    }

    public static func functionCalls(from response: [String: Any]) -> [PavlakToolCall] {
        guard let output = response["output"] as? [[String: Any]] else { return [] }
        return output.compactMap { item in
            guard item["type"] as? String == "function_call",
                  let callID = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let rawArguments = item["arguments"] as? String,
                  let data = rawArguments.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return PavlakToolCall(callID: callID, name: name, arguments: arguments)
        }
    }

    public static func outputItems(from response: [String: Any]) -> [[String: Any]] {
        response["output"] as? [[String: Any]] ?? []
    }

    public static func text(from response: [String: Any]) -> String {
        guard let output = response["output"] as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { pieces.append(text) }
            }
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

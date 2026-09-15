import Foundation

@MainActor
public final class PavlakAgentEngine {
    public static let shared = PavlakAgentEngine()

    private let parser: PavlakLocalIntentParser
    private let router: PavlakToolRouter
    private let responses: PavlakResponsesClient

    public init(
        parser: PavlakLocalIntentParser = PavlakLocalIntentParser(),
        router: PavlakToolRouter = PavlakToolRouter(),
        responses: PavlakResponsesClient = PavlakResponsesClient()
    ) {
        self.parser = parser
        self.router = router
        self.responses = responses
    }

    @discardableResult
    public func run(
        _ rawCommand: String,
        onEvent: (@Sendable (PavlakAgentEvent) -> Void)? = nil
    ) async -> String {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "" }
        onEvent?(.interpreting)

        // Caminho rápido e resiliente: executa comandos locais inequívocos sem depender da API.
        if let actions = parser.plan(for: command), !actions.isEmpty {
            var outputs: [String] = []
            for action in actions {
                onEvent?(.executing(action.toolName.rawValue))
                outputs.append(await router.execute(action: action))
            }
            let result = outputs.joined(separator: "\n")
            onEvent?(.completed(result))
            return result
        }

        do {
            var input: [Any] = [["role": "user", "content": command]]
            for cycle in 0..<8 {
                let response = try await responses.createResponse(input: input)
                let calls = PavlakResponsesClient.functionCalls(from: response)

                if calls.isEmpty {
                    let text = PavlakResponsesClient.text(from: response)
                    let result = text.isEmpty ? "A operação terminou sem resposta textual." : text
                    onEvent?(.completed(result))
                    return result
                }

                input.append(contentsOf: PavlakResponsesClient.outputItems(from: response))
                for call in calls {
                    onEvent?(.executing(call.name))
                    let output = await router.execute(name: call.name, arguments: call.arguments)
                    input.append([
                        "type": "function_call_output",
                        "call_id": call.callID,
                        "output": output
                    ])
                }

                if cycle == 7 {
                    let result = "O fluxo foi interrompido após oito ciclos de ferramentas para evitar repetição."
                    onEvent?(.failed(result))
                    return result
                }
            }
        } catch {
            let message = error.localizedDescription
            onEvent?(.failed(message))
            return message
        }

        let fallback = "Não foi possível concluir a solicitação."
        onEvent?(.failed(fallback))
        return fallback
    }
}

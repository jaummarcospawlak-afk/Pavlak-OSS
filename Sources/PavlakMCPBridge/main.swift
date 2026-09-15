import Foundation

private struct StatusSnapshot: Decodable {
    let pavlakState: String
    let availableIntegrations: [String]
    let selectedDocumentCount: Int
    let currentOperation: String?
}

private final class PavlakMCPBridge {
    private let statusURL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        statusURL = base
            .appendingPathComponent("Pavlak", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("status.json")
    }

    func run() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                write(errorResponse(id: NSNull(), code: -32700, message: "JSON inválido"))
                continue
            }
            handle(request)
        }
    }

    private func handle(_ request: [String: Any]) {
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            write(errorResponse(id: id, code: -32600, message: "Requisição inválida"))
            return
        }

        if method.hasPrefix("notifications/") { return }

        switch method {
        case "initialize":
            let params = request["params"] as? [String: Any]
            let requestedProtocol = params?["protocolVersion"] as? String
            write(success(id: id, result: [
                "protocolVersion": requestedProtocol ?? "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "PavlakMCPBridge", "version": "0.1.0"]
            ]))
        case "ping":
            write(success(id: id, result: [:]))
        case "tools/list":
            write(success(id: id, result: ["tools": [[
                "name": "pavlak_status",
                "description": "Consulta, em modo somente leitura, o estado operacional atual do Pavlak.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ]]]))
        case "tools/call":
            handleToolCall(request, id: id)
        default:
            write(errorResponse(id: id, code: -32601, message: "Método não encontrado"))
        }
    }

    private func handleToolCall(_ request: [String: Any], id: Any) {
        guard let params = request["params"] as? [String: Any],
              params["name"] as? String == "pavlak_status"
        else {
            write(errorResponse(id: id, code: -32602, message: "Ferramenta não disponível"))
            return
        }

        let snapshot = loadSnapshot()
        let structured: [String: Any] = [
            "aplicativoAtivo": snapshot == nil ? NSNull() : "Pavlak",
            "estadoPavlak": snapshot?.pavlakState ?? "nao_iniciado",
            "integracoesDisponiveis": snapshot?.availableIntegrations ?? [],
            "documentosSelecionados": snapshot?.selectedDocumentCount ?? 0,
            "operacaoAtual": snapshot?.currentOperation ?? NSNull()
        ]
        let textData = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        let text = textData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        write(success(id: id, result: [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured,
            "isError": false
        ]))
    }

    private func loadSnapshot() -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    private func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func write(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

PavlakMCPBridge().run()

import Foundation

@MainActor
final class PavlakLinkViewModel: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var resultTitle = ""
    @Published private(set) var resultLines: [String] = []
    @Published private(set) var errorMessage: String?
    let link = PavlakLinkService.shared

    func sendPhotoSearch(_ query: String) {
        send(action: .photoSearch, query: query, target: .iPhone)
    }

    func sendFileSearch(_ query: String) {
        send(action: .fileSearch, query: query, target: .mac)
    }

    func stageTransfer(filename: String, contentType: String, data: Data) {
        isWorking = true; errorMessage = nil
        Task {
            do {
                let payload = try PavlakTransferPayload(filename: filename, contentType: contentType, data: data)
                let encoded = try JSONEncoder().encode(payload)
                guard let text = String(data: encoded, encoding: .utf8) else { throw PavlakTransferError.invalidPayload }
                let response = try await link.request(action: .stageTransfer, query: filename, target: .mac, payload: text)
                guard response.status == .success, let result = response.result?.data(using: .utf8) else {
                    throw PavlakLinkResultError.remote(response.result ?? "A bandeja do Mac recusou o item.")
                }
                let receipt = try JSONDecoder().decode(PavlakTransferReceipt.self, from: result)
                resultTitle = receipt.state == "staged" ? "Item recebido na bandeja do Mac" : "Resposta de transferência inválida"
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func sendPing() {
        let target: PavlakDevice = link.localDevice == .mac ? .iPhone : .mac
        isWorking = true; errorMessage = nil
        Task {
            do {
                let response = try await link.request(action: .ping, query: "ping", target: target)
                resultTitle = response.result == "pong" ? "Ping concluído: pong" : "Resposta de ping inválida"
                resultLines = []
            } catch {
                errorMessage = error.localizedDescription
                PavlakErrorReporter.shared.report(module: "PavlakLink", action: "ping", message: "O teste de conexão não foi concluído.", error: error, result: "erro_recuperado")
            }
            isWorking = false
        }
    }

    private func send(action: PavlakLinkAction, query: String, target: PavlakDevice) {
        isWorking = true; errorMessage = nil; resultLines = []
        Task {
            do {
                let response = try await link.request(action: action, query: query, target: target)
                guard response.status == .success, let json = response.result?.data(using: .utf8) else {
                    throw PavlakLinkResultError.remote(response.result ?? "Resposta remota inválida.")
                }
                switch action {
                case .hello, .ping:
                    resultTitle = response.result ?? "Resposta recebida"
                case .photoSearch:
                    let items = try JSONDecoder().decode([PavlakLinkPhotoCandidate].self, from: json)
                    resultTitle = "\(items.count) resultado(s) do iPhone"
                    resultLines = items.map {
                        "\($0.filename ?? "Foto") • \($0.score) pts • \($0.sourceLocation) • \($0.sourceDeviceID) • \($0.processingState)"
                    }
                case .fileSearch:
                    let items = try JSONDecoder().decode([PavlakLinkFileCandidate].self, from: json)
                    resultTitle = "\(items.count) resultado(s) do Mac"
                    resultLines = items.map {
                        "\($0.name) • \($0.score) pts • \($0.sourceLocation) • ID \($0.stableID) • \($0.evidenceSummary)"
                    }
                case .stageTransfer:
                    resultTitle = "Item recebido na bandeja do Mac"
                }
            } catch {
                errorMessage = error.localizedDescription
                PavlakErrorReporter.shared.report(module: "PavlakLink", action: action.rawValue, message: "A solicitação entre dispositivos não foi concluída.", error: error, result: "erro_recuperado")
            }
            isWorking = false
        }
    }
}

enum PavlakLinkResultError: LocalizedError {
    case remote(String)
    var errorDescription: String? { switch self { case .remote(let value): value } }
}

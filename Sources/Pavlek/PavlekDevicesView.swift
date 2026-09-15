#if os(macOS)
import SwiftUI

struct PavlekDevicesView: View {
    @ObservedObject private var link = PavlakLinkService.shared
    @StateObject private var model = PavlakLinkViewModel()
    @State private var pairingCode = ""
    @State private var pairingMessage: String?
    @State private var photoQuery = ""

    var body: some View {
        Form {
            Section("Dispositivos") {
                Label("Este Mac • aplicativo em execução", systemImage: "desktopcomputer")
                LabeledContent("iPhone / iOS", value: link.remoteState == .connected && link.connectedDevices.contains(.iPhone) ? "Conectado ao Pavlek" : "Conexão não confirmada")
                LabeledContent("Transporte", value: link.isTransportEncrypted ? "TLS 1.3 autenticado pelo pareamento" : "Sem conexão protegida")
                Text(link.remoteState.title).foregroundStyle(.secondary)
                Text("Abra o Pavlek no iPhone na mesma rede local. Este painel mostra a comunicação com o aplicativo; não verifica a saúde geral do iOS.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Iniciar conexão local") { link.start() }
                Button("Verificar comunicação") { model.sendPing() }
                    .disabled(link.remoteState != .connected || !link.connectedDevices.contains(.iPhone) || model.isWorking)
                if model.isWorking { ProgressView("Verificando…") }
                if !model.resultTitle.isEmpty { Text(model.resultTitle) }
                if let error = model.errorMessage ?? link.errorMessage { Text(error).foregroundStyle(.orange) }
            }

            Section("Autenticação do Pavlak Link") {
                SecureField("Código compartilhado (mínimo 16 caracteres)", text: $pairingCode)
                Button("Salvar código no Chaveiro") {
                    do {
                        try link.configurePairingCode(pairingCode)
                        pairingCode = ""
                        pairingMessage = "Código preservado neste Mac. Configure o mesmo código no iPhone."
                    } catch { pairingMessage = error.localizedDescription }
                }.disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                if let pairingMessage { Text(pairingMessage).font(.caption).foregroundStyle(.secondary) }
                if link.hasPairingSecret {
                    Button("Revogar pareamento", role: .destructive) {
                        link.revokePairing()
                        pairingMessage = "Pareamento removido deste Mac. Conexões e consultas pendentes foram encerradas."
                    }
                }
            }

            Section("Consultar índice documental do iPhone") {
                TextField("Ex.: conta de energia ou contrato", text: $photoQuery)
                    .onSubmit(runPhotoSearch)
                Button("Buscar no iPhone", action: runPhotoSearch)
                    .disabled(
                        photoQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || link.remoteState != .connected
                            || !link.connectedDevices.contains(.iPhone)
                            || model.isWorking
                    )
                if !model.resultTitle.isEmpty { Text(model.resultTitle).font(.headline) }
                ForEach(Array(model.resultLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).textSelection(.enabled)
                }
                Text("Os resultados preservam o identificador estável e o identificador do dispositivo de origem. A prévia permanece no iPhone de origem.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Dispositivos")
    }

    private func runPhotoSearch() {
        let query = photoQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        model.sendPhotoSearch(query)
    }
}

#endif

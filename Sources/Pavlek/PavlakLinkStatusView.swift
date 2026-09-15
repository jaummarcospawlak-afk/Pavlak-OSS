import SwiftUI

struct PavlakLinkStatusView: View {
    @ObservedObject var link: PavlakLinkService
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Pavlak Link", systemImage: "link.circle.fill").font(.headline)
            if link.remoteState == .connected {
                Label("Pavlak Link — conectado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(link.isTransportEncrypted ? "TLS 1.3 • dispositivo autenticado pelo pareamento" : "Proteção do transporte não confirmada",
                      systemImage: link.isTransportEncrypted ? "lock.shield.fill" : "lock.slash")
                    .font(.caption).foregroundStyle(link.isTransportEncrypted ? .green : .orange)
            } else {
                Label(localLabel, systemImage: link.localDevice == .mac ? "laptopcomputer" : "iphone").foregroundStyle(.green)
                Label(link.remoteState.title, systemImage: remoteSymbol).foregroundStyle(remoteColor)
            }
            if let latency = link.lastLatency { Text("Última resposta: \(Int(latency * 1_000)) ms").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private var localLabel: String { link.localDevice == .mac ? "Mac local — ativo" : "iPhone local — ativo" }
    private var remoteSymbol: String { link.localDevice == .mac ? "iphone" : "laptopcomputer" }
    private var remoteColor: Color { if case .failed = link.remoteState { return .red }; return .secondary }
}

#if os(iOS)
struct PavlakDeviceConnectionView: View {
    @StateObject private var viewModel = PavlakLinkViewModel()
    @State private var pairingCode = ""
    @State private var pairingMessage: String?

    var body: some View {
        List {
            Section("Este dispositivo") {
                Label("Este iPhone", systemImage: "iphone")
                PavlakLinkStatusView(link: viewModel.link)
            }

            Section("Ambiente atual") {
                HStack {
                    Label("Mac com Pavlak", systemImage: "laptopcomputer")
                    Spacer()
                    Text(viewModel.link.connectedDevices.contains(.mac) ? "Conectado" : "Procurando…")
                        .foregroundStyle(viewModel.link.connectedDevices.contains(.mac) ? .green : .secondary)
                }

                Button("Testar conexão", systemImage: "wave.3.right") {
                    viewModel.sendPing()
                }
                .disabled(!viewModel.link.connectedDevices.contains(.mac) || viewModel.isWorking)
            }

            Section("Autenticação") {
                SecureField("Mesmo código do Mac", text: $pairingCode)
                Button("Salvar código no Chaveiro") {
                    do {
                        try viewModel.link.configurePairingCode(pairingCode)
                        pairingCode = ""
                        pairingMessage = "Código salvo. O Link aceitará apenas mensagens autenticadas."
                    } catch { pairingMessage = error.localizedDescription }
                }
                .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                if let pairingMessage { Text(pairingMessage).font(.caption).foregroundStyle(.secondary) }
                if viewModel.link.hasPairingSecret {
                    Button("Revogar pareamento", role: .destructive) {
                        viewModel.link.revokePairing()
                        pairingMessage = "Pareamento removido deste iPhone."
                    }
                }
            }

            if viewModel.isWorking {
                Section { ProgressView("Testando comunicação…") }
            }
            if !viewModel.resultTitle.isEmpty {
                Section("Resultado") {
                    Label(viewModel.resultTitle, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let error = viewModel.errorMessage ?? viewModel.link.errorMessage {
                Section("Atenção") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .task { viewModel.link.start() }
    }
}
#endif

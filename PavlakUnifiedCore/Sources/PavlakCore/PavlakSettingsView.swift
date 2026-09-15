#if os(macOS) && canImport(SwiftUI)
import SwiftUI

public struct PavlakSettingsView: View {
    @State private var apiKey = ""
    @State private var connectionMessage = ""
    @State private var isConnecting = false
    @ObservedObject private var workspace = PavlakWorkspaceManager.shared
    private let connection = PavlakOpenAIConnectionService.shared

    public init() {}

    public var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("Chave da API", text: $apiKey)
                HStack {
                    Button("Conectar") { Task { await connect() } }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                    Button("Validar novamente") { Task { await validate() } }
                        .disabled(isConnecting)
                    Button("Remover", role: .destructive) { Task { await disconnect() } }
                        .disabled(isConnecting)
                }
                if isConnecting { ProgressView() }
                if !connectionMessage.isEmpty {
                    Text(connectionMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("Arquivos") {
                Text(workspace.selectedPath ?? "Nenhuma pasta autorizada.")
                    .font(.caption)
                    .textSelection(.enabled)
                HStack {
                    Button("Escolher pasta") { _ = workspace.chooseWorkspace() }
                    if workspace.selectedPath != nil {
                        Button("Remover acesso", role: .destructive) { workspace.clearWorkspace() }
                    }
                }
            }

            Text("Protótipo pessoal: a chave fica no Keychain deste Mac. Para distribuição pública, use autenticação por servidor e não exponha uma chave no aplicativo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 560)
        .task { await validateSilently() }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let result = try await connection.connect(apiKey: apiKey)
            apiKey = ""
            connectionMessage = result.message
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    private func validate() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            connectionMessage = try await connection.validateStoredKey().message
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    private func validateSilently() async {
        guard await connection.hasStoredKey() else { return }
        await validate()
    }

    private func disconnect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await connection.disconnect()
            connectionMessage = "Conexão removida deste Mac."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }
}
#endif

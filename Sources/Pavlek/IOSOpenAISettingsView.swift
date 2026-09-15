#if os(iOS)
import SwiftUI

struct IOSOpenAISettingsView: View {
    @ObservedObject private var executionMode = PavlakExecutionMode.shared
    @State private var provider: PavlakAIProvider
    @State private var modelID: String
    @State private var deploymentName: String
    @State private var realtimeDeploymentName: String
    @State private var baseURLText: String
    @State private var credential = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var cloudLimits: CloudLimits

    init() {
        let saved = PavlakAIConfigurationStore.load()
        _provider = State(initialValue: saved.provider)
        _modelID = State(initialValue: saved.modelID ?? PavlakAIConfiguration.currentModelID)
        _deploymentName = State(initialValue: saved.deploymentName ?? "")
        _realtimeDeploymentName = State(initialValue: saved.realtimeDeploymentName ?? "gpt-realtime-mini")
        _baseURLText = State(initialValue: saved.baseURL?.absoluteString ?? "")
        _cloudLimits = State(initialValue: CloudBudget.shared.limits)
    }

    private var editedConfiguration: PavlakAIConfiguration {
        PavlakAIConfiguration(
            provider: provider,
            modelID: provider == .openAI ? modelID : nil,
            deploymentName: provider == .azureOpenAI ? deploymentName : nil,
            baseURL: URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
            realtimeDeploymentName: provider == .azureOpenAI ? realtimeDeploymentName : nil
        )
    }

    var body: some View {
        Form {
            Section("Conversa") {
                Toggle("Usar provider remoto", isOn: Binding(get: { !executionMode.isLocalOnly }, set: { enabled in
                    executionMode.setLocalOnly(!enabled)
                    testTask?.cancel(); testing = false; message = nil
                    PavlakConnectorRegistry.shared.refresh()
                }))
                Text("Busca e OCR são locais. Ao perguntar, sua mensagem é enviada ao provider configurado. O texto de um documento só acompanha a pergunta após sua autorização na seleção.")
                    .font(.caption)
            }
            Section("Provider e modelo") {
                Picker("Provider", selection: $provider) {
                    ForEach(PavlakAIProvider.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .onChange(of: provider) { _, value in
                    if value == .openAI {
                        baseURLText = PavlakAIConfiguration.defaultOpenAIBaseURL.absoluteString
                    } else {
                        baseURLText = ""
                    }
                    Task {
                        let configuration = editedConfiguration
                        _ = await CloudCredentialStore.load(configuration: configuration)
                        hasKey = CloudCredentialStore.hasCredential(configuration: configuration)
                    }
                }
                if provider == .openAI {
                    Picker("Model ID", selection: $modelID) {
                        Text("Modelo atual (gpt-5)").tag(PavlakAIConfiguration.currentModelID)
                        Text("GPT-6 Astra").tag(PavlakAIConfiguration.astraModelID)
                    }
                    Text("Astra usa fallback automático para gpt-5 somente quando a API informar modelo indisponível.")
                        .font(.caption)
                } else {
                    TextField("Deployment name Azure", text: $deploymentName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Base URL Azure /openai/v1/", text: $baseURLText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Deployment Realtime Azure", text: $realtimeDeploymentName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use uma rota Azure compatível com inferência terminada em /openai/v1/. O deployment não é presumido.")
                        .font(.caption)
                }
                Button("Salvar configuração") {
                    do {
                        try PavlakAIConfigurationStore.save(editedConfiguration)
                        message = "Configuração salva. Nenhum segredo foi alterado."
                    } catch {
                        message = editedConfiguration.validationError() ?? PavlakAIConfigurationError.invalid.localizedDescription
                    }
                }.disabled(testing)
            }
            Section("Credencial neste iPhone") {
                Text(hasKey ? "Credencial salva separadamente no Chaveiro deste aparelho." : "Nenhuma credencial salva neste aparelho.")
                    .font(.caption)
                SecureField("Chave da API do provider", text: $credential)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pavlak.apiKey")
                Button(hasKey ? "Substituir credencial" : "Salvar credencial") {
                    do {
                        try CloudCredentialStore.save(credential, configuration: editedConfiguration)
                        credential = ""; hasKey = true
                        message = "Credencial salva. Use Testar conexão para verificar o acesso."
                        PavlakConnectorRegistry.shared.refresh()
                    } catch { message = "Não foi possível salvar a credencial no Chaveiro deste aparelho." }
                }.disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                if hasKey {
                    Button("Remover credencial", role: .destructive) {
                        testTask?.cancel(); testing = false
                        executionMode.setLocalOnly(true)
                        CloudCredentialStore.remove(configuration: editedConfiguration); hasKey = false; credential = ""; message = "Credencial removida; modo local ativo."
                        PavlakConnectorRegistry.shared.refresh()
                    }
                }
            }
            Section("Proteção de custo Azure") {
                TextField("Teto diário em US$", value: $cloudLimits.dailyUSD, format: .number.precision(.fractionLength(2)))
                TextField("Texto: US$/1M tokens", value: $cloudLimits.textUSDPerMillionTokens, format: .number.precision(.fractionLength(2)))
                TextField("Voz: US$/min", value: $cloudLimits.voiceUSDPerMinute, format: .number.precision(.fractionLength(2)))
                Button("Salvar proteção de custo") {
                    do { try CloudBudget.shared.save(cloudLimits); message = "Proteção local salva. O teto é \(String(format: "%.2f", cloudLimits.dailyUSD)) US$ por dia." }
                    catch { message = "O teto informado é inválido." }
                }
                Text("O Azure fica bloqueado enquanto o teto ou a estimativa de preço estiverem em zero.")
                    .font(.caption)
            }
            Section("Verificação") {
                Button("Testar conexão com texto fictício") {
                    testing = true; message = nil
                    let selectedConfiguration = editedConfiguration
                    testTask = Task {
                        do {
                            guard let saved = await CloudCredentialStore.load(configuration: selectedConfiguration) else { throw IOSChatError.missingCredential }
                            _ = try await IOSChatClient(configuration: selectedConfiguration, credential: { saved }).respond(messages: [.init(role: .user, text: "Teste de conexão do aplicativo. Responda apenas OK.")], selection: nil, allowsExcerpt: false)
                            try Task.checkCancellation()
                            if selectedConfiguration.provider == .openAI { try OpenAIKeyStore.markValidated(saved) }
                            PavlakConnectorRegistry.shared.refresh()
                            message = "O provider respondeu ao teste. Nenhum documento foi enviado."
                        } catch {
                            if !Task.isCancelled { message = (error as? IOSChatError ?? .network).localizedDescription }
                        }
                        testing = false
                    }
                }.disabled(!hasKey || executionMode.isLocalOnly || testing || editedConfiguration.validationError() != nil)
                Text("Esse teste usa somente texto fictício e está sujeito ao uso e cobrança da conta configurada.").font(.caption)
                if testing { ProgressView("Testando…") }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
        }
        .navigationTitle("IA")
        .task {
            let configuration = editedConfiguration
            _ = await CloudCredentialStore.load(configuration: configuration)
            hasKey = CloudCredentialStore.hasCredential(configuration: configuration)
        }
        .onDisappear { testTask?.cancel(); testing = false; credential = "" }
    }
}
#endif

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ConnectionsView: View {
    @ObservedObject var registry: PavlakConnectorRegistry
    @ObservedObject var executionMode: PavlakExecutionMode
    var authorizeFolders: (() -> Void)?
    var refreshFolders: (() -> Void)?
    var selectedConnectorID: String?
    @State private var openAIKey = ""
    @State private var openAIMessage: String?
    @State private var isValidatingOpenAI = false
    @State private var isReplacingOpenAICredential = false
    @State private var openAIValidationTask: Task<Void, Never>?
    @State private var aiProvider: PavlakAIProvider
    @State private var aiModelID: String
    @State private var azureDeploymentName: String
    @State private var azureRealtimeDeploymentName: String
    @State private var azureBaseURLText: String
    @State private var azureCredential = ""
    @State private var azureHasCredential = false
    @State private var azureMessage: String?
    @State private var cloudLimits: CloudLimits
    #if os(macOS)
    private let openAIValidator = OpenAICredentialValidator()
    #endif

    init(
        registry: PavlakConnectorRegistry,
        executionMode: PavlakExecutionMode? = nil,
        authorizeFolders: (() -> Void)? = nil,
        refreshFolders: (() -> Void)? = nil,
        selectedConnectorID: String? = nil
    ) {
        self.registry = registry
        self.executionMode = executionMode ?? PavlakExecutionMode.shared
        self.authorizeFolders = authorizeFolders
        self.refreshFolders = refreshFolders
        self.selectedConnectorID = selectedConnectorID
        let saved = PavlakAIConfigurationStore.load()
        _aiProvider = State(initialValue: saved.provider)
        _aiModelID = State(initialValue: saved.modelID ?? PavlakAIConfiguration.currentModelID)
        _azureDeploymentName = State(initialValue: saved.deploymentName ?? "")
        _azureRealtimeDeploymentName = State(initialValue: saved.realtimeDeploymentName ?? "gpt-realtime-mini")
        _azureBaseURLText = State(initialValue: saved.baseURL?.absoluteString ?? "")
        _cloudLimits = State(initialValue: CloudBudget.shared.limits)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(visibleConnectors) { connector in
                    connectorCard(connector)
                }
            }
            .padding(22)
        }
        .navigationTitle(selectedConnectorID == nil ? "Conexões" : (visibleConnectors.first?.name ?? "Conexão"))
        .task {
            #if os(macOS)
            await OpenAIKeyStore.loadFromKeychain()
            #endif
            let configuration = PavlakAIConfigurationStore.load()
            if configuration.provider == .azureOpenAI {
                _ = await CloudCredentialStore.load(configuration: configuration)
                azureHasCredential = CloudCredentialStore.hasCredential(configuration: configuration)
            } else {
                azureHasCredential = false
            }
            registry.refresh()
        }
        .onChange(of: executionMode.isLocalOnly) { _, isLocalOnly in
            if isLocalOnly {
                openAIValidationTask?.cancel()
                openAIValidationTask = nil
                isValidatingOpenAI = false
                openAIMessage = "Modo local ativado. Qualquer validação em andamento foi cancelada; a credencial salva foi preservada."
            }
        }
        .onDisappear {
            openAIValidationTask?.cancel()
            openAIValidationTask = nil
        }
    }

    private var visibleConnectors: [PavlakConnector] {
        guard let selectedConnectorID else { return registry.availableConnectors }
        return registry.availableConnectors.filter { $0.id == selectedConnectorID }
    }

    private func connectorCard(_ connector: PavlakConnector) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ConnectorIconView(connector: connector)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name).font(.headline)
                    Text((registry.availability[connector.id] ?? .unavailable).title)
                        .font(.caption).foregroundStyle(statusColor(connector.id))
                }
                Spacer()
            }

            Text(connector.capabilities.joined(separator: " • "))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(connector.limitations).font(.caption).foregroundStyle(.tertiary)

            if connector.permissions.contains(.photoLibrary) {
                permissionButton(connector.id, label: "Fotos") { Task { await registry.requestPhotos() } }
            } else if connector.permissions.contains(.notifications) {
                permissionButton(connector.id, label: "Notificações") { Task { await registry.requestNotifications() } }
            } else if connector.permissions.contains(.userSelectedFolders), let authorizeFolders {
                HStack {
                    Button("Escolher pasta", systemImage: "folder.badge.plus", action: authorizeFolders).buttonStyle(.bordered)
                    if registry.availability[connector.id] == .available, let refreshFolders {
                        Button("Atualizar índice", systemImage: "arrow.clockwise", action: refreshFolders).buttonStyle(.borderedProminent)
                    }
                }
            }
            #if os(macOS)
            if connector.id == "openai" { remoteAIControls }
            #elseif os(iOS)
            if connector.id == "openai" {
                NavigationLink("Configurar IA remota") { IOSOpenAISettingsView() }
            }
            #endif
            #if os(macOS)
            if connector.permissions.isEmpty,
               connector.actions.contains(where: { $0.hasSuffix(".open") }),
               registry.availability[connector.id] == .available {
                Button("Abrir aplicativo", systemImage: "arrow.up.forward.app") {
                    registry.openApplication(for: connector.id)
                }.buttonStyle(.bordered)
            }
            #endif
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
    }

    #if os(macOS)
    private var remoteAIControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider remoto", selection: $aiProvider) {
                ForEach(PavlakAIProvider.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .onChange(of: aiProvider) { _, value in
                if value == .openAI {
                    azureMessage = nil
                    azureHasCredential = false
                } else if azureBaseURLText.isEmpty {
                    azureMessage = "Informe o endpoint do recurso Azure antes de salvar."
                    azureHasCredential = false
                } else {
                    refreshAzureCredentialPresence()
                }
            }
            .onChange(of: azureBaseURLText) { _, _ in
                if aiProvider == .azureOpenAI { refreshAzureCredentialPresence() }
            }
            if aiProvider == .azureOpenAI {
                azureControls
            } else {
                openAIControls
            }
        }
    }

    private var azureControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Azure usa somente os deployments já existentes no recurso. O nome do deployment é literal; não há criação ou troca automática de modelo.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Deployment de texto (ex.: gpt-5-mini)", text: $azureDeploymentName)
                .textFieldStyle(.roundedBorder)
            TextField("Deployment Realtime (ex.: gpt-realtime-mini)", text: $azureRealtimeDeploymentName)
                .textFieldStyle(.roundedBorder)
            TextField("Endpoint base Azure terminando em /openai/v1/", text: $azureBaseURLText)
                .textFieldStyle(.roundedBorder)
            SecureField("Chave Azure deste recurso", text: $azureCredential)
                .textFieldStyle(.roundedBorder)
            if azureHasCredential {
                Label("Chave Azure salva separadamente no Chaveiro", systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Nenhuma chave Azure carregada para este endpoint", systemImage: "key.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Salvar configuração Azure", systemImage: "externaldrive") { saveAzureConfiguration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(azureDeploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || azureBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if azureHasCredential {
                    Button("Remover chave", role: .destructive) { removeAzureCredential() }
                        .buttonStyle(.borderless)
                }
            }
            cloudBudgetControls
            Text("Salvar não faz chamada de rede. O Azure continua sujeito às tarifas, cotas e ao saldo do portal; tarifa desconhecida não significa uso grátis.")
                .font(.caption).foregroundStyle(.secondary)
            if let azureMessage { Text(azureMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var cloudBudgetControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Controle de custo local").font(.caption.bold())
            Toggle("Aplicar teto local", isOn: $cloudLimits.localBudgetEnabled)
            if cloudLimits.localBudgetEnabled {
                HStack {
                    TextField("Teto diário em US$", text: Binding(
                        get: { String(format: "%.2f", cloudLimits.dailyUSD) },
                        set: { value in cloudLimits.dailyUSD = Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                    )).textFieldStyle(.roundedBorder)
                    TextField("Texto: US$/1M tokens", text: Binding(
                        get: { String(format: "%.2f", cloudLimits.textUSDPerMillionTokens) },
                        set: { value in cloudLimits.textUSDPerMillionTokens = Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                    )).textFieldStyle(.roundedBorder)
                    TextField("Voz: US$/min", text: Binding(
                        get: { String(format: "%.2f", cloudLimits.voiceUSDPerMinute) },
                        set: { value in cloudLimits.voiceUSDPerMinute = Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                    )).textFieldStyle(.roundedBorder)
                }
                Text("As estimativas são proteção local; confirme tarifas no portal Azure.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("Acompanhar no portal Azure — sem teto local", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption).foregroundStyle(.orange)
                Text("Texto e voz não serão bloqueados por tarifa não informada. Isso não significa uso grátis nem saldo infinito; cotas, tarifas e créditos Azure continuam valendo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("Salvar controle de custo", systemImage: "lock.shield") {
                do {
                    try CloudBudget.shared.save(cloudLimits)
                    azureMessage = cloudLimits.localBudgetEnabled
                        ? "Proteção salva. O teto atual é \(String(format: "%.2f", cloudLimits.dailyUSD)) US$ por dia."
                        : "Acompanhamento no portal salvo. O Pavlak não aplica teto local de dólares."
                }
                catch { azureMessage = "Não foi possível salvar o controle local." }
            }.buttonStyle(.bordered)
        }
    }

    private var editedAzureConfiguration: PavlakAIConfiguration {
        PavlakAIConfiguration(
            provider: .azureOpenAI, modelID: nil,
            deploymentName: azureDeploymentName,
            baseURL: URL(string: azureBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
            realtimeDeploymentName: azureRealtimeDeploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : azureRealtimeDeploymentName
        )
    }

    private func saveAzureConfiguration() {
        let configuration = editedAzureConfiguration
        do {
            try PavlakAIConfigurationStore.save(configuration)
            if !azureCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try CloudCredentialStore.save(azureCredential, configuration: configuration)
                azureCredential = ""
            }
            azureHasCredential = awaitAzureCredentialPresence(configuration)
            azureMessage = configuration.validationError() ?? "Configuração Azure salva. Nenhuma chamada foi feita."
            registry.refresh()
        } catch {
            azureMessage = configuration.validationError() ?? "Não foi possível salvar a configuração Azure."
        }
    }

    private func awaitAzureCredentialPresence(_ configuration: PavlakAIConfiguration) -> Bool {
        CloudCredentialStore.hasCredential(configuration: configuration)
    }

    private func refreshAzureCredentialPresence() {
        let configuration = editedAzureConfiguration
        guard configuration.validationError() == nil else {
            azureHasCredential = false
            return
        }
        Task {
            _ = await CloudCredentialStore.load(configuration: configuration)
            azureHasCredential = CloudCredentialStore.hasCredential(configuration: configuration)
        }
    }

    private func removeAzureCredential() {
        let configuration = editedAzureConfiguration
        CloudCredentialStore.remove(configuration: configuration)
        azureHasCredential = false
        azureMessage = "Chave Azure removida do Chaveiro; o Modo remoto continua desativado."
        registry.refresh()
    }

    private var openAIControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if executionMode.isLocalOnly {
                Label("Modo local ativo — chamadas à API bloqueadas", systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.green)
                Text(OpenAIKeyStore.hasKey
                     ? "A credencial permanece salva e não será usada. Desative o Modo local na tela principal para validar ou usar a OpenAI."
                     : "Desative o Modo local na tela principal antes de configurar ou validar uma credencial.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if OpenAIKeyStore.hasValidatedKey && !isReplacingOpenAICredential {
                HStack {
                    Label("Credencial principal validada", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Validar novamente", action: validateStoredOpenAICredential).buttonStyle(.borderless)
                    Button("Substituir") { isReplacingOpenAICredential = true; openAIMessage = nil }.buttonStyle(.borderless)
                }.font(.caption)
            } else if OpenAIKeyStore.hasKey && !isReplacingOpenAICredential {
                Label("Credencial salva no Chaveiro; validação necessária", systemImage: "key.fill").font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Validar novamente", action: validateStoredOpenAICredential).buttonStyle(.borderedProminent)
                    Button("Substituir") { isReplacingOpenAICredential = true; openAIMessage = nil }.buttonStyle(.bordered)
                    Button("Remover") { OpenAIKeyStore.remove(); registry.refresh(); openAIMessage = nil }.buttonStyle(.borderless)
                }
            } else {
                SecureField("Credencial da Service Account OpenAI", text: $openAIKey).textFieldStyle(.roundedBorder)
                Button("Conectar OpenAI", systemImage: "key") {
                    saveAndValidateOpenAICredential()
                }.buttonStyle(.borderedProminent).disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingOpenAI)
            }
            if isValidatingOpenAI { ProgressView("Validando com a OpenAI…").controlSize(.small) }
            if let openAIMessage { Text(openAIMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func saveAndValidateOpenAICredential() {
        let credential = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidatingOpenAI = true; openAIMessage = nil
        openAIValidationTask?.cancel()
        openAIValidationTask = Task {
            do {
                try OpenAIKeyStore.save(credential)
                let validation = try await openAIValidator.validate(credential)
                try Task.checkCancellation()
                try OpenAIKeyStore.markValidated(credential)
                openAIKey = ""; isReplacingOpenAICredential = false
                openAIMessage = safeRequestDiagnostic(validation.diagnosticMessage)
            } catch is CancellationError {
                openAIMessage = executionMode.isLocalOnly
                    ? "Modo local ativo. A validação foi cancelada e a credencial salva foi preservada."
                    : "Validação cancelada. A credencial salva foi preservada."
            } catch is OpenAIUsagePolicyError {
                openAIMessage = OpenAIUsagePolicy.localOnlyMessage
            } catch {
                openAIKey = ""
                openAIMessage = safeRequestDiagnostic((error as? OpenAIAPIError)?.diagnosticMessage ?? "Não foi possível confirmar a conexão com a OpenAI.")
                PavlakErrorReporter.shared.report(module: "OpenAIConnection", action: "validar_credencial", message: "A credencial foi salva, mas a autenticação não foi confirmada.", error: error, result: "credencial_nao_validada")
            }
            isValidatingOpenAI = false; registry.refresh()
            openAIValidationTask = nil
        }
    }

    private func validateStoredOpenAICredential() {
        guard let credential = OpenAIKeyStore.load() else { return }
        OpenAIKeyStore.markUnvalidated()
        registry.refresh()
        isValidatingOpenAI = true; openAIMessage = nil
        openAIValidationTask?.cancel()
        openAIValidationTask = Task {
            do {
                let validation = try await openAIValidator.validate(credential)
                try Task.checkCancellation()
                try OpenAIKeyStore.markValidated(credential)
                openAIMessage = safeRequestDiagnostic(validation.diagnosticMessage)
            } catch is CancellationError {
                openAIMessage = executionMode.isLocalOnly
                    ? "Modo local ativo. A revalidação foi cancelada e a credencial salva foi preservada."
                    : "Revalidação cancelada. A credencial salva foi preservada."
            } catch is OpenAIUsagePolicyError {
                openAIMessage = OpenAIUsagePolicy.localOnlyMessage
            } catch {
                openAIMessage = safeRequestDiagnostic((error as? OpenAIAPIError)?.diagnosticMessage ?? "Não foi possível confirmar a conexão com a OpenAI.")
                PavlakErrorReporter.shared.report(module: "OpenAIConnection", action: "revalidar_credencial", message: "A OpenAI recusou ou não confirmou a credencial salva.", error: error, result: "credencial_nao_validada")
            }
            isValidatingOpenAI = false; registry.refresh()
            openAIValidationTask = nil
        }
    }

    private func safeRequestDiagnostic(_ result: String) -> String {
        guard let diagnostic = OpenAIRequestFactory.lastDiagnostics else { return result }
        return diagnostic.safeDescription + "\n" + result
    }
    #endif

    @ViewBuilder private func permissionButton(_ connectorID: String, label: String, action: @escaping () -> Void) -> some View {
        let status = registry.availability[connectorID] ?? .unavailable
        switch status {
        case .permissionRequired:
            Button("Autorizar \(label)", systemImage: "hand.raised", action: action).buttonStyle(.borderedProminent)
        case .permissionDenied:
            Button("Abrir Ajustes", systemImage: "gear", action: openSettings).buttonStyle(.bordered)
        case .available, .unavailable:
            EmptyView()
        }
    }

    private func statusColor(_ connectorID: String) -> Color {
        switch registry.availability[connectorID] ?? .unavailable {
        case .available: .green
        case .permissionRequired: .orange
        case .permissionDenied, .unavailable: .secondary
        }
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        #endif
    }
}

struct ConnectorIconView: View {
    let connector: PavlakConnector

    var body: some View {
        Group {
            #if os(macOS)
            if let icon = applicationIcon {
                Image(nsImage: icon).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: connector.icon).font(.title2).foregroundStyle(.tint)
            }
            #else
            Image(systemName: connector.icon).font(.title2).foregroundStyle(.tint)
            #endif
        }
        .frame(width: 42, height: 42)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }

    #if os(macOS)
    private var applicationIcon: NSImage? {
        guard let url = PavlakConnectorRegistry.shared.applicationURL(for: connector.id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 36, height: 36)
        return icon
    }
    #endif
}

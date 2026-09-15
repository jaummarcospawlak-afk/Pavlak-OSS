#if os(macOS)
import SwiftUI

struct PavlakHubSearchBar: View {
    @ObservedObject var workspace: PavlakWorkspaceState
    let submit: () -> Void
    let startVoiceSearch: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.blue)
            TextField("Buscar no perfil, conversas ou estudos", text: $workspace.command)
                .textFieldStyle(.plain)
                .onSubmit(submit)
            Button(action: startVoiceSearch) {
                Image(systemName: workspace.speech.state.isCapturingOrRequesting ? "stop.fill" : "mic.fill")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help(workspace.speech.state.isCapturingOrRequesting ? "Parar e executar a busca ditada" : "Ditar busca local")
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.caption.bold()).frame(width: 26, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .help("Buscar")
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Busca única do Pavlak")
    }
}

struct PavlakProfileView: View {
    @ObservedObject var workspace: PavlakWorkspaceState
    @AppStorage(PavlakProfileStore.displayNameKey) private var displayName = ""
    @AppStorage(PavlakProfileStore.preferenceKey) private var preference = ""
    @State private var authorizedFolderCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Perfil", systemImage: "person.crop.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                Text("Preferências locais do Pavlak. Nada aqui exibe chaves, tokens ou identificadores de credencial.")
                    .foregroundStyle(.secondary)

                GroupBox("Identidade local") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Nome para exibição", text: $displayName)
                        Text("Salvo somente neste Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Preferência de resposta") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Ex.: respostas concisas em português", text: $preference)
                        Text("Esta preferência é apenas uma anotação local; ela não altera a credencial nem a conta Azure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Fontes disponíveis") {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("\(authorizedFolderCount) pasta(s) autorizada(s) para busca", systemImage: "folder")
                        Label("Fotos: somente quando o acesso já estiver autorizado", systemImage: "photo.on.rectangle")
                        Label("Provider remoto: \(PavlakAIConfigurationStore.load().provider.displayName)", systemImage: workspace.executionMode.isLocalOnly ? "lock.shield" : "network")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("O Perfil não importa dados do ChatGPT, GitHub Copilot ou de outras contas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task {
            let snapshot = await workspace.documentSearch.index.authorizedSnapshot()
            authorizedFolderCount = snapshot.coveredDirectoryCount
        }
    }
}

struct PavlakConversationsView: View {
    @ObservedObject var workspace: PavlakWorkspaceState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Conversas", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 26, weight: .bold))
                    Spacer()
                    Button("Nova conversa", systemImage: "plus") {
                        workspace.startNewConversation()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Histórico local do próprio Pavlak. Conversas de ChatGPT e Copilot não são importadas.")
                    .foregroundStyle(.secondary)

                if workspace.conversations.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma conversa salva",
                        systemImage: "bubble.left",
                        description: Text("Quando você usar o chat do Pavlak, o histórico aparecerá aqui.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(workspace.conversations) { conversation in
                            let messageLabel = "\(conversation.messages.count) mensagem\(conversation.messages.count == 1 ? "" : "ns") • \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                            Button {
                                workspace.restoreConversation(conversation)
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: conversation.id == workspace.currentConversationID ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                                        .font(.title2)
                                        .foregroundStyle(conversation.id == workspace.currentConversationID ? .blue : .secondary)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(conversation.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                        Text(messageLabel)
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let preview = conversation.messages.last?.text, !preview.isEmpty {
                                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(15)
                                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Reabre somente o histórico local desta conversa")
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 800, alignment: .leading)
        }
    }
}

struct PavlakStudiesView: View {
    @ObservedObject var workspace: PavlakWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Estudos", systemImage: "book.closed.fill")
                    .font(.system(size: 26, weight: .bold))
                Text("Materiais reais encontrados somente nas pastas e Fotos já autorizadas.")
                    .foregroundStyle(.secondary)
                PavlakHubSearchBar(workspace: workspace, submit: workspace.searchStudies, startVoiceSearch: workspace.startStudiesVoiceSearch)
                if workspace.speech.state != .idle {
                    Label(workspace.speech.state.statusMessage, systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)

            Divider()
            PavlakStudyResultsContent(workspace: workspace)
        }
    }
}

struct PavlakHubSearchView: View {
    @ObservedObject var workspace: PavlakWorkspaceState
    let openConversations: () -> Void
    let openStudies: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Busca do Pavlak", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 26, weight: .bold))
                Text("Uma busca local reúne perfil, conversas e estudos autorizados.")
                    .foregroundStyle(.secondary)
                PavlakHubSearchBar(workspace: workspace, submit: workspace.submitHubSearch, startVoiceSearch: workspace.startHubVoiceSearch)
            }
            .padding(28)
            Divider()

            switch workspace.hubSearchState {
            case .idle:
                ContentUnavailableView("Digite o que procura", systemImage: "magnifyingglass", description: Text("A busca não sai das fontes locais autorizadas."))
            case .searching:
                ProgressView("Consultando o Pavlak localmente…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .completed:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !workspace.hubProfileMatches.isEmpty {
                            sectionHeader("Perfil", icon: "person.crop.circle")
                            ForEach(workspace.hubProfileMatches) { match in
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(match.label).font(.headline)
                                        Text(match.value.isEmpty ? "Ainda não preenchido" : match.value).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "person.crop.circle").foregroundStyle(.blue)
                                }
                                .padding(12)
                            }
                        }

                        if !workspace.hubConversationMatches.isEmpty {
                            sectionHeader("Conversas", icon: "bubble.left.and.bubble.right")
                            ForEach(workspace.hubConversationMatches) { conversation in
                                let messageLabel = "\(conversation.messages.count) mensagem\(conversation.messages.count == 1 ? "" : "ns") • \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                                Button {
                                    workspace.restoreConversation(conversation)
                                    openConversations()
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.title).font(.headline).foregroundStyle(.primary)
                                            Text(messageLabel)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(14)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if workspace.unifiedSearch.report != nil {
                            sectionHeader("Estudos", icon: "book.closed")
                            PavlakStudyResultsContent(workspace: workspace, compact: true)
                        }

                        if workspace.hubProfileMatches.isEmpty,
                           workspace.hubConversationMatches.isEmpty,
                           workspace.unifiedSearch.report?.results.isEmpty != false {
                            ContentUnavailableView(
                                "Nenhum resultado no Pavlak",
                                systemImage: "magnifyingglass",
                                description: Text("A consulta foi limitada ao perfil local, ao histórico do Pavlak e às fontes autorizadas.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }

                        if workspace.unifiedSearch.report != nil {
                            Button("Abrir Estudos", systemImage: "book.closed") { openStudies() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(.secondary)
    }
}

struct PavlakStudyResultsContent: View {
    @ObservedObject var workspace: PavlakWorkspaceState
    var compact = false

    var body: some View {
        Group {
            switch workspace.unifiedSearch.state {
            case .idle:
                ContentUnavailableView("Nenhuma busca realizada", systemImage: "book.closed", description: Text("Digite uma consulta sobre seus materiais."))
            case .searching:
                ProgressView("Pesquisando arquivos e Fotos autorizados…")
            case .completed:
                if let report = workspace.unifiedSearch.report {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if !compact {
                                Text(report.results.isEmpty ? "Busca de estudos concluída" : "\(report.results.count) material(is) encontrado(s)")
                                    .font(.headline)
                                ForEach([LocalUnifiedSearchSource.authorizedFiles, .authorizedPhotos], id: \.rawValue) { source in
                                    if let status = report.sourceStatuses[source] {
                                        Label("\(source.title): \(status.detail)", systemImage: status.wasConsulted ? "checkmark.circle" : "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(status.wasConsulted ? Color.secondary : Color.orange)
                                    }
                                }
                                if let detail = report.spotlightDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            if report.results.isEmpty {
                                ContentUnavailableView("Nenhum material correspondente", systemImage: "book.closed", description: Text("Não há candidato suficiente nas fontes consultadas."))
                                    .frame(maxWidth: .infinity, minHeight: compact ? 100 : 180)
                            } else {
                                ForEach(report.results) { result in
                                    studyRow(result, report: report)
                                }
                            }
                        }
                        .padding(compact ? 0 : 28)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func studyRow(_ result: LocalUnifiedSearchResult, report: LocalUnifiedSearchReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await workspace.selectUnifiedResult(result) } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: result.source == .authorizedPhotos ? "photo" : "doc.text")
                        .font(.title2).foregroundStyle(.blue).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.headline).foregroundStyle(.primary)
                        Text("\(result.source.title) • \(workspace.unifiedSearch.location(for: result))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Confiança \(result.confidence.rawValue) • \(result.reason)")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Button("Selecionar") { Task { await workspace.selectUnifiedResult(result) } }
                Button("Abrir", systemImage: "arrow.up.forward.app") {
                    Task {
                        await workspace.selectUnifiedResult(result)
                        await workspace.unifiedSearch.perform(.open, on: result)
                    }
                }
                if result.source == .authorizedFiles {
                    Button("Finder", systemImage: "folder") {
                        Task {
                            await workspace.selectUnifiedResult(result)
                            await workspace.unifiedSearch.perform(.reveal, on: result)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            Text("Origem visível • selecionar não abre nem altera o material")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
    }
}
#endif

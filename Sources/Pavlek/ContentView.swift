import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
struct ContentView: View {
    private enum Destination: Hashable {
        case pavlak
        case profile
        case conversations
        case studies
        case hubSearch
        case iOS
        case macOS
        case connector(String)
    }
    @StateObject private var workspace = PavlakWorkspaceState()
    @StateObject private var executionMode = PavlakExecutionMode.shared
    @StateObject private var registry = PavlakConnectorRegistry.shared
    @StateObject private var errorReporter = PavlakErrorReporter.shared
    @StateObject private var transferInbox = PavlakTransferInbox.shared
    @StateObject private var fileRecovery = FileRecoveryViewModel()
    @StateObject private var azureVoice = AzureRealtimeVoiceService()
    @State private var destination: Destination? = .pavlak
    @State private var showingAttachmentPicker = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                NavigationLink(value: Destination.pavlak) {
                    HStack(spacing: 12) {
                        Image(systemName: "p.circle.fill").font(.title).foregroundStyle(.blue)
                        Text("Pavlak").font(.title2.bold())
                    }.padding(.vertical, 8)
                }
                Section("Espaço Pavlak") {
                    NavigationLink(value: Destination.profile) {
                        Label("Perfil", systemImage: "person.crop.circle")
                    }
                    NavigationLink(value: Destination.conversations) {
                        HStack {
                            Label("Conversas", systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            if !workspace.conversations.isEmpty {
                                Text("\(workspace.conversations.count)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink(value: Destination.studies) {
                        Label("Estudos", systemImage: "book.closed")
                    }
                    NavigationLink(value: Destination.hubSearch) {
                        Label("Busca única", systemImage: "sparkle.magnifyingglass")
                    }
                    PavlakHubSearchBar(
                        workspace: workspace,
                        submit: {
                            destination = .hubSearch
                            workspace.submitHubSearch()
                        },
                        startVoiceSearch: {
                            destination = .hubSearch
                            workspace.startHubVoiceSearch()
                        }
                    )
                    .padding(.vertical, 5)
                }
                Section("Plataformas") {
                    NavigationLink(value: Destination.iOS) {
                        Label("iOS", systemImage: "iphone")
                    }
                    NavigationLink(value: Destination.macOS) {
                        Label("macOS", systemImage: "desktopcomputer")
                    }
                }
                Section("Conexões") {
                    ForEach(sidebarConnectors) { connector in
                        NavigationLink(value: Destination.connector(connector.id)) {
                            HStack(spacing: 9) {
                                ConnectorIconView(connector: connector).frame(width: 25, height: 25)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connector.name).lineLimit(1)
                                    Text(registry.availability[connector.id]?.title ?? "Verificando…").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 2)
                                Circle().fill(connectionColor(connector.id)).frame(width: 7, height: 7)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .frame(minWidth: 220, idealWidth: 245)
        } detail: {
            HSplitView {
                Group {
                    switch destination ?? .pavlak {
                    case .pavlak: conversationArea
                    case .profile: PavlakProfileView(workspace: workspace)
                    case .conversations: PavlakConversationsView(workspace: workspace)
                    case .studies: PavlakStudiesView(workspace: workspace)
                    case .hubSearch: PavlakHubSearchView(
                        workspace: workspace,
                        openConversations: { destination = .conversations },
                        openStudies: { destination = .studies }
                    )
                    case .iOS: PavlekDevicesView()
                    case .macOS: ConnectionsView(
                        registry: registry,
                        executionMode: executionMode,
                        authorizeFolders: authorizeFolder,
                        refreshFolders: refreshFolders
                    )
                    case .connector(let id): ConnectionsView(
                        registry: registry,
                        executionMode: executionMode,
                        authorizeFolders: authorizeFolder,
                        refreshFolders: refreshFolders,
                        selectedConnectorID: id
                    )
                    }
                }.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                activePanel.frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            errorReporter.initialize(); commandFocused = true
            PavlakLinkService.shared.commandHandler = { message in
                if message.action == .stageTransfer { return transferInbox.receive(message) }
                if message.action == .fileSearch { return await fileRecovery.handleLink(message) }
                return message.response(status: .failure, result: "Ação remota ainda não disponível.")
            }
            Task { await search.index.reload(); registry.noteAuthorizedFolders(!search.index.snapshot.roots.isEmpty) }
            Task { await PavlakMCPStatusStore.shared.publish(mcpStatusSnapshot) }
        }
        .task(id: mcpFingerprint) { await PavlakMCPStatusStore.shared.publish(mcpStatusSnapshot) }
        .onDisappear { search.releasePreviewAccess() }
        .alert("Confirmar agendamento", isPresented: Binding(
            get: { workspace.pendingDocumentSchedule != nil },
            set: { if !$0, workspace.pendingDocumentSchedule != nil { workspace.cancelDocumentSchedule() } }
        ), presenting: workspace.pendingDocumentSchedule) { _ in
            Button("Cancelar", role: .cancel, action: workspace.cancelDocumentSchedule)
            Button("Agendar notificação", action: workspace.confirmDocumentSchedule)
        } message: { request in
            Text("Arquivo: \(request.fileName)\nData e hora: \(request.scheduledAt.formatted(date: .long, time: .shortened))\n\nO arquivo não será aberto sozinho. A notificação exigirá sua interação.")
        }
        .fileImporter(isPresented: $showingAttachmentPicker, allowedContentTypes: [.pdf, .plainText, .rtf, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.addAttachments(urls) }
        }
    }

    private var conversationArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: search.goBack) { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(!search.canGoBack)
                Button(action: search.goForward) { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(!search.canGoForward)
                Spacer()
            }.padding(.horizontal, 26).padding(.top, 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("Olá, Pavlak! 👋").font(.system(size: 26, weight: .bold))
                Text("O que você precisa encontrar ou fazer hoje?").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.top, 18)
            commandBar
            if !workspace.isUnifiedSearchMode && (!search.activeContracts.isEmpty || !agent.activeContext.isEmpty) { contextBar }
            mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var mainContent: some View {
        if workspace.isUnifiedSearchMode { unifiedSearchContent }
        else if !agent.messages.isEmpty || agent.isRunning { agentContent }
        else if workspace.isPhotoMode { photoContent }
        else {
            switch search.state {
            case .idle:
                ContentUnavailableView("O que você quer encontrar?", systemImage: "sparkle.magnifyingglass", description: Text("Pesquise nas conexões autorizadas ou anexe documentos para comparar."))
            case .searching: ProgressView("Procurando nas áreas autorizadas…")
            case .results: fileResults
            case .selected:
                VStack(spacing: 0) {
                    if let response = search.assistantResponse { UniversalTextResultView(title: "Pavlak", message: response, kind: .text).padding(16) }
                    if let url = search.previewURL { DocumentPreviewView(url: url, presentation: search.presentation) }
                }
            case .orchestrating:
                ScrollView { VStack(alignment: .leading, spacing: 14) {
                    if search.isProcessingDocument { ProgressView("Lendo os documentos necessários…") }
                    if let response = search.assistantResponse { UniversalTextResultView(title: "Pavlak", message: response, kind: .text) }
                    else if !search.orchestrator.response.isEmpty { UniversalTextResultView(title: "Pavlak", message: search.orchestrator.response, kind: .text) }
                    else { ProgressView("Interpretando a solicitação…") }
                    ForEach(search.orchestrator.activeDocuments) { document in
                        resultCard(document.name, "\(document.type) • \(document.location)", "doc.text") {
                            if let candidate = document.candidate { Task { await workspace.activateFile(candidate) } }
                            else { Task { await search.orchestrator.openDocument(document) } }
                        }
                    }
                }.padding(24).frame(maxWidth: 760, alignment: .leading) }
            case .entity:
                if let entity = search.resultEntity { ActionableResultView(entity: entity) { if $0 == .open { search.openResultEntity() } }.padding(24) }
            case .failed(let message): ContentUnavailableView("Não foi possível concluir", systemImage: "exclamationmark.magnifyingglass", description: Text(message))
            }
        }
    }

    @ViewBuilder private var unifiedSearchContent: some View {
        switch workspace.unifiedSearch.state {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView("Pesquisando arquivos e fotos autorizados…")
        case .completed:
            if let report = workspace.unifiedSearch.report {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text(report.results.isEmpty ? "Busca local concluída" : "Encontrei \(report.results.count) arquivo(s) que podem corresponder ao seu pedido.")
                            .font(.headline)
                        Text(report.canReportTotalAbsence
                             ? "Nenhum candidato foi identificado nas fontes consultadas."
                             : report.results.isEmpty
                                ? "Nenhum candidato no índice disponível. Uma ou mais fontes não puderam ser consultadas por completo."
                                : "Poucos resultados, ordenados por relevância. Cada item explica a correspondência; selecionar não abre nem altera o arquivo.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        ForEach([LocalUnifiedSearchSource.authorizedFiles, .authorizedPhotos], id: \.rawValue) { source in
                            if let status = report.sourceStatuses[source] {
                                Label("\(source.title): \(status.detail)", systemImage: status.wasConsulted ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(status.wasConsulted ? Color.secondary : Color.orange)
                            }
                        }

                        if let detail = report.spotlightDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        Button("Escolher pasta para leitura", systemImage: "folder.badge.plus", action: authorizeFolder)
                        if let error = search.index.errorMessage { Text(error).foregroundStyle(.orange) }
                        if search.index.isIndexing { ProgressView("Indexando arquivos…") }
                        if let error = workspace.unifiedSearch.actionError { Text(error).foregroundStyle(.orange) }
                        if report.query.dateContext != nil {
                            Text("A data é de modificação do arquivo ou criação da foto; confira no documento a data do evento.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(report.results) { result in
                            Button { Task { await workspace.selectUnifiedResult(result) } } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.title2).foregroundStyle(.tint).frame(width: 36)
                                    VStack(alignment: .leading, spacing: 6) {
                                        if result.id == report.results.first?.id {
                                            Label("Melhor correspondência", systemImage: "star.fill").font(.caption).foregroundStyle(.blue)
                                        }
                                        Text(result.title).font(.headline).foregroundStyle(.primary)
                                        Text(result.source.title + (result.date.map { " • \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text("\((result.title as NSString).pathExtension.uppercased()) • \(workspace.unifiedSearch.location(for: result))").font(.caption).foregroundStyle(.secondary)
                                        Text("Confiança \(result.confidence.rawValue) • pontuação \(result.score.total)")
                                            .font(.caption.bold()).foregroundStyle(result.confidence == .high ? Color.green : Color.orange)
                                        Text(result.reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                        Text("Exata \(result.score.exactPhrase) • nome \(result.score.name) • texto \(result.score.contentOrOCR) • metadados \(result.score.metadata)")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                        Label("Somente leitura • abertura exige confirmação", systemImage: "lock.shield")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(15)
                                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Seleciona o candidato sem abrir; use Abrir no painel lateral para confirmar a abertura")
                            HStack {
                                Button("Abrir", systemImage: "doc") { Task { await workspace.unifiedSearch.perform(.open, on: result) } }
                                if result.source == .authorizedFiles { Button("Revelar no Finder", systemImage: "folder") { Task { await workspace.unifiedSearch.perform(.reveal, on: result) } } }
                            }

                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
    }

    private var agentContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(agent.messages) { message in
                        HStack {
                            if message.role == .user { Spacer(minLength: 80) }
                            Text(message.text.isEmpty ? " " : message.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            if message.role == .assistant { Spacer(minLength: 80) }
                        }.id(message.id)
                    }
                    if let label = agent.state.label {
                        HStack(spacing: 8) {
                            if agent.isRunning { ProgressView().controlSize(.small) }
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }.id("agent-status")
                    }
                    ForEach(agent.photos.results) { result in
                        Button { Task { await workspace.selectPhoto(result) } } label: {
                            HStack(spacing: 14) {
                                Group { if let image = agent.photos.thumbnails[result.id] { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.12) } }
                                    .frame(width: 76, height: 58).clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.filename ?? "Foto").font(.headline).foregroundStyle(.primary)
                                    Text("Foto • \(result.albumTitle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: agent.photos.selected?.id == result.id ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(.tint)
                            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                    ForEach(agent.fileResults) { candidate in
                        resultCard(candidate.file.name, "\(candidate.file.fileExtension.uppercased()) • \(candidate.file.relativePath)", "doc.text") {
                            Task { await workspace.activateFile(candidate) }
                        }
                    }
                }.padding(24).frame(maxWidth: 760, alignment: .leading)
            }
            .onChange(of: agent.messages) { _, messages in
                if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private var fileResults: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
            Text("Melhores resultados").font(.headline)
            ForEach(workspace.results.filter { $0.kind == .file }) { result in
                resultCard(result.title, result.subtitle, result.title.lowercased().hasSuffix(".pdf") ? "doc.richtext.fill" : "doc.text.fill") {
                    guard let candidate = workspace.fileCandidate(id: result.id) else { return }
                    Task { await workspace.activateFile(candidate) }
                }
            }
        }.padding(24).frame(maxWidth: 760, alignment: .leading) }
    }

    @ViewBuilder private var photoContent: some View {
        switch photos.state {
        case .idle: EmptyView()
        case .searching: ProgressView("Consultando o álbum \(photos.searchedAlbumName)…")
        case .failed(let message): ContentUnavailableView("Fotos", systemImage: "photo.badge.exclamationmark", description: Text(message))
        case .results:
            if photos.results.isEmpty { ContentUnavailableView("Nenhuma foto encontrada", systemImage: "photo.on.rectangle", description: Text("A pesquisa foi limitada ao álbum \(photos.searchedAlbumName).")) }
            else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Resultados no álbum \(photos.searchedAlbumName)").font(.headline)
                    ForEach(photos.results) { result in
                        Button { Task { await workspace.selectPhoto(result) } } label: {
                            HStack(spacing: 14) {
                                Group { if let image = photos.thumbnails[result.id] { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.12) } }
                                    .frame(width: 76, height: 58).clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.filename ?? "Foto").font(.headline).foregroundStyle(.primary)
                                    Text("Foto • \(result.albumTitle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: photos.selected?.id == result.id ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(.tint)
                            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }.padding(24).frame(maxWidth: 760, alignment: .leading) }
            }
        }
    }

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Objeto ativo").font(.headline)
                Spacer()
                if workspace.activeSelection != .none {
                    Button { workspace.clearActiveSelection() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Limpar objeto ativo")
                }
            }.padding(20)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                if !transferInbox.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Bandeja temporária", systemImage: "tray.full.fill").font(.headline)
                        Text("Itens recebidos do iPhone. Nada foi salvo em uma pasta final.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(transferInbox.items) { item in
                            HStack {
                                Image(systemName: item.contentType.hasPrefix("image/") ? "photo" : "doc")
                                VStack(alignment: .leading) {
                                    Text(item.filename).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { transferInbox.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain).help("Remover da bandeja")
                            }
                        }
                    }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                }
                switch workspace.activeSelection {
                case .file:
                    if let item = search.selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: item.file.fileExtension == "pdf" ? "doc.richtext.fill" : "doc.text.fill").font(.system(size: 42)).foregroundStyle(.blue)
                            Text(item.file.name).font(.title3.bold())
                            Text("\(item.file.fileExtension.uppercased()) • \(item.file.relativePath)").font(.caption).foregroundStyle(.secondary)
                            Label("Origem: Arquivos / Finder", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            if search.previewURL == nil {
                                Label("Selecionado sem abrir", systemImage: "lock.shield")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
                        operationsGrid(
                            open: { Task { await search.open(item) } },
                            summarize: search.summarizeCurrent,
                            compareEnabled: search.activeContracts.count >= 2,
                            compare: { search.runOnActiveContracts("Compare os documentos selecionados.") },
                            share: search.shareCurrent,
                            shareEnabled: search.previewURL != nil
                        )
                        contextSection
                    } else { emptyActive }
                case .photo:
                    if let item = photos.selected {
                        VStack(alignment: .leading, spacing: 12) {
                            if let image = photos.selectedImage ?? photos.thumbnails[item.id] { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12)) }
                            Text(item.filename ?? "Foto").font(.title3.bold())
                            Text("Foto • Álbum \(item.albumTitle)").font(.caption).foregroundStyle(.secondary)
                            Label("Origem: Fotos", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
                        operationsGrid(
                            open: { Task { await photos.open(item) } }, summarize: {}, summarizeEnabled: false,
                            compareEnabled: false, compare: {},
                            share: { photos.shareSelected(from: NSApp.keyWindow?.contentView) }
                        )
                        contextSection
                    } else { emptyActive }
                case .none:
                    emptyActive
                    operationsGrid(open: {}, openEnabled: false, summarize: {}, summarizeEnabled: false, compareEnabled: false, compare: {}, share: {}, shareEnabled: false)
                    contextSection
                }
            }.padding(20) }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }

    private var emptyActive: some View { ContentUnavailableView("Nenhum objeto selecionado", systemImage: "square.dashed", description: Text("Selecione um resultado para mantê-lo disponível aqui.")) }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !workspace.attachments.isEmpty { ScrollView(.horizontal, showsIndicators: false) { HStack {
                ForEach(workspace.attachments, id: \.self) { url in
                    HStack(spacing: 6) { Image(systemName: "doc.fill"); Text(url.lastPathComponent).lineLimit(1); Button { workspace.removeAttachment(url) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                        .font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule())
                }
            } } }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.blue)
                TextField("Pergunte ou peça algo ao Pavlak", text: $workspace.command).textFieldStyle(.plain).font(.system(size: 16)).focused($commandFocused).onSubmit(submitCommand)
                Button { showingAttachmentPicker = true } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.buttonStyle(.borderless).help("Anexar documentos")
                Button(action: workspace.toggleSpeechTranscription) {
                    Image(systemName: speech.state.isCapturingOrRequesting ? "stop.fill" : "mic.fill")
                        .foregroundStyle(speech.state == .listening ? Color.red : Color.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(speech.state.isCapturingOrRequesting ? "Parar transcrição" : "Iniciar transcrição por voz")
                if azureVoiceIsConfigured {
                    Button(action: toggleAzureVoice) {
                        Image(systemName: azureVoice.state.isActive ? "waveform.circle.fill" : "waveform.circle")
                            .foregroundStyle(azureVoice.state.isActive ? Color.accentColor : Color.primary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .disabled(executionMode.isLocalOnly)
                    .help(azureVoice.state.isActive ? "Parar e enviar voz ao Azure" : "Iniciar voz Azure")
                }
                Button(action: submitCommand) { Image(systemName: "arrow.up").font(.headline).frame(width: 30, height: 30) }.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 1.6))
            if speech.state != .idle || !speech.transcript.isEmpty {
                Label(speech.state.statusMessage, systemImage: speechStatusIcon)
                    .font(.caption)
                    .foregroundStyle(speechStatusColor)
                    .accessibilityLabel(speech.state.statusMessage)
            }
            if azureVoice.state != .idle || !azureVoice.assistantText.isEmpty || !azureVoice.inputTranscript.isEmpty {
                Label(azureVoice.state.message, systemImage: azureVoice.state.isActive ? "waveform" : "waveform.circle")
                    .font(.caption)
                    .foregroundStyle(azureVoiceStateColor)
                if !azureVoice.inputTranscript.isEmpty {
                    Text("Você: \(azureVoice.inputTranscript)").font(.caption).foregroundStyle(.secondary)
                }
                if !azureVoice.assistantText.isEmpty {
                    Text("Azure: \(azureVoice.assistantText)").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            if let status = workspace.scheduleStatusMessage {
                Label(status, systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { !executionMode.isLocalOnly },
                set: { remoteEnabled in
                    workspace.setLocalOnlyMode(!remoteEnabled)
                    if !remoteEnabled { azureVoice.reset() }
                    registry.refresh()
                }
            )) {
                Label(
                    executionMode.isLocalOnly ? "Modo remoto desabilitado — local" : "Modo remoto habilitado",
                    systemImage: executionMode.isLocalOnly ? "lock.shield.fill" : "network"
                )
            }
            .toggleStyle(.switch)
            .font(.caption)
            .help(executionMode.isLocalOnly
                  ? "As funções locais compatíveis continuam disponíveis; pedidos que exigem API são recusados localmente."
                  : "Solicitações compatíveis podem usar a API OpenAI e gerar consumo.")
        }.padding(.horizontal, 26).padding(.vertical, 18)
    }

    private var contextBar: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            Text("Contexto").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(search.activeContracts) { item in
                HStack(spacing: 6) { Button(item.file.name) { Task { await workspace.activateFile(item) } }.buttonStyle(.plain); Button { search.removeActive(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    .font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule())
            }
            ForEach(agent.activeContext) { item in
                Text(item.title).lineLimit(1)
                    .font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule())
            }
        }.padding(.horizontal, 22).padding(.vertical, 9) }
    }

    private func submitCommand() {
        workspace.submit()
    }

    private func resultCard(_ title: String, _ subtitle: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(15).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08))) }.buttonStyle(.plain)
    }

    private func operationsGrid(
        open: @escaping () -> Void,
        openEnabled: Bool = true,
        summarize: @escaping () -> Void,
        summarizeEnabled: Bool = true,
        compareEnabled: Bool,
        compare: @escaping () -> Void,
        share: @escaping () -> Void,
        shareEnabled: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operações").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                operationTile("Abrir", "arrow.up.forward.app", enabled: openEnabled, action: open)
                operationTile("Resumir", "doc.text.magnifyingglass", enabled: summarizeEnabled, action: summarize)
                operationTile("Comparar", "rectangle.on.rectangle", enabled: compareEnabled, action: compare)
                operationTile("Compartilhar", "square.and.arrow.up", enabled: shareEnabled, action: share)
            }
        }.padding(.top, 4)
    }

    private func operationTile(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 64)
        }.buttonStyle(.bordered).disabled(!enabled)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 4)
            Text("Contexto ativo").font(.headline)
            if workspace.attachments.isEmpty && workspace.activeObjects.isEmpty {
                Text("Nenhum documento adicional no contexto.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(workspace.attachments, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "paperclip").font(.caption).lineLimit(2)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(search.activeContracts) { item in
                Label(item.file.name, systemImage: "doc").font(.caption).lineLimit(2)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(workspace.activeObjects, id: \.self) { selection in
                if case .file(let id) = selection,
                   !search.activeContracts.contains(where: { $0.id == id }),
                   let item = workspace.fileCandidate(id: id) {
                    Label(item.file.name, systemImage: "doc").font(.caption).lineLimit(2)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func authorizeFolder() { Task {
        await search.index.chooseAndIndexFolder()
        registry.noteAuthorizedFolders(!search.index.snapshot.roots.isEmpty)
        if workspace.isUnifiedSearchMode, let query = workspace.unifiedSearch.lastSubmittedQuery { workspace.unifiedSearch.search(query) }
    } }
    private func refreshFolders() { Task { await search.index.refreshAuthorizedFolders(); registry.noteAuthorizedFolders(!search.index.snapshot.roots.isEmpty) } }
    private var sidebarConnectors: [PavlakConnector] { ["openai", "photos", "files", "safari", "contacts", "mail", "calendar", "pages", "system-share", "notifications"].compactMap { id in registry.availableConnectors.first { $0.id == id } } }
    private func connectionColor(_ id: String) -> Color { registry.availability[id] == .available ? .green : registry.availability[id] == .permissionRequired ? .orange : .secondary }

    private var mcpStatusSnapshot: PavlakMCPStatusSnapshot {
        PavlakMCPStatusSnapshot(pavlakState: workspace.isPhotoMode ? "pesquisando_fotos" : stateName, availableIntegrations: registry.availableConnectors.filter { registry.availability[$0.id] == .available }.map(\.name).sorted(), selectedDocumentCount: search.activeContracts.count, currentOperation: workspace.operation.identifier)
    }
    private var mcpFingerprint: String { let value = mcpStatusSnapshot; return [value.pavlakState, value.availableIntegrations.joined(), String(value.selectedDocumentCount), value.currentOperation ?? ""].joined(separator: "|") }
    private var stateName: String { switch search.state { case .idle: "pronto"; case .searching: "pesquisando"; case .orchestrating: "processando"; case .results: "resultados_disponiveis"; case .entity: "objeto_disponivel"; case .selected: "documento_selecionado"; case .failed: "atencao_necessaria" } }
    private var search: DocumentSearchViewModel { workspace.documentSearch }
    private var agent: PavlakAgent { workspace.agent }
    private var photos: MacPhotoAlbumSearchService { workspace.photos }
    private var speech: SpeechTranscriptionService { workspace.speech }
    private var azureVoiceIsConfigured: Bool {
        PavlakAIConfigurationStore.load().provider == .azureOpenAI
    }
    private func toggleAzureVoice() {
        if azureVoice.state.isActive { azureVoice.stop() } else { azureVoice.start() }
    }
    private var azureVoiceStateColor: Color {
        if case .failed = azureVoice.state { return .orange }
        return azureVoice.state == .responding ? .blue : .secondary
    }
    private var speechStatusIcon: String {
        switch speech.state {
        case .idle: "text.cursor"
        case .transcribed: "checkmark.circle.fill"
        case .requestingPermission: "hand.raised.fill"
        case .listening: "waveform"
        case .finalizing: "ellipsis.bubble"
        case .permissionDenied: "mic.slash.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private var speechStatusColor: Color {
        switch speech.state {
        case .permissionDenied, .failed: .orange
        case .transcribed: .green
        case .listening: .red
        case .idle, .requestingPermission, .finalizing: .secondary
        }
    }
}
#endif

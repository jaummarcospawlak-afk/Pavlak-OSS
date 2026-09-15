#if os(iOS)
import SwiftUI
@preconcurrency import Photos
import CoreSpotlight
import UIKit
import UniformTypeIdentifiers
import QuickLook

struct IOSContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var registry = PavlakConnectorRegistry.shared
    @StateObject private var albumService = PhotoAlbumService()
    @StateObject private var indexer = PhotoIndexer()

    var body: some View {
        TabView {
            IOSPavlakView(albumService: albumService, indexer: indexer)
                .tabItem { Label("Pavlak", systemImage: "p.circle.fill") }
            NavigationStack {
                PavlakDeviceConnectionView()
                    .navigationTitle("Dispositivos")
            }
            .tabItem { Label("Dispositivos", systemImage: "laptopcomputer.and.iphone") }
            NavigationStack {
                ConnectionsView(registry: registry)
                    .background(Color(.systemGroupedBackground))
            }
            .tabItem { Label("Conexões", systemImage: "point.3.connected.trianglepath.dotted") }
            NavigationStack {
                IOSIndexDiagnosticsView(indexer: indexer)
            }
            .tabItem { Label("Diagnóstico", systemImage: "stethoscope") }
        }
        .task {
            PavlakLinkService.shared.commandHandler = { message in
                if message.action == .photoSearch { return await indexer.handleLink(message) }
                return message.response(status: .failure, result: "Ação não disponível no índice do iPhone.")
            }
            PavlakLinkService.shared.start()
            if indexer.authorizationState.canRead {
                await indexer.indexNewAssets(isInitial: indexer.snapshot.assets.isEmpty)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await indexer.applicationDidBecomeActive() }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let stableID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            Task { await indexer.handleSpotlightSelection(stableID: stableID) }
        }
    }
}

private struct IOSPavlakView: View {
    private enum SelectedPlatform { case iOS, files, macOS }
    private enum InteractionMode: String, CaseIterable { case search = "Buscar", chat = "Perguntar" }
    @ObservedObject var albumService: PhotoAlbumService
    @ObservedObject var indexer: PhotoIndexer
    @ObservedObject private var link = PavlakLinkService.shared
    @ObservedObject private var executionMode = PavlakExecutionMode.shared
    @StateObject private var linkModel = PavlakLinkViewModel()
    @StateObject private var chat = IOSChatState()
    @StateObject private var documents = IOSDocumentStore()
    @State private var selectedPlatform = SelectedPlatform.iOS
    @State private var mode = InteractionMode.search
    @State private var command = ""
    @State private var photoMatches: [PhotoSearchMatch] = []
    @State private var fileMatches: [IOSImportedDocument] = []
    @State private var selectedPhoto: PhotoSearchMatch?
    @State private var selectedFile: IOSImportedDocument?
    @State private var didSearchPhotos = false
    @State private var didSearchMac = false
    @State private var didSearchFiles = false
    @State private var executionRequest: PavlakExecutionRequest?
    @State private var pipelineError: String?
    @State private var isSearching = false
    @State private var searchGeneration = UUID()
    @State private var selectionGeneration = UUID()
    @State private var importing = false
    @State private var previewImage: UIImage?
    @State private var showingImage = false
    @State private var previewURL: URL?
    @State private var showingFile = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Ação", selection: $mode) {
                    ForEach(InteractionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 8)
                commandField.padding(16)
                if mode == .search { sourceCards.padding(.horizontal, 16).padding(.bottom, 10) }
                Divider()
                if mode == .chat { conversation } else { results }
            }
            .navigationTitle("Pavlak")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
            .navigationDestination(for: String.self) { albumID in
                if let album = albumService.matches.first(where: { $0.id == albumID }) {
                    PhotoAlbumDetailView(album: album, service: albumService)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { IOSOpenAISettingsView() } label: { Image(systemName: "brain.head.profile") }
                        .accessibilityLabel("Configurar IA remota")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .jpeg, .png], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let token = searchGeneration
                Task {
                    await documents.add(urls)
                    guard searchGeneration == token else { return }
                    selectedPlatform = .files
                    clearSelection()
                    fileMatches = command.isEmpty ? Array(documents.documents.prefix(5)) : documents.search(command)
                    didSearchFiles = true; didSearchPhotos = false; didSearchMac = false
                }
            case .failure: pipelineError = "Não foi possível acessar os arquivos escolhidos. Tente selecioná-los novamente."
            }
        }
        .sheet(isPresented: $showingImage) {
            NavigationStack {
                Group { if let previewImage { Image(uiImage: previewImage).resizable().scaledToFit() } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { showingImage = false } } }
            }
        }
        .sheet(isPresented: $showingFile, onDismiss: {
            previewURL?.stopAccessingSecurityScopedResource(); previewURL = nil
        }) {
            NavigationStack {
                Group { if let previewURL { IOSFilePreview(url: previewURL) } }
                    .navigationTitle("Documento").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { showingFile = false } } }
            }
        }
        .onChange(of: indexer.snapshot.generation) { _, _ in
            if !isSearching { photoMatches.removeAll(); didSearchPhotos = false }
            if selectedPhoto != nil { clearSelection() }
        }
        .onChange(of: executionMode.isLocalOnly) { _, _ in chat.clear() }
        .onReceive(indexer.$spotlightSelection.compactMap { $0 }) { match in
            searchGeneration = UUID(); isSearching = false
            clearSelection(); selectedPlatform = .iOS; mode = .search
            photoMatches = [match]; didSearchPhotos = true; pipelineError = nil
        }
    }

    private var commandField: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(mode == .search ? "Encontre a identidade de…" : "Pergunte sobre o documento selecionado", text: $command, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain).focused($commandFocused).onSubmit(runCommand)
                .accessibilityIdentifier("pavlak.command")
            Button(action: runCommand) { Image(systemName: "arrow.up").font(.headline).frame(width: 30, height: 30) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isSending || isSearching)
                .accessibilityLabel("Executar").accessibilityIdentifier("pavlak.send")
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var remoteProviderName: String {
        PavlakAIConfigurationStore.load().provider.displayName
    }

    private var sourceCards: some View {
        VStack(spacing: 8) {
            HStack {
                sourceCard("Fotos", icon: "photo", selected: selectedPlatform == .iOS) {
                    changeSource(.iOS)
                }
                sourceCard("Arquivos", icon: "folder", selected: selectedPlatform == .files) {
                    changeSource(.files)
                }
                sourceCard("Mac", icon: "desktopcomputer", selected: selectedPlatform == .macOS) {
                    changeSource(.macOS); link.start()
                }
            }
            if selectedPlatform == .files {
                Button("Escolher PDF ou imagens", systemImage: "folder.badge.plus") { importing = true }
                Text("Somente os arquivos escolhidos, nesta sessão. Os originais são preservados.").font(.caption2)
            } else if selectedPlatform == .iOS {
                Text(indexer.authorizationState.title + " • " + String(indexer.snapshot.pendingContentCount) + " item(ns) aguardando conteúdo local")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(link.remoteState == .connected && link.isTransportEncrypted ? "Mac conectado por TLS" : "Conecte o Mac em Dispositivos")
                    .font(.caption2)
            }
        }
    }

    private func sourceCard(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity).padding(10) }
            .buttonStyle(.plain).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(executionMode.isLocalOnly ? "Modo local: o provider remoto está desativado. Configure a conexão para conversar." : "Perguntas enviadas ao \(remoteProviderName); a busca de documentos continua local.")
                    .font(.caption).foregroundStyle(.secondary)
                if let selection = chat.selection {
                    Text("Selecionado: " + selection.title).font(.headline)
                    Text(selection.evidence).font(.caption).textSelection(.enabled)
                    DisclosureGroup("Texto que pode ser enviado (até 6.000 caracteres)") {
                        Text(String(selection.excerpt.prefix(6000))).font(.caption).textSelection(.enabled)
                    }
                    Toggle("Autorizar envio do texto e da origem deste documento ao provider remoto", isOn: Binding(get: { chat.allowsExcerpt }, set: { chat.setAllowsExcerpt($0) }))
                        .font(.caption)
                    HStack {
                        Button("Abrir selecionado") { Task { await openSelection() } }
                        Button("Limpar seleção") { clearSelection() }
                    }.buttonStyle(.bordered)
                } else { Text("Nenhum documento selecionado. Você pode fazer uma pergunta geral.").font(.caption) }
                ForEach(chat.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == .user ? "Você" : "Pavlak • \(remoteProviderName)").font(.caption.bold())
                        Text(message.text).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                if chat.isSending { HStack { ProgressView("Respondendo…"); Button("Cancelar") { chat.cancel() } } }
                if let error = chat.errorMessage { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if let pipelineError { Label(pipelineError, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }.padding(16)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let pipelineError { Label(pipelineError, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if let error = indexer.errorMessage, selectedPlatform == .iOS { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = documents.errorMessage, selectedPlatform == .files { Text(error).font(.caption).foregroundStyle(.orange) }
                if albumService.isSearching || isSearching || documents.isReading { ProgressView("Consultando…") }
                if indexer.isIndexing { ProgressView("Atualizando OCR local…", value: indexer.progress) }
                if didSearchMac {
                    if linkModel.isWorking { ProgressView("Consultando o Mac…") }
                    if let error = linkModel.errorMessage { Text(error).foregroundStyle(.orange) }
                    Text(linkModel.resultTitle).font(.headline)
                    ForEach(Array(linkModel.resultLines.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                } else if didSearchFiles {
                    if fileMatches.isEmpty { Text("Nenhum candidato nos arquivos escolhidos. Confira cobertura e texto legível.") }
                    ForEach(fileMatches) { document in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(document.title).font(.headline)
                            Text("Arquivos escolhidos • " + document.extraction.coverage).font(.caption)
                            Text(String(document.extraction.text.prefix(240))).font(.caption).textSelection(.enabled)
                            Text("Candidato por correspondência de texto; confira tipo e titular no original.").font(.caption2)
                            HStack {
                                Button("Abrir") { Task { selectFile(document); await openSelection() } }
                                Button("Perguntar sobre este") { selectFile(document); mode = .chat; command = "" }
                            }.buttonStyle(.bordered)
                        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else if !albumService.matches.isEmpty {
                    ForEach(albumService.matches.prefix(5)) { album in
                        NavigationLink(value: album.id) { PhotoAlbumResultView(album: album, service: albumService) }
                    }
                } else if didSearchPhotos {
                    if photoMatches.isEmpty { Text("Nenhum candidato no conteúdo consultado da Fototeca. Itens pendentes ou sem OCR não provam ausência do documento.") }
                    ForEach(photoMatches) { match in
                        PhotoSearchResultCard(match: match, service: albumService, indexer: indexer, request: executionRequest,
                                              onSelect: { await selectPhoto(match) },
                                              onAsk: { if await selectPhoto(match) { mode = .chat; command = "" } })
                    }
                } else if !isSearching { Text("Peça um documento pelo tipo e pela pessoa. A busca usa somente a fonte selecionada.").foregroundStyle(.secondary) }
            }.padding(16)
        }
    }

    private func changeSource(_ source: SelectedPlatform) {
        searchGeneration = UUID(); isSearching = false
        selectedPlatform = source; clearSelection()
        photoMatches = []; fileMatches = []; didSearchPhotos = false; didSearchFiles = false; didSearchMac = false
        albumService.clearResults(); pipelineError = nil
    }

    private func clearSelection() {
        selectionGeneration = UUID()
        selectedPhoto = nil; selectedFile = nil; chat.select(nil)
    }

    @discardableResult private func selectPhoto(_ match: PhotoSearchMatch) async -> Bool {
        let token = UUID(); selectionGeneration = token
        let valid = await indexer.validateForAction(match)
        guard selectionGeneration == token else { return false }
        guard valid,
              let record = indexer.snapshot.assets.first(where: { $0.id == match.id }) else {
            clearSelection(); pipelineError = "Este resultado mudou ou não está acessível. Faça a busca novamente."; return false
        }
        selectedFile = nil; selectedPhoto = match
        chat.select(.init(id: match.id, source: "Fotos do iPhone", title: match.filename ?? "Documento fotografado",
                          evidence: match.evidenceSummary, excerpt: record.extractedTextEvidence?.text ?? ""))
        pipelineError = nil
        return true
    }

    private func selectFile(_ document: IOSImportedDocument) {
        selectionGeneration = UUID()
        selectedPhoto = nil; selectedFile = document
        chat.select(.init(id: document.id.uuidString, source: "Arquivo escolhido no iPhone", title: document.title,
                          evidence: document.extraction.coverage, excerpt: document.extraction.text))
        pipelineError = nil
    }

    private func validateSelection() async -> Bool {
        let token = selectionGeneration
        if let selectedPhoto {
            let valid = await indexer.validateForAction(selectedPhoto)
            guard selectionGeneration == token else { return false }
            guard valid else {
                clearSelection(); pipelineError = "A permissão ou o resultado mudou. Busque novamente."; return false
            }
        }
        if let selectedFile {
            do { let url = try documents.resolve(selectedFile); url.stopAccessingSecurityScopedResource() }
            catch { clearSelection(); pipelineError = error.localizedDescription; return false }
        }
        return true
    }

    private func openSelection() async {
        let token = selectionGeneration
        guard await validateSelection(), selectionGeneration == token else { return }
        if let selectedFile {
            do { previewURL = try documents.resolve(selectedFile); showingFile = true }
            catch { pipelineError = error.localizedDescription }
        } else if let selectedPhoto,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [selectedPhoto.sourceLocalIdentifier], options: nil).firstObject {
            let loadedImage = await albumService.image(for: asset, size: CGSize(width: max(asset.pixelWidth, 1), height: max(asset.pixelHeight, 1)), delivery: .highQualityFormat, networkAllowed: false)
            guard selectionGeneration == token else { return }
            previewImage = loadedImage
            if previewImage != nil { showingImage = true }
            else { pipelineError = "A imagem não está disponível localmente. Nenhum download foi iniciado." }
        } else { pipelineError = "Selecione um resultado para abrir." }
    }

    private func runCommand() {
        let submitted = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        commandFocused = false; pipelineError = nil
        if let position = IOSCommandRouting.openPosition(submitted) {
            Task {
                if didSearchFiles, fileMatches.indices.contains(position) { selectFile(fileMatches[position]); await openSelection() }
                else if didSearchPhotos, photoMatches.indices.contains(position), await selectPhoto(photoMatches[position]) { await openSelection() }
                else { pipelineError = "Não há resultado nessa posição. Faça a busca novamente." }
            }
            return
        }
        if IOSCommandRouting.opensSelection(submitted) { Task { await openSelection() }; return }
        if (mode == .chat && !IOSCommandRouting.isSearch(submitted)) || IOSCommandRouting.isQuestion(submitted) {
            mode = .chat
            let selectedID = chat.selection?.id
            Task {
                guard await validateSelection(), selectedID == chat.selection?.id else { return }
                guard chat.selection == nil || chat.allowsExcerpt else {
                    pipelineError = "Revise o texto e autorize o envio deste documento antes de perguntar sobre ele."; return
                }
                await chat.send(submitted)
            }
            return
        }
        mode = .search
        searchGeneration = UUID()
        clearSelection(); albumService.clearResults()
        didSearchPhotos = false; didSearchFiles = false; didSearchMac = false
        if selectedPlatform == .files { fileMatches = documents.search(submitted); didSearchFiles = true; return }
        if selectedPlatform == .macOS {
            guard link.remoteState == .connected, link.isTransportEncrypted else { pipelineError = "Conecte o Mac em Dispositivos."; return }
            didSearchMac = true; linkModel.sendFileSearch(submitted); return
        }
        let token = UUID(); searchGeneration = token; isSearching = true
        Task {
            if !indexer.authorizationState.canRead { await indexer.requestAccess() }
            guard searchGeneration == token, selectedPlatform == .iOS else { return }
            guard indexer.authorizationState.canRead else { pipelineError = PhotoIndexError.accessDenied.localizedDescription; isSearching = false; return }
            let parsed = PavlakIntentRouter.parse(submitted)
            if parsed.source == .photos && parsed.searchScopes.contains("Álbuns") {
                albumService.search(command: submitted); isSearching = false
            } else {
                executionRequest = try? PavlakExecutionPipeline.shared.prepare(submitted)
                let matches = await indexer.search(query: submitted)
                guard searchGeneration == token, selectedPlatform == .iOS else { return }
                photoMatches = matches; didSearchPhotos = true; isSearching = false
            }
        }
    }
}

private struct IOSFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

private struct IOSIndexDiagnosticsView: View {
    @ObservedObject var indexer: PhotoIndexer

    var body: some View {
        List {
            Section("Índice documental iOS") {
                LabeledContent("Autorização", value: indexer.authorizationState.title)
                LabeledContent("Esquema", value: "v\(indexer.snapshot.schemaVersion)")
                LabeledContent("Geração", value: "\(indexer.snapshot.generation)")
                LabeledContent("Itens visíveis", value: "\(indexer.snapshot.assets.count)")
                LabeledContent("Documentos", value: "\(indexer.snapshot.documentCount)")
                LabeledContent("Pendentes locais", value: "\(indexer.snapshot.pendingContentCount)")
            }
            Section("Armazenamento") {
                Text("Fonte de verdade: Application Support/Pavlak Photo Index/index-v1.json")
                Text("Core Spotlight é uma projeção privada e reconstruível.")
            }
            if let notice = indexer.snapshot.recoveryNotice {
                Section("Recuperação") {
                    Label(notice, systemImage: "arrow.counterclockwise.circle").foregroundStyle(.orange)
                }
            }
            if let error = indexer.errorMessage {
                Section("Atenção") {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("Ações") {
                Button(indexer.authorizationState.canRead ? "Atualizar índice" : "Autorizar Fotos") {
                    Task {
                        if indexer.authorizationState.canRead { await indexer.indexNewAssets() }
                        else { await indexer.requestAccess() }
                    }
                }
                .disabled(indexer.isIndexing)
                if indexer.isIndexing { ProgressView(value: indexer.progress) }
            }
        }
        .navigationTitle("Diagnóstico")
    }
}

private struct PhotoSearchResultCard: View {
    let match: PhotoSearchMatch
    @ObservedObject var service: PhotoAlbumService
    @ObservedObject var indexer: PhotoIndexer
    let request: PavlakExecutionRequest?
    var onSelect: () async -> Bool = { true }
    var onAsk: () async -> Void = {}
    @State private var actionError: String?
    @State private var image: UIImage?
    @State private var showingPreview = false
    @State private var showingShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionableResultView(entity: entity) { action in
                Task {
                    guard await onSelect(), await loadImage() else { actionError = "Não foi possível abrir este resultado. Atualize a busca e confira a disponibilidade local."; return }
                    if action == .preview { showingPreview = true }
                    if action == .share { showingShare = true }
                }
            }
            Button("Perguntar sobre este") { Task { await onAsk() } }.buttonStyle(.bordered)
            if let actionError { Text(actionError).font(.caption).foregroundStyle(.orange) }
            Text(match.textPreview).font(.caption).textSelection(.enabled)
            Label(match.originDescription, systemImage: "iphone")
                .font(.caption2).foregroundStyle(.secondary)
            Text(match.evidenceSummary).font(.caption2).foregroundStyle(.secondary)
            if !match.albumTitles.isEmpty {
                Text("Álbuns observados: " + match.albumTitles.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if match.processingState == .waitingForLocalContent {
                Label("Conteúdo ainda não está disponível localmente e não foi marcado como processado.", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.orange)
                Button("Baixar e processar explicitamente") {
                    Task { await indexer.makeContentAvailable(for: match) }
                }.buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFit().background(.black) }
                }
                .navigationTitle(match.filename ?? "Foto").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { showingPreview = false } } }
            }
        }
        .sheet(isPresented: $showingShare) {
            if let image { ActivityView(items: [image]) }
        }
    }

    private var entity: PavlakResultEntity {
        PavlakResultEntity(
            id: match.id, kind: .photo, title: match.filename ?? "Foto",
            type: "Foto", location: match.originDescription, date: match.date,
            actions: match.canPreviewLocally ? [.preview, .share] : [],
            context: request.map { PavlakResultContext(requestID: $0.id, intent: $0.intent, connectorID: $0.connectorID, toolAction: $0.toolAction, referenceID: match.id) }
        )
    }

    private func loadImage() async -> Bool {
        guard await indexer.validateForAction(match) else {
            image = nil
            return false
        }
        if image != nil { return true }
        guard match.canPreviewLocally,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [match.sourceLocalIdentifier], options: nil).firstObject else { return false }
        image = await service.image(
            for: asset,
            size: CGSize(width: max(asset.pixelWidth, 1), height: max(asset.pixelHeight, 1)),
            delivery: .highQualityFormat,
            networkAllowed: false
        )
        return image != nil
    }
}
#endif

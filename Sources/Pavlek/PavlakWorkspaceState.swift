#if os(macOS)
import Combine
import Foundation

@MainActor
final class PavlakWorkspaceState: ObservableObject {
    struct ResultItem: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case file, photo, text }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let origin: ResultOrigin
    }

    enum ActiveSelection: Hashable, Sendable {
        case none
        case file(String)
        case photo(String)
    }

    enum ResultOrigin: String, Equatable, Sendable {
        case none, files, photos, openAI, localDocuments, localUnified
    }

    enum HubSearchState: Equatable, Sendable {
        case idle
        case searching
        case completed
    }

    enum Operation: Equatable, Sendable {
        case idle
        case searchingFiles
        case searchingPhotos(album: String?)
        case interpreting
        case processingDocuments
        case searchingLocal
        case openingItem(String)

        var identifier: String? {
            switch self {
            case .idle: nil
            case .searchingFiles: "files.search"
            case .searchingPhotos: "photos.search"
            case .interpreting: "openai.interpret"
            case .processingDocuments: "documents.process"
            case .searchingLocal: "local.search"
            case .openingItem: "item.open"
            }
        }
    }

    struct HistoryEntry: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case command, selection }
        let id: UUID
        let kind: Kind
        let value: String
        let date: Date
    }

    @Published var command = ""
    @Published private(set) var activeSelection: ActiveSelection = .none
    @Published private(set) var resultOrigin: ResultOrigin = .none
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var results: [ResultItem] = []
    @Published private(set) var activeObjects: [ActiveSelection] = []
    @Published private(set) var isPhotoMode = false
    @Published private(set) var isUnifiedSearchMode = false
    @Published private(set) var conversations: [PavlakConversationRecord] = []
    @Published private(set) var currentConversationID: UUID?
    @Published private(set) var hubSearchState: HubSearchState = .idle
    @Published private(set) var hubSearchQuery = ""
    @Published private(set) var hubConversationMatches: [PavlakConversationRecord] = []
    @Published private(set) var hubProfileMatches: [PavlakProfileMatch] = []
    @Published private(set) var pendingDocumentSchedule: PendingDocumentSchedule?
    @Published private(set) var scheduleStatusMessage: String?

    let executionMode: PavlakExecutionMode

    let documentSearch: DocumentSearchViewModel
    let agent: PavlakAgent
    let unifiedSearch: LocalUnifiedSearchViewModel
    let speech: SpeechTranscriptionService
    var photos: MacPhotoAlbumSearchService { agent.photos }
    var attachments: [URL] { documentSearch.attachments }

    private var observations: Set<AnyCancellable> = []
    private let hasValidatedOpenAI: () -> Bool
    private let documentScheduler: DocumentScheduling
    private let conversationStore: PavlakConversationStore
    private var speechCommandPrefix = ""
    private var isSpeechSessionActive = false
    private enum SpeechCompletionAction: Equatable { case none, hubSearch, studies }
    private var speechCompletionAction: SpeechCompletionAction = .none

    init(
        documentSearch: DocumentSearchViewModel? = nil,
        agent: PavlakAgent? = nil,
        speech: SpeechTranscriptionService? = nil,
        unifiedSearch: LocalUnifiedSearchViewModel? = nil,
        documentScheduler: DocumentScheduling? = nil,
        hasValidatedOpenAI: @escaping () -> Bool = { PavlakAIConnectionStatus.isReady },
        executionMode: PavlakExecutionMode? = nil,
        conversationStore: PavlakConversationStore? = nil
    ) {
        let resolvedDocumentSearch = documentSearch ?? .init()
        let resolvedAgent = agent ?? .init()
        let resolvedSpeech = speech ?? .init()
        let resolvedConversationStore = conversationStore ?? .init()
        self.documentSearch = resolvedDocumentSearch
        self.agent = resolvedAgent
        self.speech = resolvedSpeech
        self.unifiedSearch = unifiedSearch ?? .init(index: resolvedDocumentSearch.index)
        self.hasValidatedOpenAI = hasValidatedOpenAI
        self.documentScheduler = documentScheduler ?? LocalDocumentScheduler.shared
        self.executionMode = executionMode ?? PavlakExecutionMode.shared
        self.conversationStore = resolvedConversationStore
        self.conversations = resolvedConversationStore.load()
        resolvedDocumentSearch.command = command
        resolvedDocumentSearch.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in await Task.yield(); self?.reconcileDocumentState() }
        }.store(in: &observations)
        resolvedAgent.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in await Task.yield(); self?.reconcileAgentState() }
        }.store(in: &observations)
        self.unifiedSearch.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in await Task.yield(); self?.reconcileUnifiedSearchState() }
        }.store(in: &observations)
        resolvedSpeech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        resolvedSpeech.$transcript.dropFirst().sink { [weak self] transcript in
            Task { @MainActor [weak self] in self?.applySpeechTranscript(transcript) }
        }.store(in: &observations)
        resolvedSpeech.$state.dropFirst().sink { [weak self] state in
            Task { @MainActor [weak self] in self?.reconcileSpeechState(state) }
        }.store(in: &observations)
    }

    func submit() {
        if speech.state.isCapturingOrRequesting {
            speech.stop()
            isSpeechSessionActive = false
        }
        let original = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        record(.command, original)
        let normalized = Self.normalize(original)

        if let scheduledAt = DocumentScheduleParser.parse(original),
           case .file = activeSelection,
           let selected = documentSearch.selected,
           let url = documentSearch.previewURL {
            stageDocumentSchedule(fileName: selected.file.name, fileURL: url, scheduledAt: scheduledAt)
            command = ""
            return
        }

        if isUnifiedSearchMode,
           ["abra o primeiro", "abrir o primeiro", "abra o segundo", "abrir o segundo", "revele o primeiro no finder"].contains(normalized),
           let results = unifiedSearch.report?.results {
            let position = normalized.contains("segundo") ? 1 : 0
            if results.indices.contains(position) {
                let result = results[position]
                Task {
                    await selectUnifiedResult(result)
                    await unifiedSearch.perform(normalized.contains("finder") ? .reveal : .open, on: result)
                }
            }
            return
        }

        if let query = LocalUnifiedSearchQuery.recognize(original) {
            beginScopedLocalSearch()
            isPhotoMode = false
            isUnifiedSearchMode = true
            resultOrigin = .localUnified
            operation = .searchingLocal
            unifiedSearch.search(query)
            return
        }

        if isPhotoMode, ["abra o primeiro", "abrir o primeiro"].contains(normalized) {
            operation = .openingItem("first")
            Task {
                await photos.openFirstResult()
                if let selected = photos.selected { activatePhoto(selected) }
                operation = .idle
            }
            return
        }

        if Self.isAlbumSearch(normalized) {
            let album = Self.albumName(from: original)
            isPhotoMode = true
            isUnifiedSearchMode = false
            resultOrigin = .photos
            operation = .searchingPhotos(album: album)
            Task {
                let query = normalized.contains("rg") ? "RG" : ""
                await photos.search(query: query, inAlbum: album)
                operation = .idle
            }
            return
        }

        if executionMode.isLocalOnly && !canAttemptLocally(normalized) {
            isPhotoMode = false
            isUnifiedSearchMode = false
            resultOrigin = .localDocuments
            operation = .idle
            documentSearch.presentLocalOnlyUnavailable()
            command = ""
            return
        }

        if hasValidatedOpenAI() && !executionMode.isLocalOnly {
            isPhotoMode = false
            isUnifiedSearchMode = false
            resultOrigin = .openAI
            operation = .interpreting
            currentConversationID = currentConversationID ?? UUID()
            agent.send(original)
            command = ""
            return
        }

        isPhotoMode = false
        isUnifiedSearchMode = false
        resultOrigin = attachments.count >= 2 ? .localDocuments : .files
        operation = attachments.count >= 2 ? .processingDocuments : .searchingFiles
        documentSearch.command = original
        documentSearch.search()
    }

    func setLocalOnlyMode(_ enabled: Bool) {
        executionMode.setLocalOnly(enabled)
        if enabled {
            agent.activateLocalOnlyMode()
            documentSearch.activateLocalOnlyMode()
            if resultOrigin == .openAI {
                resultOrigin = .localDocuments
                operation = .idle
            }
        }
    }

    func activateFile(_ candidate: FileSearchCandidate) async {
        await documentSearch.select(candidate)
        activeSelection = .file(candidate.id)
        retainActive(.file(candidate.id))
        resultOrigin = .files
        record(.selection, candidate.id)
    }

    func activatePhoto(_ result: MacPhotoSearchResult) {
        activeSelection = .photo(result.id)
        retainActive(.photo(result.id))
        resultOrigin = .photos
        record(.selection, result.id)
    }

    func selectPhoto(_ result: MacPhotoSearchResult) async {
        await photos.select(result)
        activatePhoto(result)
    }

    func selectUnifiedResult(_ result: LocalUnifiedSearchResult) async {
        if result.source == .authorizedPhotos {
            activeSelection = .photo(result.sourceID)
            retainActive(.photo(result.sourceID))
            record(.selection, result.sourceID)
        }
        if let candidate = unifiedSearch.fileCandidate(for: result) {
            documentSearch.selectWithoutOpening(candidate)
            activeSelection = .file(candidate.id)
            retainActive(.file(candidate.id))
            record(.selection, candidate.id)
        }
        resultOrigin = .localUnified
        isUnifiedSearchMode = true
    }

    func addAttachments(_ urls: [URL]) { documentSearch.addAttachments(urls); objectWillChange.send() }
    func removeAttachment(_ url: URL) { documentSearch.removeAttachment(url); objectWillChange.send() }

    func toggleSpeechTranscription() {
        if speech.state.isCapturingOrRequesting {
            speech.stop()
            speechCompletionAction = .none
            return
        }
        speechCommandPrefix = command
        isSpeechSessionActive = true
        speechCompletionAction = .none
        speech.start()
    }

    func startHubVoiceSearch() {
        if speech.state.isCapturingOrRequesting {
            speech.stop()
            speechCompletionAction = .none
            return
        }
        speechCommandPrefix = ""
        command = ""
        isSpeechSessionActive = true
        speechCompletionAction = .hubSearch
        speech.start()
    }

    func startStudiesVoiceSearch() {
        if speech.state.isCapturingOrRequesting {
            speech.stop()
            speechCompletionAction = .none
            return
        }
        speechCommandPrefix = ""
        command = ""
        isSpeechSessionActive = true
        speechCompletionAction = .studies
        speech.start()
    }

    func submitHubSearch() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            hubSearchState = .idle
            hubSearchQuery = ""
            hubConversationMatches = []
            hubProfileMatches = []
            return
        }
        hubSearchQuery = value
        hubConversationMatches = conversations.filter { record in
            let haystack = ([record.title] + record.messages.map(\.text)).joined(separator: " ")
            return Self.containsAllTerms(value, in: haystack)
        }
        hubProfileMatches = PavlakProfileStore.matches(query: value)
        hubSearchState = .searching
        beginScopedLocalSearch()
        isPhotoMode = false
        isUnifiedSearchMode = true
        resultOrigin = .localUnified
        operation = .searchingLocal
        if let query = Self.localSearchQuery(for: value) {
            unifiedSearch.search(query)
        } else {
            hubSearchState = .completed
            operation = .idle
        }
    }

    func searchStudies() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let query = Self.localSearchQuery(for: value) else {
            isUnifiedSearchMode = true
            hubSearchState = .completed
            resultOrigin = .localUnified
            operation = .idle
            unifiedSearch.search(LocalUnifiedSearchQuery.recognize("Procure arquivo (value)") ?? .init(
                original: value, normalized: value.lowercased(), documentKind: .file,
                requestedPhrase: "arquivo", expandedPhrases: LocalUnifiedSearchQuery.DocumentKind.file.phrases,
                detailTerms: value.split(separator: " ").map(String.init)
            ))
            return
        }
        record(.command, value)
        beginScopedLocalSearch()
        isPhotoMode = false
        isUnifiedSearchMode = true
        resultOrigin = .localUnified
        operation = .searchingLocal
        unifiedSearch.search(query)
    }

    func restoreConversation(_ record: PavlakConversationRecord) {
        currentConversationID = record.id
        command = ""
        isPhotoMode = false
        isUnifiedSearchMode = false
        resultOrigin = .none
        operation = .idle
        activeSelection = .none
        activeObjects = []
        documentSearch.clearContextForScopedSearch()
        agent.restoreConversation(record.messages.map { message in
            PavlakChatMessage(id: message.id, role: message.role == .user ? .user : .assistant, text: message.text)
        })
    }

    func startNewConversation() {
        currentConversationID = UUID()
        command = ""
        isPhotoMode = false
        isUnifiedSearchMode = false
        resultOrigin = .none
        operation = .idle
        activeSelection = .none
        activeObjects = []
        documentSearch.clearContextForScopedSearch()
        agent.startNewConversation()
    }

    func clearActiveSelection() { activeSelection = .none }

    private func beginScopedLocalSearch() {
        documentSearch.clearContextForScopedSearch()
        agent.clearContextForScopedSearch()
        unifiedSearch.clearContextForScopedSearch()
        activeSelection = .none
        activeObjects = []
        results = []
        pendingDocumentSchedule = nil
        scheduleStatusMessage = nil
    }

    func confirmDocumentSchedule() {
        guard let request = pendingDocumentSchedule else { return }
        pendingDocumentSchedule = nil
        Task {
            do {
                try await documentScheduler.schedule(request)
                scheduleStatusMessage = "Agendamento criado para \(request.fileName) em \(request.scheduledAt.formatted(date: .abbreviated, time: .shortened))."
            } catch {
                scheduleStatusMessage = error.localizedDescription
            }
        }
    }

    func cancelDocumentSchedule() {
        pendingDocumentSchedule = nil
        scheduleStatusMessage = "Agendamento cancelado. Nenhuma notificação foi criada."
    }

    func stageDocumentSchedule(fileName: String, fileURL: URL, scheduledAt: Date) {
        pendingDocumentSchedule = PendingDocumentSchedule(
            id: UUID(), fileName: fileName, fileURL: fileURL, scheduledAt: scheduledAt
        )
        scheduleStatusMessage = nil
    }

    func fileCandidate(id: String) -> FileSearchCandidate? {
        documentSearch.candidates.first { $0.id == id }
            ?? agent.fileResults.first { $0.id == id }
    }

    private func reconcileDocumentState() {
        if isUnifiedSearchMode {
            if let selected = documentSearch.selected, activeSelection != .file(selected.id) {
                activeSelection = .file(selected.id)
                retainActive(.file(selected.id))
            }
            return
        }
        results = documentSearch.candidates.map { candidate in
            ResultItem(
                id: candidate.id,
                kind: .file,
                title: candidate.file.name,
                subtitle: "\(candidate.file.fileExtension.uppercased()) • \(candidate.file.relativePath)",
                origin: .files
            )
        }
        if let selected = documentSearch.selected, activeSelection != .file(selected.id) {
            activeSelection = .file(selected.id)
            retainActive(.file(selected.id))
        }
        switch documentSearch.state {
        case .searching: operation = .searchingFiles
        case .orchestrating: operation = documentSearch.isProcessingDocument ? .processingDocuments : .interpreting
        case .idle, .results, .entity, .selected, .failed: operation = .idle
        }
    }

    private func reconcileUnifiedSearchState() {
        guard isUnifiedSearchMode else { return }
        results = (unifiedSearch.report?.results ?? []).map { result in
            ResultItem(
                id: result.id,
                kind: result.source == .authorizedPhotos ? .photo : .file,
                title: result.title,
                subtitle: "\(result.source.title) • confiança \(result.confidence.rawValue.lowercased())",
                origin: .localUnified
            )
        }
        operation = unifiedSearch.state == .searching ? .searchingLocal : .idle
        if hubSearchState == .searching, unifiedSearch.state != .searching {
            hubSearchState = .completed
        }
    }

    private func reconcileAgentState() {
        guard !isUnifiedSearchMode else { return }
        if !agent.fileResults.isEmpty {
            results = agent.fileResults.map { candidate in
                ResultItem(
                    id: candidate.id,
                    kind: .file,
                    title: candidate.file.name,
                    subtitle: "\(candidate.file.fileExtension.uppercased()) • \(candidate.file.relativePath)",
                    origin: .openAI
                )
            }
        }
        switch agent.state {
        case .thinking, .analyzing: operation = .interpreting
        case .searchingFiles: operation = .searchingFiles
        case .searchingPhotos: operation = .searchingPhotos(album: photos.searchedAlbumName.isEmpty ? nil : photos.searchedAlbumName)
        case .idle, .found, .completed, .failed: operation = .idle
        }
        persistCurrentConversation()
    }

    private func applySpeechTranscript(_ transcript: String) {
        guard isSpeechSessionActive else { return }
        command = SpeechCommandComposer.compose(baseCommand: speechCommandPrefix, transcript: transcript)
    }

    private func reconcileSpeechState(_ state: SpeechTranscriptionService.State) {
        switch state {
        case .transcribed:
            isSpeechSessionActive = false
            let action = speechCompletionAction
            speechCompletionAction = .none
            guard action != .none else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                switch action {
                case .hubSearch: self.submitHubSearch()
                case .studies: self.searchStudies()
                case .none: break
                }
            }
        case .permissionDenied, .failed:
            isSpeechSessionActive = false
            speechCompletionAction = .none
        case .idle:
            if !speech.transcript.isEmpty { isSpeechSessionActive = false }
        case .requestingPermission, .listening, .finalizing:
            break
        }
    }

    private func record(_ kind: HistoryEntry.Kind, _ value: String) {
        history.append(.init(id: UUID(), kind: kind, value: value, date: Date()))
        if history.count > 100 { history.removeFirst(history.count - 100) }
    }

    private func retainActive(_ selection: ActiveSelection) {
        guard selection != .none else { return }
        activeObjects.removeAll { $0 == selection }
        activeObjects.append(selection)
    }

    private static func albumName(from command: String) -> String {
        PhotoAlbumRequest.name(from: command)
    }

    private static func isAlbumSearch(_ normalized: String) -> Bool {
        (normalized.contains("album") || normalized.contains("albuns")) && ["procure", "buscar", "busque", "pesquise", "encontre", "localize"]
            .contains(where: normalized.contains)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canAttemptLocally(_ normalized: String) -> Bool {
        if documentSearch.selected != nil { return true }
        if attachments.count >= 2,
           normalized.contains("nom"),
           (normalized.contains("dois") || normalized.contains("ambos")) { return true }
        if DocumentSearchViewModel.isGenericLocalFileSearch(normalized) { return true }
        if normalized.contains("http://") || normalized.contains("https://") { return true }
        return normalized.hasPrefix("abra ") || normalized.hasPrefix("abrir ")
    }

    private func persistCurrentConversation() {
        guard !agent.messages.isEmpty else { return }
        let id = currentConversationID ?? UUID()
        currentConversationID = id
        let existing = conversations.first(where: { $0.id == id })
        let messages = agent.messages.map { message in
            PavlakConversationMessage(id: message.id, role: message.role == .user ? .user : .assistant, text: message.text)
        }
        let title = messages.first(where: { $0.role == .user })?.text ?? "Conversa sem título"
        let record = PavlakConversationRecord(
            id: id,
            title: title,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            messages: messages
        )
        conversationStore.upsert(record)
        conversations = conversationStore.load()
    }

    private static func localSearchQuery(for value: String) -> LocalUnifiedSearchQuery? {
        LocalUnifiedSearchQuery.recognize(value) ?? LocalUnifiedSearchQuery.recognize("Procure (value)")
    }

    private static func containsAllTerms(_ query: String, in text: String) -> Bool {
        let normalizedQuery = normalize(query)
        let normalizedText = normalize(text)
        let terms = normalizedQuery.split(separator: " ").map(String.init).filter { $0.count > 1 }
        return !terms.isEmpty && terms.allSatisfy { normalizedText.contains($0) }
    }
}
#endif

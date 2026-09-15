#if os(macOS)
import AppKit
import Combine
import Foundation

struct LocalUnifiedSearchQuery: Equatable, Sendable {
    enum DocumentKind: String, Equatable, Sendable {
        case propertyRegistration = "Matrícula"
        case residence = "Comprovante de residência"
        case ticket = "Ingresso"
        case file = "Arquivo"
        case contract = "Contrato"
        case receipt = "Comprovante"
        case marriageCertificate = "Certidão de casamento"

        var phrases: [String] {
            switch self {
            case .propertyRegistration:
                ["certidao de matricula", "registro de imovel", "registro imobiliario", "matriculas", "matricula"]
            case .residence: ["comprovante de residencia", "comprovante de endereco", "conta de agua", "talao de agua", "fatura de agua", "conta de luz", "conta de energia"]
            case .ticket: ["ingresso", "bilhete", "ticket"]
            case .file: ["arquivo", "documento", "pdf"]
            case .contract:
                ["instrumento contratual", "contratos", "contrato"]
            case .receipt:
                ["comprovante de transferencia", "comprovante de pagamento", "comprovantes", "comprovante", "recibos", "recibo"]
            case .marriageCertificate:
                ["certidoes de casamento", "certidao de casamento", "registro de casamento"]
            }
        }
    }

    let original: String
    let normalized: String
    let documentKind: DocumentKind
    let requestedPhrase: String
    let expandedPhrases: [String]
    let detailTerms: [String]
    var dateContext: Date? = nil

    static func recognize(_ command: String) -> LocalUnifiedSearchQuery? {
        let normalized = LocalSearchText.normalize(command)
        let verbs = ["encontrar", "localizar", "procurar", "ache", "buscar", "busque", "encontre", "localize", "pesquise", "procure"]
        guard verbs.contains(where: { normalized.contains($0) }) else { return nil }
        let requestedTokens = Set(normalized.split(separator: " ").map(String.init))
        let deferredSources = Set(["album", "foto", "fotos", "fototeca", "galeria", "imagem", "imagens", "calendario", "contato", "contatos", "email", "emails", "notas", "safari"])
        guard requestedTokens.isDisjoint(with: deferredSources) else { return nil }
        let matches = DocumentKind.allCasesForSearch.flatMap { kind in
            kind.phrases.compactMap { normalized.contains($0) ? (kind, $0) : nil }
        }
        let match = matches.max(by: { $0.1.count < $1.1.count }) ?? (.file, "arquivo")

        let ignored = Set(
            verbs
                + [match.1].flatMap { $0.split(separator: " ").map(String.init) }
                + [
                    "a", "as", "de", "do", "dos", "da", "das", "e", "em", "me", "meu", "meus", "minha", "minhas",
                    "mais", "na", "nas", "no", "nos", "o", "os", "para", "pavlak", "pavlek", "por", "recente", "recentes",
                    "hoje", "ontem", "amanha", "um", "uma", "ultimo", "ultima", "ultimos", "ultimas"
                ]
        )
        let otherCategoryWords = Set(matches.filter { $0.0 != .residence }.flatMap { $0.1.split(separator: " ").map(String.init) })
        let detailTerms = normalized.split(separator: " ").map(String.init)
            .filter { ($0.count >= 2 || $0.allSatisfy(\.isNumber)) && !ignored.contains($0) && !otherCategoryWords.contains($0) }
        return .init(
            original: command,
            normalized: normalized,
            documentKind: match.0,
            requestedPhrase: match.1,
            expandedPhrases: match.0.phrases,
            detailTerms: detailTerms,
            dateContext: requestedTokens.contains("hoje") ? Calendar.current.startOfDay(for: Date()) : requestedTokens.contains("ontem") ? Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) : requestedTokens.contains("amanha") ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) : nil
        )
    }
}

private extension LocalUnifiedSearchQuery.DocumentKind {
    static let allCasesForSearch: [Self] = [.propertyRegistration, .contract, .receipt, .marriageCertificate, .residence, .ticket, .file]
}

enum LocalUnifiedSearchSource: String, Hashable, Sendable {
    case authorizedFiles
    case authorizedPhotos

    var title: String {
        self == .authorizedFiles ? "Pastas autorizadas" : "Fotos autorizadas"
    }
}

enum LocalSearchConfidence: String, Equatable, Sendable {
    case high = "Alta"
    case medium = "Média"
    case low = "Baixa"
}

struct LocalSearchScoreBreakdown: Equatable, Sendable {
    let exactPhrase: Int
    let name: Int
    let contentOrOCR: Int
    let metadata: Int

    var date: Int = 0
    var fileType: Int = 0
    var total: Int { exactPhrase + name + contentOrOCR + metadata + date + fileType }
}

struct LocalSearchRecord: Equatable, Sendable {
    let id: String
    let source: LocalUnifiedSearchSource
    let title: String
    let date: Date?
    let nameText: String
    let contentOrOCRText: String
    let metadataText: String
}

struct LocalUnifiedSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let source: LocalUnifiedSearchSource
    let title: String
    let date: Date?
    let reason: String
    let confidence: LocalSearchConfidence
    let score: LocalSearchScoreBreakdown
}

enum LocalSearchSourceStatus: Equatable, Sendable {
    case consulted(resultCount: Int)
    case partial(String)
    case blocked(String)
    case unavailable(String)
    case failed(String)

    var wasConsulted: Bool {
        if case .consulted = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .consulted(let count): "consultada (\(count) candidato\(count == 1 ? "" : "s"))"
        case .partial(let message), .blocked(let message), .unavailable(let message), .failed(let message): message
        }
    }
}

struct LocalUnifiedSearchReport: Equatable, Sendable {
    let query: LocalUnifiedSearchQuery
    let results: [LocalUnifiedSearchResult]
    let sourceStatuses: [LocalUnifiedSearchSource: LocalSearchSourceStatus]
    var spotlightDetail: String? = nil

    var canReportTotalAbsence: Bool {
        results.isEmpty
            && !sourceStatuses.isEmpty && sourceStatuses.values.allSatisfy { $0.wasConsulted }
    }

    var incompleteSources: [(LocalUnifiedSearchSource, LocalSearchSourceStatus)] {
        LocalUnifiedSearchSource.allCasesForSearch.compactMap { source in
            guard let status = sourceStatuses[source], !status.wasConsulted else { return nil }
            return (source, status)
        }
    }
}

private extension LocalUnifiedSearchSource {
    static let allCasesForSearch: [LocalUnifiedSearchSource] = [.authorizedFiles]
}

enum LocalUnifiedSearchRanker {
    static func rank(
        query: LocalUnifiedSearchQuery,
        records: [LocalSearchRecord],
        limit: Int = 5
    ) -> [LocalUnifiedSearchResult] {
        records.compactMap { evaluate(query: query, record: $0) }
            .sorted {
                if $0.score.total != $1.score.total { return $0.score.total > $1.score.total }
                return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private static func evaluate(
        query: LocalUnifiedSearchQuery,
        record: LocalSearchRecord
    ) -> LocalUnifiedSearchResult? {
        let name = LocalSearchText.normalize(record.nameText)
        let content = LocalSearchText.normalize(record.contentOrOCRText)
        let metadata = LocalSearchText.normalize(record.metadataText)
        let fields = [name, content, metadata]

        let requestedCombination = ([query.requestedPhrase] + query.detailTerms).joined(separator: " ")
        let exact = fields.contains { $0.contains(requestedCombination) } ? 42 : 0
        let nameMatch = fieldScore(name, phrases: query.expandedPhrases, detailTerms: query.detailTerms, weight: 30)
        let contentMatch = fieldScore(content, phrases: query.expandedPhrases, detailTerms: query.detailTerms, weight: 24)
        let metadataMatch = fieldScore(metadata, phrases: query.expandedPhrases, detailTerms: query.detailTerms, weight: 14)
        let breakdown = LocalSearchScoreBreakdown(
            exactPhrase: exact,
            name: nameMatch.score,
            contentOrOCR: contentMatch.score,
            metadata: metadataMatch.score,
            date: query.dateContext.map { target in record.date.map { Calendar.current.isDate($0, inSameDayAs: target) ? 18 : 0 } ?? 0 } ?? 0,
            fileType: ["pdf", "doc", "docx", "pages", "txt", "rtf", "md"].contains((record.title as NSString).pathExtension.lowercased()) ? 3 : 0
        )

        let matches = [nameMatch, contentMatch, metadataMatch]
        guard matches.contains(where: { $0.categoryPhrase != nil }) || (query.documentKind == .file && matches.contains(where: { !$0.details.isEmpty })) else { return nil }
        if !query.detailTerms.isEmpty {
            guard matches.contains(where: { !$0.details.isEmpty }) else { return nil }
        }

        var reasons: [String] = []
        if breakdown.date > 0 { reasons.append("modificado na data pedida; isso não confirma a data do evento") }
        if exact > 0 { reasons.append("expressão solicitada no arquivo: “\(requestedCombination)”") }
        appendReason(&reasons, location: "no nome", match: nameMatch)
        appendReason(&reasons, location: "no texto", match: contentMatch)
        appendReason(&reasons, location: "na pasta ou nos metadados", match: metadataMatch)

        let confidence: LocalSearchConfidence
        if breakdown.total >= 65 { confidence = .high }
        else if breakdown.total >= 28 { confidence = .medium }
        else { confidence = .low }

        return LocalUnifiedSearchResult(
            id: "\(record.source.rawValue):\(record.id)",
            sourceID: record.id,
            source: record.source,
            title: record.title,
            date: record.date,
            reason: reasons.joined(separator: "; ") + ". É apenas um candidato; selecionar não abre nem altera o arquivo.",
            confidence: confidence,
            score: breakdown
        )
    }

    private static func fieldScore(
        _ field: String,
        phrases: [String],
        detailTerms: [String],
        weight: Int
    ) -> (score: Int, categoryPhrase: String?, details: [String]) {
        guard !field.isEmpty else { return (0, nil, []) }
        let phrase = phrases.first(where: { field.contains($0) })
        let details = detailTerms.filter { field.contains($0) }
        guard phrase != nil || !details.isEmpty else { return (0, nil, []) }
        return ((phrase == nil ? 0 : weight) + min(details.count, 3) * 5, phrase, details)
    }

    private static func appendReason(
        _ reasons: inout [String],
        location: String,
        match: (score: Int, categoryPhrase: String?, details: [String])
    ) {
        guard match.categoryPhrase != nil || !match.details.isEmpty else { return }
        var fragments: [String] = []
        if let phrase = match.categoryPhrase { fragments.append("tipo “\(phrase)”") }
        if !match.details.isEmpty {
            fragments.append("detalhe\(match.details.count == 1 ? "" : "s") “\(match.details.joined(separator: ", "))”")
        }
        reasons.append(fragments.joined(separator: " e ") + " \(location)")
    }
}

@MainActor
final class PavlakOrchestrator: ObservableObject {
    enum State: Equatable { case idle, searching, completed }
    typealias SearchExecutor = @MainActor @Sendable (LocalUnifiedSearchQuery) async -> LocalUnifiedSearchReport

    @Published private(set) var actionError: String?
    @Published private(set) var intent: PavlakIntent?
    private var generation = UUID()
    private var searchTask: Task<Void, Never>?
    private var photoService: MacPhotoAlbumSearchService?
    @Published private(set) var state: State = .idle
    @Published private(set) var report: LocalUnifiedSearchReport?
    @Published private(set) var lastSubmittedQuery: LocalUnifiedSearchQuery?

    private let executor: SearchExecutor
    private var fileCandidates: [String: FileSearchCandidate] = [:]
    private var productionIndex: FileIndexService?

    init(index: FileIndexService) {
        productionIndex = index
        let photos = MacPhotoAlbumSearchService()
        photoService = photos
        executor = { query in
            await Self.performProductionSearch(query: query, index: index, photos: photos)
        }
    }

    init(searchExecutor: @escaping SearchExecutor) {
        executor = searchExecutor
    }

    func search(_ query: LocalUnifiedSearchQuery) {
        searchTask?.cancel()
        let requestID = UUID()
        generation = requestID
        actionError = nil
        intent = PavlakIntent(query: query)
        lastSubmittedQuery = query
        state = .searching
        report = nil
        fileCandidates = [:]
        searchTask = Task {
            let interpreted = await PavlakLocalIntentInterpreter.interpret(query)
            guard generation == requestID else { return }
            intent = PavlakIntent(query: interpreted)
            let completed = await executor(interpreted)
            guard generation == requestID else { return }
            if let index = productionIndex {
                let scoped = await index.authorizedSnapshot()
                fileCandidates = Dictionary(uniqueKeysWithValues: completed.results.compactMap { result in
                    guard result.source == .authorizedFiles,
                          let file = scoped.files.first(where: { $0.id == result.sourceID }) else { return nil }
                    return (file.id, FileSearchCandidate(file: file, score: result.score.total))
                })
            }
            guard generation == requestID else { return }
            report = completed
            state = .completed
        }
    }

    func clearContextForScopedSearch() {
        searchTask?.cancel()
        searchTask = nil
        generation = UUID()
        actionError = nil
        intent = nil
        report = nil
        lastSubmittedQuery = nil
        fileCandidates = [:]
        state = .idle
    }

    func fileCandidate(for result: LocalUnifiedSearchResult) -> FileSearchCandidate? {
        guard result.source == .authorizedFiles else { return nil }
        return fileCandidates[result.sourceID]
    }

    private static func performProductionSearch(
        query: LocalUnifiedSearchQuery,
        index: FileIndexService,
        photos: MacPhotoAlbumSearchService
    ) async -> LocalUnifiedSearchReport {
        let provider = PavlakFileSearchProvider(index: index)
        let directories = await index.authorizedDirectories()
        let spotlight = PavlakSpotlightSearch()
        async let spotlightResponse = spotlight.search(query, directories: directories)
        let files = await provider.search(query)
        let metadata = await spotlightResponse
        let scoped = await index.authorizedSnapshot()
        var enriched: [LocalSearchRecord] = []
        for record in files.records {
            let indexed = scoped.files.first { $0.id == record.id }
            let url = if let indexed { try? await index.resolveForPreview(indexed) } else { nil as URL? }
            defer { url?.stopAccessingSecurityScopedResource() }
            let hit = metadata.hits.first { $0.path == url?.standardizedFileURL.resolvingSymlinksInPath().path }
            enriched.append(.init(id: record.id, source: record.source, title: record.title,
                                  date: hit?.modifiedAt ?? record.date, nameText: record.nameText,
                                  contentOrOCRText: record.contentOrOCRText,
                                  metadataText: record.metadataText + " " + (hit?.metadata ?? "")))
        }
        let photoStatus = await photos.searchAlreadyAuthorized(query: (query.expandedPhrases + query.detailTerms).joined(separator: " "))
        enriched += photoRecords(photos.results)
        let ranked = LocalUnifiedSearchRanker.rank(query: query, records: enriched)
        let fileCount = ranked.filter { $0.source == .authorizedFiles }.count
        var statuses: [LocalUnifiedSearchSource: LocalSearchSourceStatus] = [
            .authorizedFiles: files.status
        ]
        switch photoStatus {
        case .consulted: statuses[.authorizedPhotos] = .consulted(resultCount: ranked.filter { $0.source == .authorizedPhotos }.count)
        case .partial(let detail): statuses[.authorizedPhotos] = .partial(detail)
        case .blocked(let detail): statuses[.authorizedPhotos] = .blocked(detail)
        case .albumUnavailable(let detail): statuses[.authorizedPhotos] = .unavailable(detail)
        case .failed(let detail): statuses[.authorizedPhotos] = .failed(detail)
        }
        if files.status.wasConsulted { statuses[.authorizedFiles] = .consulted(resultCount: fileCount) }
        return .init(query: query, results: ranked, sourceStatuses: statuses, spotlightDetail: metadata.detail)
    }

    static func photoRecords(_ results: [MacPhotoSearchResult]) -> [LocalSearchRecord] {
        results.map {
            .init(id: $0.id, source: .authorizedPhotos, title: $0.filename ?? "Foto de documento",
                  date: $0.creationDate, nameText: $0.filename ?? "", contentOrOCRText: $0.recognizedText,
                  metadataText: $0.albumTitle)
        }
    }

    static func searchFiles(
        query: LocalUnifiedSearchQuery,
        index: FileIndexService
    ) async -> (records: [LocalSearchRecord], status: LocalSearchSourceStatus) {
        let scoped = await index.authorizedSnapshot()
        guard scoped.coveredDirectoryCount > 0 else {
            return ([], .blocked("Nenhuma pasta com autorização válida. Use Escolher pasta para permitir a leitura."))
        }
        var records: [LocalSearchRecord] = []
        var extractionFailures: [String: Int] = [:]
        for file in scoped.files {
            let candidate = FileSearchCandidate(file: file, score: 0)
            let content: String
            do {
                content = try await index.extractText(from: candidate)
            } catch let error as FileIndexError {
                content = ""
                let key: String
                switch error {
                case .protectedDocument: key = "protegido(s)"
                case .unsupportedDocument: key = "sem extração de texto suportada"
                case .emptyDocument: key = "sem texto extraível"
                case .rootUnavailable, .staleAuthorization: key = "indisponível(is)"
                }
                extractionFailures[key, default: 0] += 1
            } catch {
                content = ""
                extractionFailures["com falha de leitura", default: 0] += 1
            }
            let rootName = scoped.rootNamesByID[file.rootID] ?? ""
            let directory = (file.relativePath as NSString).deletingLastPathComponent
            records.append(.init(
                id: file.id,
                source: .authorizedFiles,
                title: file.name,
                date: file.modifiedAt,
                nameText: file.name,
                contentOrOCRText: content,
                metadataText: [rootName, directory, file.fileExtension].joined(separator: " ")
            ))
        }
        var limitations: [String] = []
        if scoped.coveredDirectoryCount < index.snapshot.roots.count {
            limitations.append("algumas autorizações não puderam ser recuperadas")
        }
        for key in extractionFailures.keys.sorted() {
            if let count = extractionFailures[key] {
                limitations.append("\(count) arquivo\(count == 1 ? "" : "s") \(key)")
            }
        }
        if !limitations.isEmpty {
            return (records, .partial("metadados consultados; " + limitations.joined(separator: "; ")))
        }
        return (records, .consulted(resultCount: 0))
    }

    func location(for result: LocalUnifiedSearchResult) -> String {
        if result.source == .authorizedPhotos {
            return photoService?.results.first { $0.id == result.sourceID }?.albumTitle ?? "Fototeca autorizada"
        }
        guard let file = fileCandidate(for: result)?.file else { return "Localização indisponível" }
        let root = productionIndex?.snapshot.roots.first { $0.id == file.rootID }?.displayName ?? "Pasta autorizada"
        return root + "/" + file.relativePath
    }

    func perform(_ action: PavlakDocumentAction, on result: LocalUnifiedSearchResult) async {
        actionError = nil
        if result.source == .authorizedPhotos {
            guard let service = photoService, let photo = service.results.first(where: { $0.id == result.sourceID }) else {
                actionError = "A foto não está mais disponível. Pesquise novamente."
                return
            }
            await service.open(photo)
            if case .failed(let detail) = service.state { actionError = detail }
            return
        }
        guard let index = productionIndex, let candidate = fileCandidate(for: result) else {
            actionError = "O resultado não está mais disponível. Pesquise novamente."
            return
        }
        do {
            let url = try await index.resolveForPreview(candidate.file)
            defer { url.stopAccessingSecurityScopedResource() }
            switch action {
            case .open:
                guard NSWorkspace.shared.open(url) else { throw FileIndexError.unsupportedDocument }
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch { actionError = "Não foi possível acessar o arquivo. Ele pode ter sido movido ou a permissão expirou. Escolha a pasta novamente e atualize o índice." }
    }

}

typealias LocalUnifiedSearchViewModel = PavlakOrchestrator

enum LocalSearchText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
#endif

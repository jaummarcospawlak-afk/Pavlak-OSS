#if os(macOS)
import Foundation

@MainActor
final class FileRecoveryViewModel: ObservableObject {
    enum Phase: Equatable { case idle, searching, candidates, reading, finished, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [FileSearchCandidate] = []
    @Published var selectedID: String?
    @Published private(set) var summary = ""

    let index: FileIndexService
    private let summarizer: any DocumentSummarizer
    var summarizerName: String { summarizer.name }
    var isActive: Bool { phase != .idle }

    init(summarizer: (any DocumentSummarizer)? = nil, index: FileIndexService? = nil) {
        self.summarizer = summarizer ?? DocumentSummarizerFactory.make()
        self.index = index ?? FileIndexService()
    }

    func receive(_ request: RemoteFileRequest) {
        phase = .searching; summary = ""
        candidates = index.search(command: request.command)
        selectedID = candidates.first?.id
        phase = candidates.isEmpty ? .failed("Nenhum contrato compatível foi localizado nas pastas autorizadas.") : .candidates
    }

    func summarizeSelected() {
        guard let candidate = candidates.first(where: { $0.id == selectedID }) else { return }
        phase = .reading
        Task {
            do {
                let text = try await index.extractText(from: candidate)
                summary = try await summarizer.summarize(title: candidate.file.name, text: text)
                phase = .finished
            } catch {
                phase = .failed(error.localizedDescription)
                PavlakErrorReporter.shared.report(module: "FileRecovery", action: "ler_e_resumir", message: "Não foi possível processar o arquivo selecionado.", error: error, result: "erro_recuperado")
            }
        }
    }

    func handleLink(_ message: PavlakLinkMessage) async -> PavlakLinkMessage {
        await index.reload()
        let sourceDeviceID = PavlakLinkDeviceIdentity.loadOrCreate()
        guard let query = LocalUnifiedSearchQuery.recognize(message.query)
                ?? LocalUnifiedSearchQuery.recognize("Encontre " + message.query) else {
            return message.response(status: .failure, result: "Descreva o documento que deseja localizar.")
        }
        let response = await PavlakFileSearchProvider(index: index).search(query)
        if case .blocked(let detail) = response.status {
            return message.response(status: .failure, result: detail)
        }
        let scoped = await index.authorizedSnapshot()
        let ranked = LocalUnifiedSearchRanker.rank(query: query, records: response.records)
        let found = ranked.compactMap { result -> PavlakLinkFileCandidate? in
            guard let file = scoped.files.first(where: { $0.id == result.sourceID }) else { return nil }
            let stableID = PavlakLinkDeviceIdentity.stableID(deviceID: sourceDeviceID, localID: file.id)
            return PavlakLinkFileCandidate(stableID: stableID, fileID: file.id,
                                    sourceDeviceID: sourceDeviceID, sourceDevice: .mac,
                                    sourceLocation: scoped.rootNamesByID[file.rootID] ?? "Pasta autorizada no Mac",
                                    score: result.score.total, name: file.name,
                                    relativePath: file.relativePath, fileExtension: file.fileExtension,
                                    modifiedAt: file.modifiedAt,
                                    evidenceSummary: result.reason)
        }
        do {
            let data = try JSONEncoder().encode(Array(found))
            return message.response(status: .success, result: String(data: data, encoding: .utf8))
        } catch {
            PavlakErrorReporter.shared.report(module: "FileRecovery", action: "responder_busca_remota", message: "Não foi possível preparar o resultado remoto.", error: error, result: "erro_recuperado")
            return message.response(status: .failure, result: error.localizedDescription)
        }
    }

    func reset() { phase = .idle; candidates = []; selectedID = nil; summary = "" }
}
#endif

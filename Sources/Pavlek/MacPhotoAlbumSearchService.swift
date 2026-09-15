#if os(macOS)
import AppKit
import Foundation
@preconcurrency import Photos
@preconcurrency import Vision

struct MacPhotoSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let albumTitle: String
    let filename: String?
    let creationDate: Date?
    let score: Int
    let recognizedText: String
}

enum MacPhotoSearchConsultation: Equatable, Sendable {
    case consulted
    case partial(String)
    case blocked(String)
    case albumUnavailable(String)
    case failed(String)
}

private struct SendablePhotoImage: @unchecked Sendable { let value: NSImage? }
private struct SendableCGImage: @unchecked Sendable { let value: CGImage }

enum PhotoAlbumRequest {
    static func name(from command: String) -> String {
        let pattern = #"(?i)\b[áa]lbu(?:m|ns)(?:\s+chamad[oa]s?)?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return "Documentos" }
        var value = String(command[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoted names are literal; unquoted requests can include a connecting preposition.
        if !["\"", "“", "'", "‘"].contains(where: value.hasPrefix) {
            value = value.replacingOccurrences(of: #"(?i)^(?:de|do|da|dos|das)\s+"#,
                                               with: "", options: .regularExpression)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.isEmpty ? "Documentos" : value
    }

    static func isTrips(_ name: String) -> Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: Locale(identifier: "pt_BR"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["viagens", "viajens"].contains(normalized)
    }

    static func unavailableMessage(for name: String) -> String {
        if isTrips(name) {
            return "Não encontrei um álbum com esse nome. Se você procura a coleção automática Viagens, abra Fotos › Coleções › Viagens. Essa coleção ainda não é consultada pela busca do Pavlak."
        }
        return "Não encontrei o álbum “\(name)” entre os álbuns acessíveis. Confira o nome no Fotos; coleções automáticas podem não aparecer nesta busca."
    }
}

private enum PhotoTextRecognizer {
    static func recognize(_ image: CGImage) async -> String {
        let wrapped = SendableCGImage(value: image)
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["pt-BR"]
            do {
                try VNImageRequestHandler(cgImage: wrapped.value).perform([request])
                return request.results?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ") ?? ""
            } catch {
                return ""
            }
        }.value
    }
}

@MainActor
final class MacPhotoAlbumSearchService: ObservableObject {
    enum State: Equatable { case idle, searching, results, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var results: [MacPhotoSearchResult] = []
    @Published private(set) var selected: MacPhotoSearchResult?
    @Published private(set) var selectedImage: NSImage?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var searchedAlbumName = ""
    @Published private(set) var skippedAssetCount = 0

    private let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]
    private var ocrCache: [String: (Date?, String)] = [:]
    private var exportedURLs: [String: URL] = [:]

    func searchIdentity(inAlbum albumName: String = "Documentos") async {
        await search(query: "RG", inAlbum: albumName)
    }

    func search(query: String, inAlbum albumName: String? = nil) async {
        _ = await performSearch(query: query, inAlbum: albumName, requestAuthorizationIfNeeded: true)
    }

    /// Consulta destinada à busca local unificada. Nunca apresenta um novo prompt do macOS.
    func searchAlreadyAuthorized(query: String, inAlbum albumName: String? = nil) async -> MacPhotoSearchConsultation {
        await performSearch(query: query, inAlbum: albumName, requestAuthorizationIfNeeded: false)
    }

    func clearResults() {
        state = .idle
        results = []
        selected = nil
        selectedImage = nil
        thumbnails = [:]
        assets = [:]
        exportedURLs = [:]
        searchedAlbumName = ""
        skippedAssetCount = 0
    }

    private func performSearch(
        query: String,
        inAlbum albumName: String?,
        requestAuthorizationIfNeeded: Bool
    ) async -> MacPhotoSearchConsultation {
        searchedAlbumName = albumName ?? "Todas as Fotos"
        state = .searching
        results = []
        selected = nil
        selectedImage = nil
        thumbnails = [:]
        assets = [:]
        exportedURLs = [:]
        skippedAssetCount = 0

        var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined && requestAuthorizationIfNeeded {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else {
            let message: String
            if requestAuthorizationIfNeeded {
                message = "O acesso às Fotos é necessário. Abra Ajustes do Sistema › Privacidade e Segurança › Fotos e autorize o Pavlak."
            } else if authorization == .notDetermined {
                message = "Fotos não foi consultada porque ainda não há autorização; nenhum prompt foi aberto"
            } else {
                message = "Fotos não foi consultada porque o acesso não está autorizado"
            }
            state = .failed(message)
            return .blocked(message)
        }
        let accessible = PHAsset.fetchAssets(with: nil)
        var visibleIDs = Set<String>()
        accessible.enumerateObjects { asset, _, _ in visibleIDs.insert(asset.localIdentifier) }
        ocrCache = ocrCache.filter { visibleIDs.contains($0.key) }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let collection: PHAssetCollection?
        if let albumName {
            guard let found = findAlbum(named: albumName) else {
                let message = PhotoAlbumRequest.unavailableMessage(for: albumName)
                state = .failed(message)
                return .albumUnavailable(message)
            }
            collection = found
        } else { collection = nil }
        let fetched = collection.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)
        var albumAssets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in albumAssets.append(asset) }

        var found: [MacPhotoSearchResult] = []
        let normalizedQuery = normalize(query)
        for asset in albumAssets {
            guard !Task.isCancelled else { return .partial("Consulta interrompida por um novo pedido.") }
            assets[asset.localIdentifier] = asset
            let cached = ocrCache[asset.localIdentifier]
            let text: String
            if let cached, let modified = asset.modificationDate, cached.0 == modified, !normalizedQuery.isEmpty {
                text = cached.1
            } else {
            guard let image = await requestImage(asset, size: CGSize(width: normalizedQuery.isEmpty ? 360 : 1800, height: normalizedQuery.isEmpty ? 360 : 1800), networkAllowed: requestAuthorizationIfNeeded) else {
                skippedAssetCount += 1
                continue
            }
            thumbnails[asset.localIdentifier] = image
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
            if normalizedQuery.isEmpty {
                found.append(MacPhotoSearchResult(
                    id: asset.localIdentifier, albumTitle: collection?.localizedTitle ?? albumName ?? "Todas as Fotos",
                    filename: filename, creationDate: asset.creationDate, score: 1, recognizedText: ""
                ))
                continue
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            text = await PhotoTextRecognizer.recognize(cgImage)
            guard !Task.isCancelled else { return .partial("Consulta interrompida por um novo pedido.") }
            ocrCache[asset.localIdentifier] = (asset.modificationDate, text)
            }
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
            let searchable = normalize([filename, text].compactMap { $0 }.joined(separator: " "))
            let score = relevanceScore(searchable, query: query)
            if score > 0 {
                var memberships: [String] = []
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { album, _, _ in
                    if let title = album.localizedTitle { memberships.append(title) }
                }
                found.append(MacPhotoSearchResult(
                    id: asset.localIdentifier, albumTitle: collection?.localizedTitle ?? (memberships.isEmpty ? "Fototeca autorizada" : memberships.joined(separator: " • ")),
                    filename: filename, creationDate: asset.creationDate, score: score,
                    recognizedText: String(text.prefix(80_000))
                ))
            }
        }
        results = found.sorted { $0.score == $1.score ? ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) : $0.score > $1.score }
        state = .results
        if skippedAssetCount > 0 {
            let noun = skippedAssetCount == 1 ? "imagem" : "imagens"
            let predicate = skippedAssetCount == 1 ? "não pôde ser lida" : "não puderam ser lidas"
            return .partial("álbum consultado parcialmente; \(skippedAssetCount) \(noun) \(predicate)")
        }
        return .consulted
    }

    func select(_ result: MacPhotoSearchResult) async {
        selected = result
        guard let asset = assets[result.id] else { return }
        selectedImage = await requestImage(asset, size: CGSize(width: 1800, height: 1800), networkAllowed: true)
    }

    func openFirstResult() async {
        guard let first = results.first else { return }
        await select(first)
    }

    func open(resultID: String) async throws {
        guard let result = results.first(where: { $0.id == resultID }) else { throw PhotoSearchError.unknownResult }
        await open(result)
    }

    func open(_ result: MacPhotoSearchResult) async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              PHAsset.fetchAssets(withLocalIdentifiers: [result.id], options: nil).firstObject != nil else {
            state = .failed("A foto não está mais no escopo autorizado.")
            return
        }
        await select(result)
        guard let asset = assets[result.id], let resource = PHAssetResource.assetResources(for: asset).first else {
            state = .failed("A foto selecionada não está mais disponível.")
            return
        }
        do {
            let url: URL
            if let existing = exportedURLs[result.id], FileManager.default.fileExists(atPath: existing.path) {
                url = existing
            } else {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pavlak-Photos", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let safeName = (result.filename ?? resource.originalFilename).replacingOccurrences(of: "/", with: "-")
                url = folder.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
                try await export(resource, to: url)
                exportedURLs[result.id] = url
            }
            guard NSWorkspace.shared.open(url) else { throw PhotoOpenError.couldNotOpen }
        } catch {
            state = .failed("Não foi possível abrir a foto selecionada.")
            PavlakErrorReporter.shared.report(module: "PhotoSearch", action: "abrir_foto", message: "A foto selecionada não pôde ser aberta.", error: error, result: "erro_recuperado")
        }
    }

    func shareSelected(from view: NSView?) {
        guard let selectedImage, let view else { return }
        NSSharingServicePicker(items: [selectedImage]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func findAlbum(named name: String) -> PHAssetCollection? {
        let wanted = normalize(name)
        var best: (PHAssetCollection, Int)?
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let fetched = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle else { return }
                let candidate = self.normalize(title)
                // Prefer a literal album title, including a user-created title with a typo.
                let score = candidate == wanted ? 100
                    : (PhotoAlbumRequest.isTrips(wanted) && candidate == "viagens" ? 90
                       : (candidate.contains(wanted) ? 70 : 0))
                if score > (best?.1 ?? 0) { best = (collection, score) }
            }
        }
        return best?.0
    }

    private func requestImage(_ asset: PHAsset, size: CGSize, networkAllowed: Bool) async -> NSImage? {
        let wrapped: SendablePhotoImage = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = networkAllowed
            var completed = false
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                guard !completed, !degraded || cancelled || failed else { return }
                completed = true
                continuation.resume(returning: SendablePhotoImage(value: image))
            }
        }
        return wrapped.value
    }

    private func export(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func identityScore(_ text: String) -> Int {
        let weighted = ["registro geral": 18, "carteira de identidade": 18, "identidade": 12, "rg": 10, "cpf": 5, "republica federativa": 7, "secretaria de seguranca": 8]
        return weighted.reduce(0) { $0 + (text.contains($1.key) ? $1.value : 0) }
    }

    private func relevanceScore(_ text: String, query: String) -> Int {
        let normalizedQuery = normalize(query)
        if normalizedQuery == "rg" || normalizedQuery.contains("identidade") { return identityScore(text) }
        let ignored = Set(["procure", "buscar", "busque", "foto", "fotos", "minha", "meu", "nas", "nos"])
        let terms = normalizedQuery.split(separator: " ").map(String.init).filter { $0.count > 2 && !ignored.contains($0) }
        return terms.reduce(0) { $0 + (text.contains($1) ? 10 : 0) }
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private enum PhotoOpenError: Error { case couldNotOpen }
private enum PhotoSearchError: Error { case unknownResult }
#endif

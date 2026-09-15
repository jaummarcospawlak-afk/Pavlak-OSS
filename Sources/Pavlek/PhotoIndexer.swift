#if os(iOS)
import Foundation
import Photos
import Security
@preconcurrency import Vision
import UIKit

@MainActor
final class PhotoIndexer: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorizationState: PhotoAuthorizationState = .notDetermined
    @Published private(set) var isIndexing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var snapshot = PhotoIndexSnapshot()
    @Published private(set) var lastReport: IndexRunReport?
    @Published private(set) var errorMessage: String?
    @Published private(set) var spotlightSelection: PhotoSearchMatch?

    private let deviceID: String
    private let store: PhotoIndexStore
    private let spotlight = PhotoSpotlightIndex()
    private var libraryFetchResult: PHFetchResult<PHAsset>?
    private var incrementalTask: Task<Void, Never>?
    private var refreshRequestedWhileIndexing = false

    override init() {
        let identity = Self.deviceIdentifier()
        deviceID = identity
        store = PhotoIndexStore(deviceID: identity)
        super.init()
        refreshAuthorization()
        PHPhotoLibrary.shared().register(self)
        Task {
            await reconcileAuthorization()
        }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func refreshAuthorization() {
        authorizationState = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        errorMessage = nil
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        authorizationState = Self.map(status)
        if authorizationState.canRead {
            await indexNewAssets(isInitial: snapshot.assets.isEmpty)
        } else {
            await reconcileAuthorization()
            errorMessage = PhotoIndexError.accessDenied.localizedDescription
        }
    }

    func applicationDidBecomeActive() async {
        refreshAuthorization()
        if authorizationState.canRead { await indexNewAssets(isInitial: snapshot.assets.isEmpty) }
        else { await reconcileAuthorization() }
    }

    func indexNewAssets(isInitial: Bool = false) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let scope = Self.scope(status)
        authorizationState = Self.map(status)
        guard scope.canRead else {
            await reconcileAuthorization()
            return
        }
        guard !isIndexing else {
            refreshRequestedWhileIndexing = true
            return
        }
        isIndexing = true; progress = 0; errorMessage = nil
        defer {
            isIndexing = false
            if refreshRequestedWhileIndexing {
                refreshRequestedWhileIndexing = false
                Task { await indexNewAssets() }
            }
        }
        let started = ContinuousClock.now

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(with: options)
        libraryFetchResult = fetched
        let albums = albumAssociations()
        let currentSnapshot = await store.currentSnapshot()
        let existing = Dictionary(uniqueKeysWithValues: currentSnapshot.assets.map { ($0.sourceLocalIdentifier, $0) })
        var visible = Set<String>()
        var work: [(PHAsset, String?, String, [PhotoAlbumAssociationEvidence])] = []
        var newCount = 0
        var changedCount = 0

        fetched.enumerateObjects { asset, _, _ in
            let localID = asset.localIdentifier
            visible.insert(localID)
            let resource = PHAssetResource.assetResources(for: asset).first
            let filename = resource?.originalFilename
            let associations = albums[localID] ?? []
            let fingerprint = Self.fingerprint(asset: asset, filename: filename, contentType: resource?.uniformTypeIdentifier, albums: associations)
            if let old = existing[localID] {
                if old.sourceFingerprint != fingerprint || old.processingState == .interrupted || old.processingState == .failed {
                    changedCount += 1
                    work.append((asset, filename, fingerprint, associations))
                }
            } else {
                newCount += 1
                work.append((asset, filename, fingerprint, associations))
            }
        }

        let placeholders = work.map { processingPlaceholder(asset: $0.0, filename: $0.1, fingerprint: $0.2, albums: $0.3) }
        do {
            try await store.beginUpdate(
                placeholders: placeholders,
                visibleSourceIdentifiers: visible,
                authorization: scope
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        var completed: [IndexedPhoto] = []
        for (offset, entry) in work.enumerated() {
            guard !Task.isCancelled else { break }
            guard Self.scope(PHPhotoLibrary.authorizationStatus(for: .readWrite)) == scope else {
                await reconcileAuthorization()
                return
            }
            completed.append(await index(asset: entry.0, filename: entry.1, fingerprint: entry.2, albums: entry.3))
            progress = work.isEmpty ? 1 : Double(offset + 1) / Double(work.count)
            if completed.count >= 25 {
                try? await store.beginUpdate(
                    placeholders: completed,
                    visibleSourceIdentifiers: visible,
                    authorization: scope
                )
                completed.removeAll(keepingCapacity: true)
            }
        }

        guard !Task.isCancelled else {
            snapshot = await store.currentSnapshot()
            return
        }
        guard Self.scope(PHPhotoLibrary.authorizationStatus(for: .readWrite)) == scope else {
            await reconcileAuthorization()
            return
        }
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        do {
            let removed = try await store.completeUpdate(
                records: completed,
                visibleSourceIdentifiers: visible,
                authorization: scope,
                duration: isInitial ? seconds : nil
            )
            snapshot = await store.currentSnapshot()
            await rebuildSpotlight()
            lastReport = IndexRunReport(
                visibleAssetCount: fetched.count, newlyIndexedCount: newCount,
                changedAssetCount: changedCount, removedAssetCount: removed,
                documentCount: snapshot.documentCount, pendingCloudCount: snapshot.pendingContentCount,
                elapsed: seconds, indexByteCount: await store.byteCount(), authorizationScope: scope
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func searchEnergyBill() async -> [PhotoSearchMatch] {
        guard await prepareForSearch() else { return [] }
        return currentlyAccessible(PhotoIndexQueryEngine.search(
            query: "conta de energia",
            in: snapshot
        ))
    }

    func search(query: String) async -> [PhotoSearchMatch] {
        guard await prepareForSearch() else { return [] }
        return currentlyAccessible(PhotoIndexQueryEngine.search(query: query, in: snapshot))
    }

    func handleSpotlightSelection(stableID: String) async {
        guard await prepareForSearch(),
              let match = PhotoIndexQueryEngine.match(stableID: stableID, in: snapshot),
              currentlyAccessible([match]).count == 1 else {
            errorMessage = "O item do Spotlight não está mais disponível no escopo autorizado."
            spotlightSelection = nil
            return
        }
        spotlightSelection = match
    }

    /// Explicit user action: this is the only path that allows an iCloud download for indexed content.
    func makeContentAvailable(for match: PhotoSearchMatch) async {
        guard match.processingState == .waitingForLocalContent,
              await validate(match: match, expectedState: .waitingForLocalContent) else { return }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [match.sourceLocalIdentifier], options: nil)
        guard let asset = fetched.firstObject else { return }
        let resource = PHAssetResource.assetResources(for: asset).first
        let associations = albumAssociations()[asset.localIdentifier] ?? []
        let fingerprint = Self.fingerprint(asset: asset, filename: resource?.originalFilename, contentType: resource?.uniformTypeIdentifier, albums: associations)
        let record = await index(asset: asset, filename: resource?.originalFilename, fingerprint: fingerprint, albums: associations, networkAllowed: true)
        let visible = Set(snapshot.assets.map(\.sourceLocalIdentifier)).union([asset.localIdentifier])
        do {
            _ = try await store.completeUpdate(records: [record], visibleSourceIdentifiers: visible, authorization: Self.scope(PHPhotoLibrary.authorizationStatus(for: .readWrite)), duration: nil)
            snapshot = await store.currentSnapshot()
            await rebuildSpotlight()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Revalidates both the current PhotoKit scope and the exact committed index generation
    /// immediately before a preview/share action.
    func validateForAction(_ match: PhotoSearchMatch) async -> Bool {
        await validate(match: match, expectedState: .processed)
    }

    func handleLink(_ message: PavlakLinkMessage) async -> PavlakLinkMessage {
        guard message.action == .photoSearch, message.sourceDevice == .mac, message.targetDevice == .iPhone else {
            return message.response(status: .failure, result: "Rota de consulta inválida.")
        }
        let matches = await search(query: message.query).prefix(8).map {
            PavlakLinkPhotoCandidate(
                stableID: $0.id, sourceLocalIdentifier: $0.sourceLocalIdentifier,
                sourceDeviceID: $0.sourceDeviceID, sourceDevice: $0.sourceDevice,
                sourceKind: $0.sourceKind.rawValue, sourceLocation: "Fotos no iPhone",
                score: $0.score, date: $0.date, filename: $0.filename,
                textPreview: $0.textPreview, processingState: $0.processingState.rawValue,
                evidenceSummary: $0.evidenceSummary
            )
        }
        do {
            let data = try JSONEncoder().encode(Array(matches))
            return message.response(status: .success, result: String(data: data, encoding: .utf8))
        } catch {
            return message.response(status: .failure, result: "Não foi possível codificar os resultados do índice do iPhone.")
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            incrementalTask?.cancel()
            incrementalTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await indexNewAssets()
            }
        }
    }

    private func reconcileAuthorization() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let scope = Self.scope(status)
        do {
            let visible = scope == .limited ? currentlyVisiblePhotoIdentifiers() : nil
            try await store.applyAuthorization(scope, visibleSourceIdentifiers: visible)
            snapshot = await store.currentSnapshot()
            if !scope.canRead {
                libraryFetchResult = nil
                lastReport = nil
                spotlightSelection = nil
                await rebuildSpotlight()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshSnapshot() async { snapshot = await store.currentSnapshot() }

    private func prepareForSearch() async -> Bool {
        let scope = Self.scope(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard scope.canRead else {
            await reconcileAuthorization()
            errorMessage = PhotoIndexError.accessDenied.localizedDescription
            return false
        }
        await refreshSnapshot()
        guard snapshot.authorizationScope == scope else {
            await reconcileAuthorization()
            return false
        }
        return true
    }

    private func validate(match: PhotoSearchMatch, expectedState: PhotoProcessingState) async -> Bool {
        guard await prepareForSearch(),
              snapshot.generation == match.indexGeneration,
              snapshot.authorizationScope == match.authorizationScope,
              let current = snapshot.assets.first(where: { $0.id == match.id }),
              current.sourceLocalIdentifier == match.sourceLocalIdentifier,
              current.sourceFingerprint == match.sourceFingerprint,
              current.processingState == expectedState else {
            errorMessage = "O resultado mudou ou saiu do escopo autorizado. Faça a busca novamente."
            return false
        }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [match.sourceLocalIdentifier], options: nil)
        guard fetched.firstObject != nil else {
            refreshRequestedWhileIndexing = true
            errorMessage = "O item não está mais disponível no escopo autorizado. Atualize o índice."
            return false
        }
        return true
    }

    private func currentlyAccessible(_ matches: [PhotoSearchMatch]) -> [PhotoSearchMatch] {
        guard !matches.isEmpty else { return [] }
        let identifiers = matches.map(\.sourceLocalIdentifier)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var accessible = Set<String>()
        fetched.enumerateObjects { asset, _, _ in accessible.insert(asset.localIdentifier) }
        return matches.filter { accessible.contains($0.sourceLocalIdentifier) }
    }

    private func currentlyVisiblePhotoIdentifiers() -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetched = PHAsset.fetchAssets(with: options)
        var visible = Set<String>()
        fetched.enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
        return visible
    }

    private func rebuildSpotlight() async {
        do { try await spotlight.rebuild(from: snapshot) }
        catch {
            errorMessage = "O índice principal foi preservado, mas a projeção do Core Spotlight não pôde ser reconstruída: \(error.localizedDescription)"
        }
    }

    private func processingPlaceholder(asset: PHAsset, filename: String?, fingerprint: String, albums: [PhotoAlbumAssociationEvidence]) -> IndexedPhoto {
        metadata(asset: asset, filename: filename, fingerprint: fingerprint, albums: albums,
                 category: .unknown, normalizedText: "", extracted: nil, classification: nil,
                 availability: .unavailable, state: .processing)
    }

    private func index(asset: PHAsset, filename: String?, fingerprint: String, albums: [PhotoAlbumAssociationEvidence], networkAllowed: Bool = false) async -> IndexedPhoto {
        let imageResult = await requestThumbnail(for: asset, networkAllowed: networkAllowed)
        guard case .image(let image) = imageResult else {
            let availability: PhotoContentAvailability = imageResult == .notLocal ? .cloudOnly : .unavailable
            let state: PhotoProcessingState = imageResult == .notLocal ? .waitingForLocalContent : .failed
            return metadata(asset: asset, filename: filename, fingerprint: fingerprint, albums: albums,
                            category: imageResult == .notLocal ? .pendingCloud : .unknown,
                            normalizedText: "", extracted: nil, classification: nil,
                            availability: availability, state: state,
                            error: imageResult == .notLocal ? "Conteúdo ainda não disponível localmente." : "Imagem indisponível para processamento.")
        }
        let now = Date()
        // OCR covers every authorized, locally readable image, including cropped documents
        // and screenshots without a detectable page outline. It uses a 1200px rendition.
        let text: String
        do { text = try await Self.recognizeText(in: image) }
        catch {
            return metadata(asset: asset, filename: filename, fingerprint: fingerprint, albums: albums,
                            category: .unknown, normalizedText: "", extracted: nil, classification: nil,
                            availability: .local, state: .failed, error: "Falha no OCR local; tente atualizar o índice.")
        }
        let normalized = Self.normalize(text)
        let candidateKind = PhotoDocumentQuery.Kind.allCases.first { kind in
            kind.contentSignals.contains { PhotoDocumentQuery.contains(normalized, phrase: $0) }
        }
        let category: IndexedPhotoCategory = candidateKind == nil ? .other : .document
        let extracted = PhotoExtractedTextEvidence(text: text, normalizedText: normalized,
            extractor: "Vision OCR v3 — linhas preservadas; imagem até 1200 px", extractedAt: now)
        // No numeric confidence is invented for these lexical hints.
        return metadata(asset: asset, filename: filename, fingerprint: fingerprint, albums: albums,
                        category: category, normalizedText: normalized, extracted: extracted,
                        classification: nil, availability: .local, state: .processed)
    }

    private func metadata(
        asset: PHAsset, filename: String?, fingerprint: String, albums: [PhotoAlbumAssociationEvidence],
        category: IndexedPhotoCategory, normalizedText: String,
        extracted: PhotoExtractedTextEvidence?, classification: PhotoClassificationEvidence?,
        availability: PhotoContentAvailability, state: PhotoProcessingState, error: String? = nil
    ) -> IndexedPhoto {
        let now = Date()
        let resource = PHAssetResource.assetResources(for: asset).first
        return IndexedPhoto(
            id: PhotoStableIdentifier.make(deviceID: deviceID, assetLocalIdentifier: asset.localIdentifier),
            sourceLocalIdentifier: asset.localIdentifier, sourceDeviceID: deviceID,
            contentType: resource?.uniformTypeIdentifier ?? "public.image",
            creationDate: asset.creationDate, modificationDate: asset.modificationDate,
            width: asset.pixelWidth, height: asset.pixelHeight, originalFilename: filename,
            albumAssociations: albums,
            originalEvidence: .init(provider: "PhotoKit", observedAt: now, assetLocalIdentifier: asset.localIdentifier),
            category: category, normalizedOCRText: normalizedText,
            extractedTextEvidence: extracted, classificationEvidence: classification,
            contentAvailability: availability, processingState: state,
            processingError: error, indexedAt: now, sourceFingerprint: fingerprint
        )
    }

    private func albumAssociations() -> [String: [PhotoAlbumAssociationEvidence]] {
        var output: [String: [PhotoAlbumAssociationEvidence]] = [:]
        let observedAt = Date()
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle else { return }
                let evidence = PhotoAlbumAssociationEvidence(
                    albumLocalIdentifier: collection.localIdentifier, title: title,
                    observedAt: observedAt, provider: "PhotoKit"
                )
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    output[asset.localIdentifier, default: []].append(evidence)
                }
            }
        }
        return output
    }

    private enum ImageAvailability: Equatable {
        case image(CGImage), notLocal, unavailable
        static func == (lhs: ImageAvailability, rhs: ImageAvailability) -> Bool {
            switch (lhs, rhs) {
            case (.image, .image), (.notLocal, .notLocal), (.unavailable, .unavailable): true
            default: false
            }
        }
    }

    private func requestThumbnail(for asset: PHAsset, networkAllowed: Bool) async -> ImageAvailability {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = networkAllowed
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                if let image = image?.cgImage { continuation.resume(returning: .image(image)) }
                else if (info?[PHImageResultIsInCloudKey] as? Bool) == true { continuation.resume(returning: .notLocal) }
                else { continuation.resume(returning: .unavailable) }
            }
        }
    }

    nonisolated private static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["pt-BR", "en-US"]
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                    continuation.resume(returning: text)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func fingerprint(asset: PHAsset, filename: String?, contentType: String?, albums: [PhotoAlbumAssociationEvidence]) -> String {
        let values = [
            "ocr-all-images-lines-v3", // Refresh prior contour-gated OCR without promoting legacy text.
            asset.localIdentifier, filename ?? "", contentType ?? "", String(asset.pixelWidth), String(asset.pixelHeight),
            asset.creationDate?.ISO8601Format() ?? "", asset.modificationDate?.ISO8601Format() ?? "",
            albums.map { "\($0.albumLocalIdentifier)=\($0.title)" }.sorted().joined(separator: ",")
        ].joined(separator: "\u{1f}")
        return String(values.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    nonisolated private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    nonisolated private static func scope(_ status: PHAuthorizationStatus) -> PhotoIndexAuthorizationScope {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    private static func deviceIdentifier() -> String {
        let defaultsKey = "Pavlak.photoIndex.deviceID.v1"
        let keychainService = "com.pavlak.photo-index.identity"
        let keychainAccount = "source-device-id-v1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            UserDefaults.standard.set(existing, forKey: defaultsKey)
            return existing
        }

        // Preserve identifiers created by earlier builds before promoting them to Keychain.
        let created = UserDefaults.standard.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? UIDevice.current.identifierForVendor?.uuidString
            ?? UUID().uuidString
        var insert = query
        insert.removeValue(forKey: kSecReturnData as String)
        insert.removeValue(forKey: kSecMatchLimit as String)
        insert[kSecValueData as String] = Data(created.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(insert as CFDictionary, nil)
        UserDefaults.standard.set(created, forKey: defaultsKey)
        return created
    }
}
#endif

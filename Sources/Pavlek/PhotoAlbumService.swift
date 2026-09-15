#if os(iOS)
import Foundation
@preconcurrency import Photos
import UIKit

struct PhotoAlbumMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let itemCount: Int
    let coverAssetIdentifier: String?
    let score: Int
}

@MainActor
final class PhotoAlbumService: ObservableObject {
    @Published private(set) var matches: [PhotoAlbumMatch] = []
    @Published private(set) var albumAssets: [PHAsset] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var collections: [String: PHAssetCollection] = [:]
    private let imageManager = PHCachingImageManager()

    func search(command: String) {
        errorMessage = nil
        matches = []
        albumAssets = []

        guard Self.canReadPhotos else {
            errorMessage = "Autorize o acesso às Fotos para localizar álbuns."
            return
        }

        isSearching = true
        let query = Self.albumName(from: command)
        var found: [PhotoAlbumMatch] = []
        collections.removeAll()

        let types: [PHAssetCollectionType] = [.album, .smartAlbum]
        for type in types {
            let fetched = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle, !title.isEmpty else { return }
                let score = Self.score(title: title, query: query)
                guard score > 0 else { return }
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                let coverID = assets.lastObject?.localIdentifier
                let match = PhotoAlbumMatch(
                    id: collection.localIdentifier,
                    title: title,
                    itemCount: assets.count,
                    coverAssetIdentifier: coverID,
                    score: score
                )
                found.append(match)
                self.collections[match.id] = collection
            }
        }

        matches = found.sorted {
            if $0.score == $1.score { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.score > $1.score
        }
        isSearching = false
    }

    func clearResults() {
        matches = []
        albumAssets = []
        errorMessage = nil
    }

    func open(_ album: PhotoAlbumMatch) {
        errorMessage = nil
        guard let collection = collections[album.id] else {
            errorMessage = "O álbum não está mais disponível."
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }
        albumAssets = loaded
    }

    func image(
        for asset: PHAsset,
        size: CGSize,
        delivery: PHImageRequestOptionsDeliveryMode = .opportunistic,
        networkAllowed: Bool = true
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = delivery
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = networkAllowed
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                guard !resumed, !degraded || cancelled || hasError else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    func imagesForSharing(assetIDs: Set<String>) async -> [UIImage] {
        let selected = albumAssets.filter { assetIDs.contains($0.localIdentifier) }
        var images: [UIImage] = []
        for asset in selected {
            if let image = await image(
                for: asset,
                size: CGSize(width: max(asset.pixelWidth, 1), height: max(asset.pixelHeight, 1)),
                delivery: .highQualityFormat
            ) {
                images.append(image)
            }
        }
        return images
    }

    static var canReadPhotos: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    private static func albumName(from command: String) -> String {
        var value = normalize(command)
        let ignored = ["pavlak", "localize", "encontre", "procure", "o", "a", "album", "minha", "galeria", "fototeca", "de", "fotos", "foto"]
        for word in ignored {
            value = value.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", with: " ", options: .regularExpression)
        }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func score(title: String, query: String) -> Int {
        let candidate = normalize(title)
        guard !query.isEmpty else { return 1 }
        if candidate == query { return 100 }
        if candidate.contains(query) { return 80 }
        if query.contains(candidate), candidate.count >= 3 { return 65 }
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let titleTokens = Set(candidate.split(separator: " ").map(String.init))
        let common = queryTokens.intersection(titleTokens).count
        return common == 0 ? 0 : 30 + common * 10
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
#endif

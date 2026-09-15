#if os(iOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Disposable projection of PhotoIndexStore. Search never treats Spotlight as authoritative.
actor PhotoSpotlightIndex {
    static let domainIdentifier = "com.pavlek.photo-index.v2"
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) { self.index = index }

    func rebuild(from snapshot: PhotoIndexSnapshot) async throws {
        try await deleteDomain()
        let items = snapshot.assets
            .filter { $0.processingState == .processed }
            .map { record -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .image)
                attributes.title = record.originalFilename ?? "Foto"
                attributes.textContent = record.extractedTextEvidence?.text
                attributes.contentDescription = "Foto em \(record.sourceDevice.rawValue); categoria inferida: \(record.category.rawValue)"
                attributes.keywords = record.albumAssociations.map(\.title) + [record.category.rawValue]
                attributes.contentCreationDate = record.creationDate
                let item = CSSearchableItem(
                    uniqueIdentifier: record.id,
                    domainIdentifier: Self.domainIdentifier,
                    attributeSet: attributes
                )
                item.expirationDate = .distantFuture
                return item
            }
        guard !items.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func deleteDomain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
#endif

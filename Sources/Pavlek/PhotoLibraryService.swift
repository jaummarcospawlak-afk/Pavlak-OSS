import Foundation
import Photos

enum PhotoAuthorizationState: Equatable, Sendable {
    case notDetermined, denied, restricted, limited, authorized

    var title: String {
        switch self {
        case .notDetermined: "Não solicitado"
        case .denied: "Negado"
        case .restricted: "Restrito"
        case .limited: "Acesso limitado"
        case .authorized: "Autorizado"
        }
    }

    var symbol: String {
        switch self {
        case .authorized, .limited: "checkmark.circle.fill"
        case .notDetermined: "questionmark.circle"
        case .denied, .restricted: "xmark.circle.fill"
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }

    static func title(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Não solicitado"
        case .denied: "Negado"
        case .restricted: "Restrito"
        case .limited: "Acesso limitado"
        case .authorized: "Autorizado"
        @unknown default: "Indisponível"
        }
    }
}

@MainActor
final class PhotoLibraryService: ObservableObject {
    @Published private(set) var authorizationState: PhotoAuthorizationState
    @Published private(set) var accessibleItemCount: Int?
    @Published private(set) var lastError: String?

    init() {
        authorizationState = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func refreshAuthorization() {
        authorizationState = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestReadAccess() async -> PhotoAuthorizationState {
        lastError = nil
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else {
            let mapped = Self.map(current)
            authorizationState = mapped
            return mapped
        }
        let reporter = PavlakErrorReporter.shared
        let operation = reporter.begin(module: "PhotoLibraryService", action: "solicitar_autorizacao_fototeca")
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        reporter.finish(operation, result: Self.map(status).title)
        let mapped = Self.map(status)
        authorizationState = mapped
        return mapped
    }

    func locatePhotos(period: String, sampleLimit: Int = 12) throws -> PhotoQueryResult {
        lastError = nil
        let current = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        authorizationState = current
        guard current.canRead else {
            let error = AgentError.permissionDenied
            lastError = error.localizedDescription
            PavlakErrorReporter.shared.report(
                module: "PhotoLibraryService", action: "consultar_fototeca",
                message: "A consulta foi impedida porque a Fototeca não está autorizada.",
                error: error, result: "bloqueada_antes_da_consulta"
            )
            throw error
        }

        let allAccessible = PHAsset.fetchAssets(with: nil).count
        accessibleItemCount = allAccessible

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let interval = Self.dateInterval(for: period) {
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                interval.start as NSDate,
                interval.end as NSDate
            )
        }

        let assets = PHAsset.fetchAssets(with: options)
        var matches: [PhotoMatch] = []
        assets.enumerateObjects { asset, index, stop in
            if index >= sampleLimit { stop.pointee = true; return }
            matches.append(PhotoMatch(
                id: asset.localIdentifier,
                createdAt: asset.creationDate,
                mediaType: asset.mediaType == .video ? "Vídeo" : "Foto",
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                isFavorite: asset.isFavorite
            ))
        }
        return PhotoQueryResult(accessibleItemCount: allAccessible, matchedItemCount: assets.count, sample: matches)
    }

    func record(error: Error) {
        lastError = error.localizedDescription
        PavlakErrorReporter.shared.report(module: "PhotoLibraryService", action: "executar_operacao", message: "A operação de Fotos não foi concluída.", error: error, result: "erro_recuperado")
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    private static func dateInterval(for period: String, now: Date = Date()) -> DateInterval? {
        let calendar = Calendar.current
        switch period.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) {
        case "hoje": return calendar.dateInterval(of: .day, for: now)
        case "ontem":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: yesterday)
        case "esta semana": return calendar.dateInterval(of: .weekOfYear, for: now)
        case "semana passada":
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: previous)
        case "este mes": return calendar.dateInterval(of: .month, for: now)
        case "mes passado":
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: previous)
        case "ultimos 7 dias":
            return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: now) ?? now, end: now)
        case "ultimos 30 dias":
            return DateInterval(start: calendar.date(byAdding: .day, value: -30, to: now) ?? now, end: now)
        default: return nil
        }
    }
}

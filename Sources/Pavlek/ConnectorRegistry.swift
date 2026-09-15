import Foundation
import Photos
import UserNotifications

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum PavlakPlatform: String, CaseIterable, Sendable {
    case macOS, iOS
}

enum ConnectorPermission: String, Sendable {
    case photoLibrary
    case userSelectedFolders
    case notifications

    var title: String {
        switch self {
        case .photoLibrary: "Fototeca"
        case .userSelectedFolders: "Pastas selecionadas"
        case .notifications: "Notificações"
        }
    }
}

struct PavlakConnector: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let platforms: Set<PavlakPlatform>
    let permissions: [ConnectorPermission]
    let capabilities: [String]
    let actions: [String]
    let limitations: String
}

enum ConnectorAvailability: Equatable, Sendable {
    case available
    case unavailable
    case permissionRequired
    case permissionDenied

    var title: String {
        switch self {
        case .available: "Disponível"
        case .unavailable: "Não disponível"
        case .permissionRequired: "Requer autorização"
        case .permissionDenied: "Acesso negado"
        }
    }
}

@MainActor
final class PavlakConnectorRegistry: ObservableObject {
    static let shared = PavlakConnectorRegistry()

    @Published private(set) var availability: [String: ConnectorAvailability] = [:]
    let connectors: [PavlakConnector]

    private init() {
        connectors = [
            PavlakConnector(
                id: "photos", name: "Fotos", icon: "photo.on.rectangle.angled",
                platforms: [.macOS, .iOS], permissions: [.photoLibrary],
                capabilities: ["Consultar fotos", "Localizar álbuns"],
                actions: ["photos.search", "photos.album.search"],
                limitations: "Somente leitura. Compartilhamento exige seleção e confirmação do usuário."
            ),
            PavlakConnector(
                id: "files", name: "Arquivos / Finder", icon: "folder",
                platforms: [.macOS], permissions: [.userSelectedFolders],
                capabilities: ["Indexar metadados", "Localizar arquivos", "Pré-visualizar documentos"],
                actions: ["files.search", "files.preview"],
                limitations: "Pesquisa somente pastas escolhidas pelo usuário; não altera os originais."
            ),
            PavlakConnector(
                id: "safari", name: "Safari", icon: "safari",
                platforms: [.macOS, .iOS], permissions: [],
                capabilities: ["Pesquisar na web", "Abrir páginas web"], actions: ["web.search", "web.open"],
                limitations: "Não lê histórico, abas ou conteúdo privado."
            ),
            PavlakConnector(
                id: "contacts", name: "Contatos", icon: "person.crop.circle",
                platforms: [.macOS], permissions: [],
                capabilities: ["Abrir o aplicativo"], actions: ["contacts.open"],
                limitations: "Ainda não consulta nem altera contatos."
            ),
            PavlakConnector(
                id: "mail", name: "Mail", icon: "envelope",
                platforms: [.macOS], permissions: [],
                capabilities: ["Abrir o aplicativo"], actions: ["mail.open"],
                limitations: "Ainda não lê nem envia mensagens."
            ),
            PavlakConnector(
                id: "calendar", name: "Calendário", icon: "calendar",
                platforms: [.macOS], permissions: [],
                capabilities: ["Abrir o aplicativo"], actions: ["calendar.open"],
                limitations: "Ainda não consulta nem altera eventos."
            ),
            PavlakConnector(
                id: "notifications", name: "Notificações", icon: "bell",
                platforms: [.macOS, .iOS], permissions: [.notifications],
                capabilities: ["Apresentar notificações locais"], actions: ["notifications.present"],
                limitations: "O usuário controla a autorização nos ajustes do sistema."
            ),
            PavlakConnector(
                id: "pages", name: "Pages", icon: "doc.richtext",
                platforms: [.macOS], permissions: [],
                capabilities: ["Abrir documentos compatíveis"], actions: ["pages.open"],
                limitations: "Disponível somente quando o Pages estiver instalado."
            ),
            PavlakConnector(
                id: "system-share", name: "Compartilhamento", icon: "square.and.arrow.up",
                platforms: [.macOS, .iOS], permissions: [],
                capabilities: ["Apresentar destinos do sistema"], actions: ["system.share"],
                limitations: "O usuário sempre escolhe o aplicativo e confirma o destino."
            ),
            PavlakConnector(
                id: "openai", name: "IA remota (OpenAI/Azure)", icon: "brain.head.profile",
                platforms: [.macOS, .iOS], permissions: [],
                capabilities: ["Conversar sobre solicitações", "Relacionar trechos autorizados de documentos"],
                actions: ["openai.orchestrate"],
                limitations: "A conversa usa a API. Busca e ações no dispositivo são executadas pelo Pavlak."
            )
        ]
        refresh()
    }

    var currentPlatform: PavlakPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    var availableConnectors: [PavlakConnector] {
        connectors.filter { $0.platforms.contains(currentPlatform) }
    }

    func connector(forAction action: String) -> PavlakConnector? {
        availableConnectors.first { $0.actions.contains(action) }
    }

    func canExecute(_ action: String) -> Bool {
        guard let connector = connector(forAction: action) else { return false }
        return availability[connector.id] == .available
    }

    func refresh() {
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        availability["photos"] = switch photoStatus {
        case .authorized, .limited: .available
        case .denied, .restricted: .permissionDenied
        case .notDetermined: .permissionRequired
        @unknown default: .unavailable
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            availability["notifications"] = .permissionRequired
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let resolved: ConnectorAvailability = switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: .available
                case .denied: .permissionDenied
                case .notDetermined: .permissionRequired
                @unknown default: .unavailable
                }
                Task { @MainActor in
                    self.availability["notifications"] = resolved
                }
            }
        } else {
            availability["notifications"] = .unavailable
        }

        availability["system-share"] = .available
        #if os(macOS)
        if availability["files"] != .available {
            availability["files"] = .permissionRequired
        }
        availability["safari"] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") == nil ? .unavailable : .available
        availability["pages"] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") == nil ? .unavailable : .available
        availability["openai"] = OpenAIUsagePolicy.isLocalOnly
            ? .unavailable
            : (PavlakAIConnectionStatus.isReady ? .available : .permissionRequired)
        for connectorID in ["contacts", "mail", "calendar"] {
            availability[connectorID] = applicationURL(for: connectorID) == nil ? .unavailable : .available
        }
        #else
        availability["openai"] = OpenAIUsagePolicy.isLocalOnly ? .unavailable : (PavlakAIConnectionStatus.isReady ? .available : .permissionRequired)
        availability["safari"] = UIApplication.shared.canOpenURL(URL(string: "https://apple.com")!) ? .available : .unavailable
        #endif
    }

    func requestPhotos() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { refresh(); return }
        let reporter = PavlakErrorReporter.shared
        let operation = reporter.begin(module: "ConnectorRegistry", action: "autorizar_fotos")
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        reporter.finish(operation, result: PhotoAuthorizationState.title(for: PHPhotoLibrary.authorizationStatus(for: .readWrite)))
        refresh()
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        refresh()
    }

    func noteAuthorizedFolders(_ hasFolders: Bool) {
        #if os(macOS)
        availability["files"] = hasFolders ? .available : .permissionRequired
        #endif
    }

    #if os(macOS)
    func applicationURL(for connectorID: String) -> URL? {
        let bundleIDs = [
            "photos": "com.apple.Photos", "files": "com.apple.finder",
            "safari": "com.apple.Safari", "pages": "com.apple.iWork.Pages",
            "contacts": "com.apple.AddressBook", "mail": "com.apple.mail",
            "calendar": "com.apple.iCal"
        ]
        guard let bundleID = bundleIDs[connectorID] else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openApplication(for connectorID: String) {
        guard let url = applicationURL(for: connectorID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                PavlakErrorReporter.shared.report(module: "ConnectorRegistry", action: "abrir_\(connectorID)", message: "Não foi possível abrir o aplicativo solicitado.", error: error, result: "erro_recuperado")
            }
        }
    }
    #endif
}

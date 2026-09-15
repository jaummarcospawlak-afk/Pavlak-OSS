import SwiftUI
#if os(macOS)
import UserNotifications

final class PavlekAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LocalDocumentScheduler.shared.configureNotificationActions()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let bookmark = response.notification.request.content.userInfo["securityScopedBookmark"] as? String
        DispatchQueue.main.async {
            LocalDocumentScheduler.handle(actionIdentifier: actionIdentifier, encodedBookmark: bookmark)
        }
        completionHandler()
    }
}
#endif

@main
struct PavlekApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PavlekAppDelegate.self) private var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            #if os(iOS)
            IOSContentView()
            #else
            ContentView()
                .frame(minWidth: 1180, minHeight: 720)
                .task {
                    PavlakLinkService.shared.start()
                    await OpenAIKeyStore.loadFromKeychain()
                    let configuration = PavlakAIConfigurationStore.load()
                    _ = await CloudCredentialStore.load(configuration: configuration)
                    PavlakConnectorRegistry.shared.refresh()
                }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1480, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        #endif
    }
}

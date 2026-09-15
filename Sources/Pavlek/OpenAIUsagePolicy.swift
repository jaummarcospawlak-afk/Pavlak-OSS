import Foundation
import Combine

/// Persistent, process-wide policy checked before every OpenAI network send.
/// Missing preferences intentionally default to local-only for this release.
enum OpenAIUsagePolicy {
    static let defaultsKey = "Pavlak.openAI.localOnly.v1"
    static let localOnlyMessage = "Este pedido não está disponível no Modo local. Nenhuma chamada à OpenAI foi feita. Desative o Modo local explicitamente para usar a API."

    static var isLocalOnly: Bool { isLocalOnly(in: .standard) }

    static func isLocalOnly(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setLocalOnly(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

enum OpenAIUsagePolicyError: LocalizedError, Sendable, Equatable {
    case localOnly

    var errorDescription: String? { OpenAIUsagePolicy.localOnlyMessage }
}

@MainActor
final class PavlakExecutionMode: ObservableObject {
    static let shared = PavlakExecutionMode()

    @Published private(set) var isLocalOnly: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isLocalOnly = OpenAIUsagePolicy.isLocalOnly(in: defaults)
        // Persist the safe initial state so subsequent launches are explicit.
        if defaults.object(forKey: OpenAIUsagePolicy.defaultsKey) == nil {
            OpenAIUsagePolicy.setLocalOnly(true, in: defaults)
        }
    }

    func setLocalOnly(_ enabled: Bool) {
        OpenAIUsagePolicy.setLocalOnly(enabled, in: defaults)
        isLocalOnly = enabled
    }
}

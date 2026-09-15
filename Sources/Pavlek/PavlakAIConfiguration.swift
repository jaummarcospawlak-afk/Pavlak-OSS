import Foundation

enum PavlakAIProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case azureOpenAI = "azure_openai"

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .azureOpenAI: "Azure OpenAI / Microsoft Foundry"
        }
    }
}

struct PavlakAIConfiguration: Codable, Equatable, Sendable {
    static let defaultOpenAIBaseURL = URL(string: "https://api.openai.com/v1/")!
    static let currentModelID = "gpt-5"
    static let astraModelID = "gpt-6-astra"

    var provider: PavlakAIProvider
    var modelID: String?
    var deploymentName: String?
    var baseURL: URL?
    var realtimeDeploymentName: String? = "gpt-realtime-mini"

    static let openAIDefault = Self(
        provider: .openAI,
        modelID: currentModelID,
        deploymentName: nil,
        baseURL: defaultOpenAIBaseURL
    )

    var effectiveModelName: String? {
        switch provider {
        case .openAI: modelID?.trimmedNonEmpty
        case .azureOpenAI: deploymentName?.trimmedNonEmpty
        }
    }

    var responsesURL: URL? {
        guard let baseURL else { return nil }
        return baseURL.appendingPathComponent("responses")
    }

    var usesBearerAuthentication: Bool { provider == .openAI }

    var credentialScope: String {
        // A provider key belongs to the resource, not to one model deployment.
        // Keeping model names out of the scope avoids asking for the same Azure
        // key again when the user changes between the existing text/voice deployments.
        [provider.rawValue, baseURL?.host?.lowercased() ?? "", baseURL?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""].joined(separator: "|")
    }

    var realtimeURL: URL? {
        guard provider == .azureOpenAI, validationError() == nil,
              let deployment = realtimeDeploymentName, Self.validDeployment(deployment),
              let baseURL, var parts = URLComponents(url: baseURL.appendingPathComponent("realtime"), resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "wss"
        parts.queryItems = [URLQueryItem(name: "model", value: deployment)]
        return parts.url
    }

    private static func validDeployment(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }
    }

    /// Astra fallback is intentionally limited to direct OpenAI. Azure cannot
    /// guess a deployment name for the older model.
    var fallbackConfiguration: Self? {
        guard provider == .openAI,
              modelID?.trimmedNonEmpty == Self.astraModelID else { return nil }
        return Self(provider: .openAI, modelID: Self.currentModelID,
                    deploymentName: nil, baseURL: baseURL)
    }

    func validationError() -> String? {
        guard let baseURL else { return "Informe a base URL do provider." }
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.port == nil || baseURL.port == 443 else { return "Use HTTPS sem usuário, senha ou porta personalizada." }
        guard let model = effectiveModelName, !model.isEmpty else {
            return provider == .openAI ? "Informe o model ID da OpenAI." : "Informe o deployment name do Azure."
        }
        guard baseURL.query == nil, baseURL.fragment == nil else { return "A base URL não pode conter query ou fragmento." }
        if provider == .openAI {
            guard baseURL == Self.defaultOpenAIBaseURL else {
                return "A OpenAI direta usa https://api.openai.com/v1/."
            }
        } else {
            // The /openai/v1 inference and Realtime routes used here belong to
            // the Azure OpenAI resource endpoint. A Foundry project endpoint
            // (services.ai.azure.com) is a different API surface and must not
            // be accepted as a drop-in replacement.
            guard let host = baseURL.host?.lowercased(),
                  host.hasSuffix(".openai.azure.com") else {
                return "Use o host oficial do recurso Azure OpenAI."
            }
            let suffix = ".openai.azure.com"
            let resource = String(host.dropLast(suffix.count))
            guard !resource.isEmpty, resource.count <= 63, resource.first != "-", resource.last != "-",
                  resource.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return "Use o host oficial do recurso Azure OpenAI."
            }
            guard ["/openai/v1", "/openai/v1/"].contains(baseURL.path),
                  !baseURL.absoluteString.contains("%") else {
                return "Use uma base Azure compatível com inferência, terminando em /openai/v1/."
            }
            guard Self.validDeployment(model), realtimeDeploymentName.map(Self.validDeployment) ?? true else {
                return "Nome de deployment inválido."
            }
        }
        return nil
    }
}

enum PavlakAIConfigurationStore {
    private static let key = "pavlak.ai.configuration.v1"

    static func load(defaults: UserDefaults = .standard) -> PavlakAIConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(PavlakAIConfiguration.self, from: data),
              configuration.validationError() == nil else {
            // An invalid saved destination must never silently select another provider.
            if defaults.object(forKey: key) != nil {
                return Self.invalidConfiguration
            }
            return .openAIDefault
        }
        return configuration
    }

    private static var invalidConfiguration: PavlakAIConfiguration {
        .init(provider: .azureOpenAI, modelID: nil, deploymentName: nil, baseURL: nil)
    }

    static func save(_ configuration: PavlakAIConfiguration, defaults: UserDefaults = .standard) throws {
        guard configuration.validationError() == nil else { throw PavlakAIConfigurationError.invalid }
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

enum PavlakAIConfigurationError: Error, LocalizedError, Equatable {
    case invalid

    var errorDescription: String? {
        "A configuração do provider está incompleta ou incompatível."
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

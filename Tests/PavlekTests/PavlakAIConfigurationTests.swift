import XCTest
@testable import Pavlek

final class PavlakAIConfigurationTests: XCTestCase {
    func testDefaultIsDirectOpenAIGPT5AndAstraHasReversibleFallback() {
        let configuration = PavlakAIConfiguration.openAIDefault
        XCTAssertEqual(configuration.provider, .openAI)
        XCTAssertEqual(configuration.modelID, PavlakAIConfiguration.currentModelID)
        XCTAssertEqual(configuration.baseURL, PavlakAIConfiguration.defaultOpenAIBaseURL)
        XCTAssertNil(configuration.fallbackConfiguration)

        var astra = configuration
        astra.modelID = PavlakAIConfiguration.astraModelID
        XCTAssertEqual(astra.fallbackConfiguration?.modelID, PavlakAIConfiguration.currentModelID)
        XCTAssertEqual(astra.fallbackConfiguration?.baseURL, configuration.baseURL)
    }

    func testAzureRequiresInferenceV1BaseAndConfiguredDeployment() {
        let projectEndpoint = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                                    deploymentName: "deployment-fixture",
                                                    baseURL: URL(string: "https://example.services.ai/api/projects/demo")!)
        XCTAssertNotNil(projectEndpoint.validationError())

        let foundryProjectHost = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                                       deploymentName: "deployment-fixture",
                                                       baseURL: URL(string: "https://example.services.ai.azure.com/openai/v1/")!)
        XCTAssertNotNil(foundryProjectHost.validationError())

        let valid = PavlakAIConfiguration(provider: .azureOpenAI, modelID: nil,
                                          deploymentName: "deployment-fixture",
                                          baseURL: URL(string: "https://resource.openai.azure.com/openai/v1/")!,
                                          realtimeDeploymentName: "gpt-realtime-mini")
        XCTAssertNil(valid.validationError())
        XCTAssertNil(valid.fallbackConfiguration)
        XCTAssertEqual(valid.realtimeURL?.absoluteString,
                       "wss://resource.openai.azure.com/openai/v1/realtime?model=gpt-realtime-mini")
    }

    func testStorePersistsOnlyNonSecretConfiguration() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "PavlakAIConfigurationTests.\(UUID().uuidString)"))
        let configuration = PavlakAIConfiguration(provider: .openAI, modelID: PavlakAIConfiguration.astraModelID,
                                                   deploymentName: nil, baseURL: PavlakAIConfiguration.defaultOpenAIBaseURL)
        try PavlakAIConfigurationStore.save(configuration, defaults: suite)
        XCTAssertEqual(PavlakAIConfigurationStore.load(defaults: suite), configuration)
        XCTAssertNil(suite.string(forKey: "api-key"))
        PavlakAIConfigurationStore.reset(defaults: suite)
    }
}

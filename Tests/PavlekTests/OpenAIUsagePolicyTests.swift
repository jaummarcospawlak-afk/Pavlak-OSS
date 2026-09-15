import XCTest
@testable import Pavlek

final class OpenAIUsagePolicyTests: XCTestCase {
    func testMissingPreferenceDefaultsToLocalOnlyAndPersistsChanges() throws {
        let suiteName = "PavlekTests.OpenAIUsagePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(OpenAIUsagePolicy.isLocalOnly(in: defaults))
        OpenAIUsagePolicy.setLocalOnly(false, in: defaults)
        XCTAssertFalse(OpenAIUsagePolicy.isLocalOnly(in: defaults))
        OpenAIUsagePolicy.setLocalOnly(true, in: defaults)
        XCTAssertTrue(OpenAIUsagePolicy.isLocalOnly(in: defaults))
    }
}

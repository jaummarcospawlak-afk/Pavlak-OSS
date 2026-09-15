#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class DocumentComparisonTests: XCTestCase {
    func testFindsNamePresentInTwoAttachedDocuments() {
        let names = AttachmentNameComparator.commonNames(in: [
            "O locatário Rogério Almeida assume as obrigações descritas.",
            "Este instrumento é firmado por Rogério Almeida e Maria Souza."
        ])
        XCTAssertEqual(names, ["Rogério Almeida"])
    }
}
#endif

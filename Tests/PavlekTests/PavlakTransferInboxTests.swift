#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class PavlakTransferInboxTests: XCTestCase {
    func testStagesValidatedItemOnlyInMemoryAndReturnsReceipt() throws {
        let inbox = PavlakTransferInbox()
        let payload = try PavlakTransferPayload(filename: "teste.jpg", contentType: "image/jpeg", data: Data([1, 2, 3]))
        let text = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let request = PavlakLinkMessage(requestID: UUID(), sourceDevice: .iPhone, targetDevice: .mac,
                                        action: .stageTransfer, query: "teste.jpg", payload: text,
                                        status: .requested, result: nil, sentAt: Date())

        let response = inbox.receive(request)

        XCTAssertEqual(response.status, .success)
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertEqual(inbox.items.first?.data, Data([1, 2, 3]))
        let receipt = try JSONDecoder().decode(PavlakTransferReceipt.self, from: XCTUnwrap(response.result?.data(using: .utf8)))
        XCTAssertEqual(receipt, PavlakTransferReceipt(itemID: payload.itemID, state: "staged"))
    }

    func testRejectsWrongRoute() throws {
        let inbox = PavlakTransferInbox()
        let payload = try PavlakTransferPayload(filename: "teste.txt", contentType: "text/plain", data: Data("ok".utf8))
        let text = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let request = PavlakLinkMessage(requestID: UUID(), sourceDevice: .mac, targetDevice: .iPhone,
                                        action: .stageTransfer, query: "teste.txt", payload: text,
                                        status: .requested, result: nil, sentAt: Date())
        XCTAssertEqual(inbox.receive(request).status, .failure)
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testRejectsOversizedPayloadBeforeEncoding() {
        XCTAssertThrowsError(try PavlakTransferPayload(filename: "grande.bin", contentType: "application/octet-stream",
                                                       data: Data(repeating: 0, count: PavlakTransferPayload.maximumByteCount + 1)))
    }

    func testKeepsAtMostTenTemporaryItems() throws {
        let inbox = PavlakTransferInbox()
        for number in 0..<12 {
            let payload = try PavlakTransferPayload(filename: "\(number).txt", contentType: "text/plain", data: Data([UInt8(number)]))
            let text = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
            let request = PavlakLinkMessage(requestID: UUID(), sourceDevice: .iPhone, targetDevice: .mac,
                                            action: .stageTransfer, query: payload.filename, payload: text,
                                            status: .requested, result: nil, sentAt: Date())
            XCTAssertEqual(inbox.receive(request).status, .success)
        }
        XCTAssertEqual(inbox.items.count, 10)
        XCTAssertEqual(inbox.items.first?.filename, "11.txt")
    }
}
#endif

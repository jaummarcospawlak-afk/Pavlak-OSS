#if os(macOS)
import XCTest
@testable import Pavlek

@MainActor
final class LocalDocumentSchedulerTests: XCTestCase {
    func testParsesTomorrowAtNine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 15)))

        let result = try XCTUnwrap(DocumentScheduleParser.parse("Pavlak, abra este arquivo amanhã às 9h", now: now, calendar: calendar))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result), DateComponents(year: 2026, month: 8, day: 30, hour: 9, minute: 0))
    }

    func testRejectsImmediateOpenCommand() {
        XCTAssertNil(DocumentScheduleParser.parse("Abra este arquivo agora"))
    }

    func testConfirmationIsRequiredBeforeScheduling() async {
        let scheduler = RecordingDocumentScheduler()
        let workspace = PavlakWorkspaceState(documentScheduler: scheduler, hasValidatedOpenAI: { false })
        workspace.stageDocumentSchedule(
            fileName: "Fixture.pdf",
            fileURL: URL(fileURLWithPath: "/tmp/Fixture.pdf"),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNotNil(workspace.pendingDocumentSchedule)
        XCTAssertTrue(scheduler.requests.isEmpty)

        workspace.confirmDocumentSchedule()
        await Task.yield()
        XCTAssertEqual(scheduler.requests.map(\.fileName), ["Fixture.pdf"])
    }
}

@MainActor
private final class RecordingDocumentScheduler: DocumentScheduling {
    var requests: [PendingDocumentSchedule] = []
    func schedule(_ request: PendingDocumentSchedule) async throws { requests.append(request) }
}
#endif

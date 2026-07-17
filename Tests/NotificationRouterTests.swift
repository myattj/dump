import XCTest
@testable import Dump

@MainActor
final class NotificationRouterTests: XCTestCase {
    func testDoneActionMarksEntryDoneWithoutSnoozing() async {
        let entryURL = URL(fileURLWithPath: "/tmp/dump-done-entry.md")
        var markedDone: [URL] = []
        var snoozed: [URL] = []
        let router = NotificationRouter(
            markDone: { markedDone.append($0) },
            snooze: { snoozed.append($0) }
        )

        await router.handle(
            action: QueueNotification.doneAction,
            entryID: nil,
            path: entryURL.path
        )

        XCTAssertEqual(markedDone, [entryURL])
        XCTAssertTrue(snoozed.isEmpty)
    }

    func testSnoozeActionSnoozesEntryWithoutMarkingItDone() async {
        let entryURL = URL(fileURLWithPath: "/tmp/dump-snooze-entry.md")
        var markedDone: [URL] = []
        var snoozed: [URL] = []
        let router = NotificationRouter(
            markDone: { markedDone.append($0) },
            snooze: { snoozed.append($0) }
        )

        await router.handle(
            action: QueueNotification.snoozeAction,
            entryID: nil,
            path: entryURL.path
        )

        XCTAssertTrue(markedDone.isEmpty)
        XCTAssertEqual(snoozed, [entryURL])
    }
}

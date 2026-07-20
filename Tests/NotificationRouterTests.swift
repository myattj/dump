import XCTest
@testable import Dump

@MainActor
final class NotificationRouterTests: XCTestCase {
    func testDoneActionMarksEntryDoneWithoutSnoozing() async {
        let entryURL = URL(fileURLWithPath: "/tmp/dump-done-entry.md")
        var markedDone: [URL] = []
        var snoozed: [URL] = []
        var mutationCallbacks = 0
        let router = NotificationRouter(
            markDone: { markedDone.append($0) },
            snooze: { snoozed.append($0) },
            queueDidMutate: { mutationCallbacks += 1 }
        )

        await router.handle(
            action: QueueNotification.doneAction,
            entryID: nil,
            path: entryURL.path
        )

        XCTAssertEqual(markedDone, [entryURL])
        XCTAssertTrue(snoozed.isEmpty)
        XCTAssertEqual(mutationCallbacks, 1)
    }

    func testSnoozeActionSnoozesEntryWithoutMarkingItDone() async {
        let entryURL = URL(fileURLWithPath: "/tmp/dump-snooze-entry.md")
        var markedDone: [URL] = []
        var snoozed: [URL] = []
        var mutationCallbacks = 0
        let router = NotificationRouter(
            markDone: { markedDone.append($0) },
            snooze: { snoozed.append($0) },
            queueDidMutate: { mutationCallbacks += 1 }
        )

        await router.handle(
            action: QueueNotification.snoozeAction,
            entryID: nil,
            path: entryURL.path
        )

        XCTAssertTrue(markedDone.isEmpty)
        XCTAssertEqual(snoozed, [entryURL])
        XCTAssertEqual(mutationCallbacks, 1)
    }

    func testFailedMutationRefreshesWithoutRequestingIndexUpdate() async {
        var refreshCallbacks = 0
        var mutationCallbacks = 0
        let router = NotificationRouter(
            markDone: { _ in throw NotificationRouterTestError.mutationFailed },
            snooze: { _ in },
            refreshQueue: { refreshCallbacks += 1 },
            queueDidMutate: { mutationCallbacks += 1 }
        )

        await router.handle(
            action: QueueNotification.doneAction,
            entryID: nil,
            path: "/tmp/dump-failed-entry.md"
        )

        XCTAssertEqual(refreshCallbacks, 1)
        XCTAssertEqual(mutationCallbacks, 0)
    }
}

private enum NotificationRouterTestError: Error {
    case mutationFailed
}

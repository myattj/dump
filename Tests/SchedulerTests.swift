import XCTest
@testable import Dump

final class SchedulerServiceTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-sched-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "sched.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
        try? FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testFutureScheduledEntryGetsRegistered() async throws {
        let writer = MarkdownWriter()
        let when = Date(timeIntervalSinceNow: 3600)
        let result = try writer.write(body: "do the thing", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = when
            fm.title = "Do the thing"
        }
        XCTAssertNotNil(result)

        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let outcome = await scheduler.reconcile(now: Date())
        XCTAssertEqual(outcome.scheduled.count, 1)
        XCTAssertEqual(notif.scheduled.count, 1)
        XCTAssertEqual(notif.scheduled.first?.title, "Do the thing")
    }

    func testPastEntryIsNotScheduled() async throws {
        let writer = MarkdownWriter()
        _ = try writer.write(body: "expired", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = Date(timeIntervalSinceNow: -10)
        }
        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let outcome = await scheduler.reconcile(now: Date())
        XCTAssertEqual(outcome.scheduled.count, 0)
        XCTAssertEqual(notif.scheduled.count, 0)
        XCTAssertEqual(notif.authorizationRequestCount, 0)
    }

    func testAuthorizationIsRequestedOnlyWhenSchedulingIsNeeded() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try writer.write(body: "first", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = now.addingTimeInterval(600)
        }
        _ = try writer.write(body: "second", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.deadlineAt = now.addingTimeInterval(1_200)
        }

        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let outcome = await scheduler.reconcile(now: now)

        XCTAssertEqual(outcome.scheduled.count, 2)
        XCTAssertEqual(notif.authorizationRequestCount, 1)
    }

    func testDeniedAuthorizationDoesNotScheduleFutureEntry() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try writer.write(body: "ping me", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = now.addingTimeInterval(600)
        }

        let notif = MockNotificationCenter()
        notif.authorized = false
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let outcome = await scheduler.reconcile(now: now)

        XCTAssertEqual(outcome.scheduled.count, 0)
        XCTAssertEqual(notif.scheduled.count, 0)
        XCTAssertEqual(notif.authorizationRequestCount, 1)
    }

    func testDoneEntryGetsCancelled() async throws {
        let writer = MarkdownWriter()
        let when = Date(timeIntervalSinceNow: 3600)
        let result = try writer.write(body: "done already", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = when
            fm.status = .done
            fm.notificationId = "stale-id"
        }
        XCTAssertNotNil(result)

        let notif = MockNotificationCenter()
        try await notif.schedule(id: "stale-id", title: "x", body: "x", fireAt: when, userInfo: [:])

        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        _ = await scheduler.reconcile(now: Date())
        XCTAssertEqual(notif.cancelled, ["stale-id"])
    }

    func testDeadlineOnlyTaskSchedulesAtDeadline() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(7_200)
        _ = try writer.write(body: "ship the fix", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.deadlineAt = deadline
            fm.title = "Ship the fix"
        }

        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let outcome = await scheduler.reconcile(now: now)

        XCTAssertEqual(outcome.scheduled.count, 1)
        XCTAssertEqual(notif.scheduled.first?.fireAt, deadline)
        XCTAssertEqual(notif.scheduled.first?.title, "Ship the fix")
    }

    func testScheduledAtWinsOverDeadline() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let scheduledAt = now.addingTimeInterval(1_800)
        _ = try writer.write(body: "prep the demo", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.scheduledAt = scheduledAt
            fm.deadlineAt = now.addingTimeInterval(86_400)
        }

        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        _ = await scheduler.reconcile(now: now)

        XCTAssertEqual(notif.scheduled.first?.fireAt, scheduledAt)
    }

    func testSnoozeNotificationReArmsAnHourLater() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let result = try writer.write(body: "call sam", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = now.addingTimeInterval(60)
            fm.notificationId = "n1"
        }
        let notif = MockNotificationCenter()
        try await notif.schedule(id: "n1", title: "x", body: "x", fireAt: now.addingTimeInterval(60), userInfo: [:])

        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        try await scheduler.snoozeNotification(entryURL: result.url, now: now)

        XCTAssertTrue(notif.cancelled.contains("n1"))
        XCTAssertEqual(notif.scheduled.map(\.id), ["n1"])
        XCTAssertEqual(notif.scheduled.first?.fireAt, now.addingTimeInterval(3_600))
    }

    func testSnoozeNotificationLeavesTaskDeadlineUntouched() async throws {
        let writer = MarkdownWriter()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(600)
        let result = try writer.write(body: "send invoice", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.deadlineAt = deadline
            fm.notificationId = "n2"
        }
        let notif = MockNotificationCenter()

        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        try await scheduler.snoozeNotification(entryURL: result.url, now: now)

        let raw = try String(contentsOf: result.url, encoding: .utf8)
        let (fm, _) = try FrontmatterCodec.decode(raw)
        XCTAssertEqual(fm.deadlineAt, deadline)
        XCTAssertEqual(fm.scheduledAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(notif.scheduled.first?.fireAt, now.addingTimeInterval(3_600))
    }

    func testMarkDoneUpdatesFrontmatter() async throws {
        let writer = MarkdownWriter()
        let result = try writer.write(body: "x", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .reminder
            fm.scheduledAt = Date(timeIntervalSinceNow: 3600)
            fm.notificationId = "n1"
        }
        let notif = MockNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)
        let doneAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await scheduler.markDone(entryURL: result.url, completedAt: doneAt)
        let raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"))
        XCTAssertTrue(raw.contains("completed_at:"))
        XCTAssertTrue(notif.cancelled.contains("n1"))
    }

    func testCancelAllPendingClearsNotificationsBeforeStorageMove() async throws {
        let notif = MockNotificationCenter()
        try await notif.schedule(id: "old-1", title: "x", body: "x", fireAt: .distantFuture, userInfo: [:])
        try await notif.schedule(id: "old-2", title: "x", body: "x", fireAt: .distantFuture, userInfo: [:])
        let scheduler = SchedulerService(storage: storage, writer: MarkdownWriter(), notifications: notif)

        await scheduler.cancelAllPending()
        let pending = await notif.pending()

        XCTAssertEqual(Set(notif.cancelled), ["old-1", "old-2"])
        XCTAssertTrue(pending.isEmpty)
    }
}

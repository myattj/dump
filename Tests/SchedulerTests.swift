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
}

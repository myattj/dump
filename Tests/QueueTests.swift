import XCTest
@testable import Dump

final class QueueRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOrdersByUrgencyBeforeEffort() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "later-quick", createdAt: now, deadlineAt: now.addingTimeInterval(2 * 86_400), effortMinutes: 15),
            .init(id: "tomorrow-long", createdAt: now, deadlineAt: now.addingTimeInterval(86_400), effortMinutes: 240),
            .init(id: "no-deadline", createdAt: now, effortMinutes: 5),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["tomorrow-long", "later-quick", "no-deadline"])
    }

    func testUsesEffortForNoDeadlineTasks() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "long", createdAt: now, effortMinutes: 180),
            .init(id: "quick", createdAt: now, effortMinutes: 5),
        ]

        let ranked = ranker.rank(entries, now: now)

        XCTAssertEqual(ranked.map { $0.entry.id }, ["quick", "long"])
        XCTAssertEqual(ranked.map(\.rank), [1, 2])
    }
}

final class QueueStoreTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!
    var writer: MarkdownWriter!
    var notifications: MockNotificationCenter!
    var scheduler: SchedulerService!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-queue-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "queue.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
        writer = MarkdownWriter()
        notifications = MockNotificationCenter()
        scheduler = SchedulerService(storage: storage, writer: writer, notifications: notifications)
        try? FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storage.subdirectory(.meetings), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testReconcileScansActiveInboxTasksAndPersistsRanks() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = try writer.write(body: "send invoice", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "soon"
            fm.type = .task
            fm.deadlineAt = now.addingTimeInterval(3_600)
            fm.effortMinutes = 15
        }
        _ = try writer.write(body: "write launch notes", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "later"
            fm.type = .task
            fm.deadlineAt = now.addingTimeInterval(86_400)
            fm.effortMinutes = 120
        }
        _ = try writer.write(body: "archive note", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .note
        }
        _ = try writer.write(body: "finished", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.status = .done
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        let items = try await store.reconcile(now: now)

        XCTAssertEqual(items.map(\.id), ["soon", "later"])
        XCTAssertEqual(items.map(\.queueRank), [1, 2])
        let raw = try String(contentsOf: soon.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("queue_rank: 1"))
        XCTAssertTrue(raw.contains("queue_score:"))
    }

    func testMarkDoneAndUndoUseMarkdownAndScheduler() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try writer.write(body: "call Sam", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "sam"
            fm.type = .reminder
            fm.scheduledAt = now.addingTimeInterval(3_600)
            fm.notificationId = "n-sam"
        }
        try await notifications.schedule(
            id: "n-sam",
            title: "Call Sam",
            body: "call Sam",
            fireAt: now.addingTimeInterval(3_600),
            userInfo: [:]
        )
        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        let item = try await store.reconcile(now: now).first!

        let undo = try await store.markDone(item, completedAt: now)

        var raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"))
        XCTAssertTrue(raw.contains("completed_at:"))
        XCTAssertEqual(notifications.cancelled, ["n-sam"])

        try await store.undo(undo)

        raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: active"))
        XCTAssertFalse(raw.contains("completed_at:"))
        XCTAssertTrue(notifications.scheduled.contains { $0.id == "n-sam" })
    }
}

import XCTest
@testable import Dump

final class QueueRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour = 3_600.0
    private let day = 86_400.0

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

    func testLongTasksSurfaceEarlierForTheSameDeadline() {
        // Effort creates lead time: a 4h task due tomorrow is more urgent
        // than a 5m task due tomorrow, not less.
        let ranker = QueueRanker()
        let deadline = now.addingTimeInterval(day)
        let entries: [QueueRanker.Entry] = [
            .init(id: "quick", createdAt: now, deadlineAt: deadline, effortMinutes: 5),
            .init(id: "long", createdAt: now, deadlineAt: deadline, effortMinutes: 240),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["long", "quick"])
    }

    func testImportanceOrdersItemsWithTheSameDeadline() {
        let ranker = QueueRanker()
        let deadline = now.addingTimeInterval(day)
        let entries: [QueueRanker.Entry] = [
            .init(id: "normal", createdAt: now, deadlineAt: deadline, effortMinutes: 30),
            .init(id: "critical", createdAt: now, deadlineAt: deadline, effortMinutes: 30, importance: 4),
            .init(id: "low", createdAt: now, deadlineAt: deadline, effortMinutes: 30, importance: 1),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["critical", "normal", "low"])
    }

    func testImportantUndatedItemDoesNotOutrankImminentDeadline() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "critical-someday", createdAt: now, importance: 4),
            .init(id: "due-today", createdAt: now, deadlineAt: now.addingTimeInterval(4 * hour), effortMinutes: 30),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["due-today", "critical-someday"])
    }

    func testFutureReminderGatesToLaterBucket() {
        let ranker = QueueRanker()
        let scheduled = now.addingTimeInterval(7 * day)
        let entries: [QueueRanker.Entry] = [
            .init(id: "next-week-reminder", createdAt: now, scheduledAt: scheduled),
            .init(id: "backlog-task", createdAt: now, effortMinutes: 60),
        ]

        let ranked = ranker.rank(entries, now: now)

        XCTAssertEqual(ranked.map { $0.entry.id }, ["backlog-task", "next-week-reminder"])
        XCTAssertEqual(ranked[0].bucket, .now)
        XCTAssertEqual(ranked[1].bucket, .later)
        XCTAssertEqual(ranked[1].wakeAt, scheduled.addingTimeInterval(-30 * 60))
    }

    func testFiredReminderRanksAboveBacklog() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "backlog-task", createdAt: now, effortMinutes: 60),
            .init(id: "fired-reminder", createdAt: now, scheduledAt: now.addingTimeInterval(-hour)),
        ]

        let ranked = ranker.rank(entries, now: now)

        XCTAssertEqual(ranked.map { $0.entry.id }, ["fired-reminder", "backlog-task"])
        XCTAssertEqual(ranked.map(\.bucket), [.now, .now])
    }

    func testSnoozedEntryDropsToLaterUntilWake() {
        let ranker = QueueRanker()
        let wake = now.addingTimeInterval(day)
        let entries: [QueueRanker.Entry] = [
            .init(id: "snoozed", createdAt: now, deadlineAt: now.addingTimeInterval(2 * hour), snoozedUntil: wake, snoozeCount: 1),
            .init(id: "plain", createdAt: now, effortMinutes: 60),
        ]

        let asleep = ranker.rank(entries, now: now)
        XCTAssertEqual(asleep.map { $0.entry.id }, ["plain", "snoozed"])
        XCTAssertEqual(asleep[1].bucket, .later)
        XCTAssertEqual(asleep[1].wakeAt, wake)

        let awake = ranker.rank(entries, now: wake.addingTimeInterval(1))
        XCTAssertEqual(awake.map { $0.entry.id }, ["snoozed", "plain"])
        XCTAssertEqual(awake.map(\.bucket), [.now, .now])
    }

    func testRepeatedSnoozesDecayImportance() {
        let ranker = QueueRanker()
        let deadline = now.addingTimeInterval(day)
        let entries: [QueueRanker.Entry] = [
            .init(id: "deferred", createdAt: now, deadlineAt: deadline, effortMinutes: 30, importance: 4, snoozeCount: 3),
            .init(id: "fresh", createdAt: now, deadlineAt: deadline, effortMinutes: 30, importance: 4),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["fresh", "deferred"])
    }

    func testOverdueSaturatesAndStaysOnTop() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "due-soon", createdAt: now, deadlineAt: now.addingTimeInterval(2 * hour), effortMinutes: 30),
            .init(id: "overdue-week", createdAt: now, deadlineAt: now.addingTimeInterval(-8 * day), effortMinutes: 30),
            .init(id: "overdue-month", createdAt: now, deadlineAt: now.addingTimeInterval(-30 * day), effortMinutes: 30),
        ]

        let ranked = ranker.rank(entries, now: now)

        XCTAssertEqual(ranked.map { $0.entry.id }, ["overdue-month", "overdue-week", "due-soon"])
        // Deep-overdue scores converge instead of growing without bound.
        XCTAssertEqual(ranked[0].score, ranked[1].score, accuracy: 0.05)
    }

    func testUndatedItemsCreepUpWithAge() {
        let ranker = QueueRanker()
        let entries: [QueueRanker.Entry] = [
            .init(id: "fresh", createdAt: now, effortMinutes: 60),
            .init(id: "month-old", createdAt: now.addingTimeInterval(-30 * day), effortMinutes: 60),
            .init(id: "due-next-week", createdAt: now, deadlineAt: now.addingTimeInterval(7 * day), effortMinutes: 60),
        ]

        let ranked = ranker.rank(entries, now: now).map { $0.entry.id }

        XCTAssertEqual(ranked, ["month-old", "fresh", "due-next-week"])
    }
}

final class QueueMetadataExtractorTests: XCTestCase {
    func testExtractsDateAndEffortFromQueueText() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let metadata = QueueMetadataExtractor.extract(from: "send invoice tomorrow 15m", now: now)
        let deadline = try XCTUnwrap(metadata.deadlineAt)

        XCTAssertEqual(metadata.inferredType, .task)
        XCTAssertNil(metadata.scheduledAt)
        XCTAssertEqual(metadata.effortMinutes, 15)
        XCTAssertTrue(calendar.isDate(deadline, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
        XCTAssertEqual(calendar.component(.hour, from: deadline), 17)
    }

    func testExtractsReminderSchedule() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let metadata = QueueMetadataExtractor.extract(from: "remind me to call Sam tomorrow at 9am", now: now)
        let scheduled = try XCTUnwrap(metadata.scheduledAt)

        XCTAssertEqual(metadata.inferredType, .reminder)
        XCTAssertNil(metadata.deadlineAt)
        XCTAssertTrue(calendar.isDate(scheduled, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!))
        XCTAssertEqual(calendar.component(.hour, from: scheduled), 9)
    }

    func testExtractsImportanceFromBangsAndWords() {
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "call mom !").importance, 3)
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "pay rent !!").importance, 4)
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "urgent: fix the server").importance, 4)
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "this is important, prep the deck").importance, 3)
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "someday learn piano").importance, 1)
        XCTAssertNil(QueueMetadataExtractor.extract(from: "send invoice tomorrow").importance)
    }

    func testExtractsTildeEffortSyntax() {
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "write report ~45m").effortMinutes, 45)
        XCTAssertEqual(QueueMetadataExtractor.extract(from: "plan offsite ~2h").effortMinutes, 120)
    }

    func testDisplayTitleStripsSyntaxTokens() {
        XCTAssertEqual(
            QueueMetadataExtractor.displayTitle(from: "send invoice tomorrow ~15m !!"),
            "send invoice tomorrow"
        )
        XCTAssertEqual(
            QueueMetadataExtractor.displayTitle(from: "call Sam !\nsecond line ignored"),
            "call Sam"
        )
        XCTAssertNil(QueueMetadataExtractor.displayTitle(from: "!!"))
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

    func testReconcileBackfillsMissingQueueMetadataFromBody() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try writer.write(body: "send invoice tomorrow 15m", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "invoice"
            fm.type = .task
            fm.createdAt = now
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        let items = try await store.reconcile(now: now)

        XCTAssertEqual(items.map(\.id), ["invoice"])
        XCTAssertNotNil(items.first?.deadlineAt)
        XCTAssertEqual(items.first?.effortMinutes, 15)

        let raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("deadline_at:"))
        XCTAssertTrue(raw.contains("effort_minutes: 15"))
        XCTAssertTrue(raw.contains("queue_rank: 1"))
    }

    func testReconcileArmsNotificationsForHydratedDeadlines() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try writer.write(body: "send invoice tomorrow 15m", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "invoice"
            fm.type = .task
            fm.createdAt = now
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        _ = try await store.reconcile(now: now)

        // The deadline only exists because hydration mined it from the body;
        // the queue reconcile must hand it to the scheduler, not sit on it
        // until the next capture.
        XCTAssertEqual(notifications.scheduled.count, 1)
        XCTAssertEqual(notifications.scheduled.first?.userInfo["entry_id"], "invoice")
    }

    func testReconcileDoesNotRewriteFilesWhenOnlyTimePasses() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try writer.write(body: "send invoice", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "invoice"
            fm.type = .task
            fm.deadlineAt = now.addingTimeInterval(86_400)
            fm.effortMinutes = 15
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        _ = try await store.reconcile(now: now)
        let afterFirst = try String(contentsOf: result.url, encoding: .utf8)

        // An hour later the score has drifted but the rank hasn't — the
        // file must not be rewritten (rewrites trigger re-index/embed).
        _ = try await store.reconcile(now: now.addingTimeInterval(3_600))
        let afterSecond = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertEqual(afterFirst, afterSecond)
    }

    func testSnoozeMovesItemToLaterBucketAndPersists() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try writer.write(body: "stay active", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "active"
            fm.type = .task
            fm.createdAt = now
        }
        _ = try writer.write(body: "put off", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "deferred"
            fm.type = .task
            fm.createdAt = now
            fm.deadlineAt = now.addingTimeInterval(3_600)
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        let items = try await store.reconcile(now: now)
        XCTAssertEqual(items.map(\.id), ["deferred", "active"])

        let deferred = items[0]
        try await store.snooze(deferred, until: now.addingTimeInterval(86_400))
        let after = try await store.reconcile(now: now)

        XCTAssertEqual(after.map(\.id), ["active", "deferred"])
        XCTAssertTrue(after[1].isLater)
        XCTAssertEqual(after[1].snoozeCount, 1)
        let raw = try String(contentsOf: deferred.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("snoozed_until:"))
        XCTAssertTrue(raw.contains("snooze_count: 1"))

        try await store.wake(after[1])
        let woken = try await store.reconcile(now: now)
        XCTAssertEqual(woken.map(\.id), ["deferred", "active"])
        XCTAssertFalse(woken[0].isLater)
    }

    func testEditMetadataMarksEditedAndBlocksRehydration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try writer.write(body: "send invoice tomorrow 15m", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "invoice"
            fm.type = .task
            fm.createdAt = now
        }

        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        let items = try await store.reconcile(now: now)
        XCTAssertNotNil(items.first?.deadlineAt)

        // User clears the date; body still says "tomorrow" but hydration
        // must not resurrect it.
        try await store.editMetadata(items[0]) { fm in
            fm.deadlineAt = nil
        }
        let after = try await store.reconcile(now: now)

        XCTAssertNil(after.first?.deadlineAt)
        let raw = try String(contentsOf: items[0].url, encoding: .utf8)
        XCTAssertTrue(raw.contains("metadata_edited: true"))
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

@MainActor
final class QueueViewModelSelectionTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!
    var writer: MarkdownWriter!
    var notifications: MockNotificationCenter!
    var scheduler: SchedulerService!
    var viewModel: QueueViewModel!

    // Xcode 16 declares XCTest's async base hook as nonisolated, so an
    // @MainActor test case must perform its setup without calling that no-op.
    override func setUp() async throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-queue-vm-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "queue.vm.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
        writer = MarkdownWriter()
        notifications = MockNotificationCenter()
        scheduler = SchedulerService(storage: storage, writer: writer, notifications: notifications)
        try FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)

        let classifier = ClassifierHub(
            keychain: KeychainStore(service: "queue.vm.\(UUID())"),
            defaults: UserDefaults(suiteName: "queue.vm.hub.\(UUID())")!,
            claude: QueueViewModelNoopClassifier(),
            ollama: QueueViewModelNoopClassifier(),
            custom: QueueViewModelNoopClassifier(),
            bedrock: QueueViewModelNoopClassifier()
        )
        let store = QueueStore(storage: storage, writer: writer, scheduler: scheduler)
        viewModel = QueueViewModel(
            storage: storage,
            writer: writer,
            classifier: classifier,
            scheduler: scheduler,
            store: store
        )
    }

    // See setUp(): the XCTest base implementation has no work to preserve.
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        viewModel = nil
        scheduler = nil
        notifications = nil
        writer = nil
        storage = nil
        defaults = nil
    }

    func testRefreshDoesNotSelectFirstItemAutomatically() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeTask(id: "first", title: "First", deadlineAt: now.addingTimeInterval(3_600), createdAt: now)
        try writeTask(id: "second", title: "Second", deadlineAt: now.addingTimeInterval(7_200), createdAt: now)

        await viewModel.refresh(now: now)

        XCTAssertEqual(viewModel.items.map(\.id), ["first", "second"])
        XCTAssertNil(viewModel.selectedID)
    }

    func testRefreshPreservesExplicitSelectionAndClearsStaleSelectionToNil() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try writeTask(id: "first", title: "First", deadlineAt: now.addingTimeInterval(3_600), createdAt: now)
        let selected = try writeTask(id: "second", title: "Second", deadlineAt: now.addingTimeInterval(7_200), createdAt: now)
        await viewModel.refresh(now: now)

        viewModel.selectedID = "second"
        await viewModel.refresh(now: now)
        XCTAssertEqual(viewModel.selectedID, "second")

        try FileManager.default.removeItem(at: selected.url)
        await viewModel.refresh(now: now)

        XCTAssertEqual(viewModel.items.map(\.id), ["first"])
        XCTAssertNil(viewModel.selectedID)
    }

    func testKeyboardNavigationCanEstablishSelectionFromEmptyState() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeTask(id: "first", title: "First", deadlineAt: now.addingTimeInterval(3_600), createdAt: now)
        try writeTask(id: "second", title: "Second", deadlineAt: now.addingTimeInterval(7_200), createdAt: now)
        await viewModel.refresh(now: now)
        XCTAssertNil(viewModel.selectedID)

        viewModel.selectNext()

        XCTAssertEqual(viewModel.selectedID, "first")
    }

    func testSubmitRestoresDraftWhenWriteFails() async throws {
        let inbox = storage.subdirectory(.inbox)
        try FileManager.default.removeItem(at: inbox)
        XCTAssertTrue(FileManager.default.createFile(atPath: inbox.path, contents: Data()))
        viewModel.input = "  keep this task  "

        await viewModel.submit(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(viewModel.input, "  keep this task  ")
        XCTAssertNotNil(viewModel.error)
    }

    @discardableResult
    private func writeTask(
        id: String,
        title: String,
        deadlineAt: Date,
        createdAt: Date
    ) throws -> MarkdownWriter.WriteResult {
        try writer.write(body: title, into: storage.subdirectory(.inbox)) { fm in
            fm.id = id
            fm.title = title
            fm.type = .task
            fm.createdAt = createdAt
            fm.deadlineAt = deadlineAt
        }
    }
}

private struct QueueViewModelNoopClassifier: Classifier {
    let identifier = "queue-vm-noop"

    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        .unknown
    }
}

final class QueueSummaryTests: XCTestCase {
    private let calendar = Calendar.current
    // 9am local on a fixed day, so "+1h" stays inside today for the
    // due-today bucket regardless of the machine's time zone.
    private var now: Date {
        calendar.date(
            bySettingHour: 9, minute: 0, second: 0,
            of: Date(timeIntervalSince1970: 1_800_000_000)
        )!
    }

    private func item(_ id: String, due: Date?, isLater: Bool = false) -> QueueItem {
        QueueItem(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id).md"),
            title: id,
            body: "",
            type: .task,
            createdAt: now.addingTimeInterval(-86_400),
            deadlineAt: due,
            scheduledAt: nil,
            effortMinutes: nil,
            importance: nil,
            snoozedUntil: nil,
            snoozeCount: 0,
            queueRank: 1,
            queueScore: 0,
            isLater: isLater,
            wakeAt: nil,
            metadataConfidence: nil,
            tags: []
        )
    }

    func testCountsOverdueAndDueTodaySeparately() {
        let items = [
            item("overdue", due: now.addingTimeInterval(-3_600)),
            item("today", due: now.addingTimeInterval(3_600)),
            item("next-week", due: now.addingTimeInterval(7 * 86_400)),
            item("undated", due: nil),
        ]

        let summary = QueueSummary.compute(from: items, now: now, calendar: calendar)

        XCTAssertEqual(summary.overdueCount, 1)
        XCTAssertEqual(summary.dueTodayCount, 1)
    }

    func testTopItemsKeepRankOrderAndSkipLaterBucket() {
        let items = [
            item("a", due: now.addingTimeInterval(3_600)),
            item("sleeping", due: nil, isLater: true),
            item("b", due: nil),
            item("c", due: nil),
            item("d", due: nil),
        ]

        let summary = QueueSummary.compute(from: items, now: now, calendar: calendar)

        XCTAssertEqual(summary.topItems.map(\.id), ["a", "b", "c"])
    }

    func testLaterItemsDoNotCountAsOverdue() {
        let items = [
            item("snoozed-overdue", due: now.addingTimeInterval(-3_600), isLater: true)
        ]

        let summary = QueueSummary.compute(from: items, now: now, calendar: calendar)

        XCTAssertEqual(summary.overdueCount, 0)
        XCTAssertTrue(summary.topItems.isEmpty)
    }
}

import Foundation
import os
import XCTest
@testable import Dump

/// TEMPORARY repro for review claim: reconcile's stale frontmatter
/// write-back resurrecting a just-completed entry. Delete after review.
final class RaceReproTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-race-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "race.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
        try? FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// A NotificationScheduling whose schedule() suspends until released —
    /// modeling the real UNUserNotificationCenter.add IPC await.
    final class GatedNotificationCenter: NotificationScheduling, @unchecked Sendable {
        private struct State: Sendable {
            var entered: [CheckedContinuation<Void, Never>] = []
            var gate: [CheckedContinuation<Void, Never>] = []
            var released = false
            var scheduleEntered = false
            var scheduledIDs: [String] = []
            var cancelledIDs: [String] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var scheduledIDs: [String] { state.withLock { $0.scheduledIDs } }
        var cancelledIDs: [String] { state.withLock { $0.cancelledIDs } }

        func requestAuthorizationIfNeeded() async -> Bool { true }

        /// Waits until schedule() has been entered.
        func waitUntilScheduleEntered() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock {
                    if $0.scheduleEntered { return true }
                    $0.entered.append(cont)
                    return false
                }
                if resumeNow { cont.resume() }
            }
        }

        func release() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock {
                $0.released = true
                let w = $0.gate
                $0.gate = []
                return w
            }
            waiters.forEach { $0.resume() }
        }

        func schedule(id: String, title: String, body: String, fireAt: Date, userInfo: [String: String]) async throws {
            // Signal that we're inside schedule(), then hold the suspension
            // open until the test releases us — like slow IPC to usernoted.
            let enteredWaiters: [CheckedContinuation<Void, Never>] = state.withLock {
                $0.scheduleEntered = true
                let w = $0.entered
                $0.entered = []
                return w
            }
            enteredWaiters.forEach { $0.resume() }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock {
                    if $0.released { return true }
                    $0.gate.append(cont)
                    return false
                }
                if resumeNow { cont.resume() }
            }
            state.withLock { $0.scheduledIDs.append(id) }
        }

        func cancel(ids: [String]) async {
            state.withLock { $0.cancelledIDs.append(contentsOf: ids) }
        }

        func pending() async -> Set<String> { [] }
    }

    func testMarkDoneDuringReconcileStampWindowIsRevertedByStaleWriteBack() async throws {
        let writer = MarkdownWriter()
        let now = Date()
        // Fresh entry: active, future fire date, no notification_id yet —
        // i.e. exactly the state of any just-captured dated entry on its
        // first scheduler pass.
        let result = try writer.write(body: "pay rent friday", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .task
            fm.deadlineAt = now.addingTimeInterval(3_600)
            fm.title = "Pay rent"
        }

        let notif = GatedNotificationCenter()
        let scheduler = SchedulerService(storage: storage, writer: writer, notifications: notif)

        // Reconcile pass begins: snapshots frontmatter, then suspends inside
        // notifications.schedule(...) (real IPC in production).
        let reconcileTask = Task { await scheduler.reconcile(now: now) }
        await notif.waitUntilScheduleEntered()

        // User completes the item from the queue while the pass is in
        // flight (QueueViewModel.complete -> store.markDone -> scheduler.markDone).
        let doneAt = now.addingTimeInterval(1)
        try await scheduler.markDone(entryURL: result.url, completedAt: doneAt)

        // Confirm the completion hit disk.
        var (fm, _) = try FrontmatterCodec.decode(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertEqual(fm.status, .done)
        XCTAssertEqual(fm.completedAt?.timeIntervalSince1970 ?? 0, doneAt.timeIntervalSince1970, accuracy: 1)

        // IPC returns; reconcile resumes and stamps notification_id using
        // its enumerate-time snapshot.
        notif.release()
        _ = await reconcileTask.value

        // The completed entry should still be done. If the stale snapshot
        // was written back, it is resurrected: status active, completed_at
        // gone, notification armed.
        (fm, _) = try FrontmatterCodec.decode(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertEqual(fm.status, .done, "reconcile's stale write-back resurrected a completed entry")
        XCTAssertNotNil(fm.completedAt, "completed_at was lost to the stale write-back")
        XCTAssertTrue(notif.cancelledIDs.contains(fm.notificationId ?? fm.id) || notif.scheduledIDs.isEmpty,
                      "notification stays armed for a completed entry")
    }
}

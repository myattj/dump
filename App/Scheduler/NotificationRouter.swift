import AppKit
import OSLog
import UserNotifications

/// Owns the `UNUserNotificationCenter` delegate role: registers the queue
/// item category (Done / Snooze 1h) and routes notification responses back
/// into the app — a tap lands in the Queue on the item that fired, the
/// banner actions complete or re-arm the entry without opening a window.
/// Must be installed before the app finishes launching so responses that
/// started the app are delivered.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let markDone: @MainActor (URL) async throws -> Void
    private let snooze: @MainActor (URL) async throws -> Void
    private let refreshQueueHandler: @MainActor () -> Void
    private let queueDidMutateHandler: @MainActor () -> Void
    private let revealQueueEntry: @MainActor (String?) -> Void
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "notifications")

    public convenience init(coordinator: AppCoordinator) {
        self.init(
            markDone: { [weak coordinator] entryURL in
                guard let coordinator else { return }
                try await coordinator.scheduler.markDone(entryURL: entryURL)
            },
            snooze: { [weak coordinator] entryURL in
                guard let coordinator else { return }
                try await coordinator.scheduler.snoozeNotification(entryURL: entryURL)
            },
            refreshQueue: { [weak coordinator] in
                coordinator?.queue.refresh()
            },
            queueDidMutate: { [weak coordinator] in
                coordinator?.queue.refreshAfterExternalMutation()
            },
            revealQueueEntry: { [weak coordinator] entryID in
                coordinator?.queue.reveal(id: entryID)
            }
        )
    }

    init(
        markDone: @escaping @MainActor (URL) async throws -> Void,
        snooze: @escaping @MainActor (URL) async throws -> Void,
        refreshQueue: @escaping @MainActor () -> Void = {},
        queueDidMutate: @escaping @MainActor () -> Void = {},
        revealQueueEntry: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.markDone = markDone
        self.snooze = snooze
        self.refreshQueueHandler = refreshQueue
        self.queueDidMutateHandler = queueDidMutate
        self.revealQueueEntry = revealQueueEntry
        super.init()
    }

    public func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(
            identifier: QueueNotification.doneAction,
            title: "Done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: QueueNotification.snoozeAction,
            title: "Snooze 1h",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: QueueNotification.category,
                actions: [done, snooze],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A firing notification means an item just crossed its date — a
        // pinned queue panel showing it as future-dated is now lying.
        await refreshQueue()
        return [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        await handle(
            action: response.actionIdentifier,
            entryID: info["entry_id"] as? String,
            path: info["path"] as? String
        )
    }

    func handle(action: String, entryID: String?, path: String?) async {
        switch action {
        case QueueNotification.doneAction:
            guard let path else { return }
            do {
                try await markDone(URL(fileURLWithPath: path))
                queueDidMutateHandler()
            } catch {
                log.error("mark done from notification failed: \(String(describing: error), privacy: .public)")
                refreshQueue()
            }
        case QueueNotification.snoozeAction:
            guard let path else { return }
            do {
                try await snooze(URL(fileURLWithPath: path))
                queueDidMutateHandler()
            } catch {
                log.error("snooze from notification failed: \(String(describing: error), privacy: .public)")
                refreshQueue()
            }
        case UNNotificationDefaultActionIdentifier:
            revealQueueEntry(entryID)
        default:
            break
        }
    }

    private func refreshQueue() {
        refreshQueueHandler()
    }
}

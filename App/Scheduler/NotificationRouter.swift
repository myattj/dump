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
    private weak var coordinator: AppCoordinator?
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "notifications")

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
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

    private func handle(action: String, entryID: String?, path: String?) async {
        guard let coordinator else { return }
        switch action {
        case QueueNotification.doneAction:
            guard let path else { return }
            do {
                try await coordinator.scheduler.snoozeNotification(entryURL: URL(fileURLWithPath: path))
            } catch {
                log.error("snooze from notification failed: \(String(describing: error), privacy: .public)")
            }
            coordinator.queue.refresh()
        case QueueNotification.snoozeAction:
            guard let path else { return }
            do {
                try await coordinator.scheduler.markDone(entryURL: URL(fileURLWithPath: path))
            } catch {
                log.error("mark done from notification failed: \(String(describing: error), privacy: .public)")
            }
            coordinator.queue.refresh()
        case UNNotificationDefaultActionIdentifier:
            coordinator.queue.reveal(id: entryID)
        default:
            break
        }
    }

    private func refreshQueue() {
        coordinator?.queue.refresh()
    }
}

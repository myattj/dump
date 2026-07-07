import Foundation
import UserNotifications

/// Identifiers shared between the scheduling adapter (which stamps the
/// category on outgoing notifications) and `NotificationRouter` (which
/// registers the category's actions and handles responses).
public enum QueueNotification {
    public static let category = "dump.queue.item"
    public static let doneAction = "dump.action.done"
    public static let snoozeAction = "dump.action.snooze1h"
}

/// Abstraction over `UNUserNotificationCenter` so tests can verify what was
/// scheduled without hitting the real notification subsystem.
public protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func schedule(id: String, title: String, body: String, fireAt: Date, userInfo: [String: String]) async throws
    func cancel(ids: [String]) async
    func pending() async -> Set<String>
}

public struct UserNotificationCenterAdapter: NotificationScheduling {
    public init() {}

    public func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func schedule(id: String, title: String, body: String, fireAt: Date, userInfo: [String: String]) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        content.categoryIdentifier = QueueNotification.category

        // Calendar triggers key on wall-clock time, so a Mac that was asleep
        // at the fire time delivers on wake — interval triggers pause while
        // asleep and drift by the sleep duration.
        let trigger: UNNotificationTrigger
        if fireAt.timeIntervalSinceNow > 1 {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireAt
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    public func cancel(ids: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func pending() async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier))
    }
}

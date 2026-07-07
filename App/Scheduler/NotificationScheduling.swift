import Foundation
import UserNotifications

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
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
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

        let trigger: UNNotificationTrigger
        let interval = fireAt.timeIntervalSinceNow
        if interval > 0 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
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

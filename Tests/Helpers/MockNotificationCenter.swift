import Foundation
import os
@testable import Dump

public final class MockNotificationCenter: NotificationScheduling, @unchecked Sendable {
    public struct Scheduled: Equatable, Sendable {
        public let id: String
        public let title: String
        public let body: String
        public let fireAt: Date
        public let userInfo: [String: String]
    }

    private struct State: Sendable {
        var scheduled: [Scheduled] = []
        var cancelled: [String] = []
        var authorized: Bool = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var scheduled: [Scheduled] { state.withLock { $0.scheduled } }
    public var cancelled: [String] { state.withLock { $0.cancelled } }
    public var authorized: Bool {
        get { state.withLock { $0.authorized } }
        set { state.withLock { $0.authorized = newValue } }
    }

    public func requestAuthorizationIfNeeded() async -> Bool {
        state.withLock { $0.authorized }
    }

    public func schedule(id: String, title: String, body: String, fireAt: Date, userInfo: [String: String]) async throws {
        state.withLock {
            $0.scheduled.append(Scheduled(id: id, title: title, body: body, fireAt: fireAt, userInfo: userInfo))
        }
    }

    public func cancel(ids: [String]) async {
        state.withLock {
            $0.cancelled.append(contentsOf: ids)
            $0.scheduled.removeAll { ids.contains($0.id) }
        }
    }

    public func pending() async -> Set<String> {
        state.withLock { Set($0.scheduled.map(\.id)) }
    }
}

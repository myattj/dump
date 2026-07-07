import Foundation

public struct QueueRanker: Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let createdAt: Date
        public let deadlineAt: Date?
        public let scheduledAt: Date?
        public let effortMinutes: Int?

        public init(
            id: String,
            createdAt: Date,
            deadlineAt: Date? = nil,
            scheduledAt: Date? = nil,
            effortMinutes: Int? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.deadlineAt = deadlineAt
            self.scheduledAt = scheduledAt
            self.effortMinutes = effortMinutes
        }
    }

    public struct RankedEntry: Equatable, Sendable {
        public let entry: Entry
        public let rank: Int
        public let score: Double
    }

    public init() {}

    public func rank(_ entries: [Entry], now: Date = Date()) -> [RankedEntry] {
        entries
            .map { entry in
                RankedEntry(entry: entry, rank: 0, score: score(for: entry, now: now))
            }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.0001 {
                    return lhs.score < rhs.score
                }
                let lhsDate = priorityDate(for: lhs.entry) ?? .distantFuture
                let rhsDate = priorityDate(for: rhs.entry) ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                let lhsEffort = normalizedEffort(lhs.entry.effortMinutes)
                let rhsEffort = normalizedEffort(rhs.entry.effortMinutes)
                if lhsEffort != rhsEffort { return lhsEffort < rhsEffort }
                if lhs.entry.createdAt != rhs.entry.createdAt {
                    return lhs.entry.createdAt < rhs.entry.createdAt
                }
                return lhs.entry.id < rhs.entry.id
            }
            .enumerated()
            .map { idx, ranked in
                RankedEntry(entry: ranked.entry, rank: idx + 1, score: ranked.score)
            }
    }

    public func score(for entry: Entry, now: Date = Date()) -> Double {
        let effort = Double(normalizedEffort(entry.effortMinutes))
        let ageDays = max(0, now.timeIntervalSince(entry.createdAt) / Self.day)

        if let date = priorityDate(for: entry) {
            let minutesUntil = date.timeIntervalSince(now) / 60
            let boundedMinutes = min(max(minutesUntil, -Self.weekMinutes), Self.fortyFiveDayMinutes)
            let ageNudge = min(ageDays, 30) * -6
            return boundedMinutes + effort * 2 + ageNudge
        }

        let noDeadlineBase = 21 * 24 * 60.0
        let ageNudge = min(ageDays, 30) * -30
        return noDeadlineBase + effort * 6 + ageNudge
    }

    private func priorityDate(for entry: Entry) -> Date? {
        entry.deadlineAt ?? entry.scheduledAt
    }

    private func normalizedEffort(_ effort: Int?) -> Int {
        min(max(effort ?? 30, 5), 480)
    }

    private static let day = 86_400.0
    private static let weekMinutes = 7 * 24 * 60.0
    private static let fortyFiveDayMinutes = 45 * 24 * 60.0
}

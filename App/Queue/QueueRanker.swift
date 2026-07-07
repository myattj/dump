import Foundation

/// Ranks queue entries by urgency, highest score first.
///
/// The model: each entry gets an urgency in (0, 1) from whichever signal
/// applies — slack until its deadline (time remaining minus a working
/// buffer for the estimated effort, squashed through a sigmoid so overdue
/// saturates and far-future compresses), time since its reminder fired,
/// or a slow age creep for undated items. Importance scales that urgency
/// multiplicatively, so an unimportant deadline still rises as it nears —
/// it just rises later. Snoozed and not-yet-due reminders drop into the
/// `.later` bucket below every actionable item, ordered by wake time.
public struct QueueRanker: Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let createdAt: Date
        public let deadlineAt: Date?
        public let scheduledAt: Date?
        public let effortMinutes: Int?
        public let importance: Int?
        public let snoozedUntil: Date?
        public let snoozeCount: Int

        public init(
            id: String,
            createdAt: Date,
            deadlineAt: Date? = nil,
            scheduledAt: Date? = nil,
            effortMinutes: Int? = nil,
            importance: Int? = nil,
            snoozedUntil: Date? = nil,
            snoozeCount: Int = 0
        ) {
            self.id = id
            self.createdAt = createdAt
            self.deadlineAt = deadlineAt
            self.scheduledAt = scheduledAt
            self.effortMinutes = effortMinutes
            self.importance = importance
            self.snoozedUntil = snoozedUntil
            self.snoozeCount = snoozeCount
        }
    }

    public enum Bucket: Equatable, Sendable {
        /// Actionable now — ranked by score, highest first.
        case now
        /// Snoozed or scheduled for later — held below `.now`, ordered by wake time.
        case later
    }

    public struct RankedEntry: Equatable, Sendable {
        public let entry: Entry
        public let rank: Int
        public let score: Double
        public let bucket: Bucket
        /// When a `.later` entry becomes actionable again.
        public let wakeAt: Date?
    }

    public init() {}

    public func rank(_ entries: [Entry], now: Date = Date()) -> [RankedEntry] {
        entries
            .map { entry -> RankedEntry in
                let bucket = bucket(for: entry, now: now)
                return RankedEntry(
                    entry: entry,
                    rank: 0,
                    score: bucket == .now ? score(for: entry, now: now) : 0,
                    bucket: bucket,
                    wakeAt: bucket == .later ? wakeDate(for: entry, now: now) : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.bucket != rhs.bucket { return lhs.bucket == .now }
                if lhs.bucket == .later {
                    let lhsWake = lhs.wakeAt ?? .distantFuture
                    let rhsWake = rhs.wakeAt ?? .distantFuture
                    if lhsWake != rhsWake { return lhsWake < rhsWake }
                } else if abs(lhs.score - rhs.score) > 0.0001 {
                    return lhs.score > rhs.score
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
                RankedEntry(
                    entry: ranked.entry,
                    rank: idx + 1,
                    score: ranked.score,
                    bucket: ranked.bucket,
                    wakeAt: ranked.wakeAt
                )
            }
    }

    public func bucket(for entry: Entry, now: Date = Date()) -> Bucket {
        if let snoozed = entry.snoozedUntil, snoozed > now { return .later }
        if entry.deadlineAt == nil,
           let scheduled = entry.scheduledAt,
           scheduled.timeIntervalSince(now) > Self.reminderLeadWindow {
            return .later
        }
        return .now
    }

    public func wakeDate(for entry: Entry, now: Date = Date()) -> Date? {
        var candidates: [Date] = []
        if let snoozed = entry.snoozedUntil, snoozed > now { candidates.append(snoozed) }
        if entry.deadlineAt == nil,
           let scheduled = entry.scheduledAt,
           scheduled.timeIntervalSince(now) > Self.reminderLeadWindow {
            candidates.append(scheduled.addingTimeInterval(-Self.reminderLeadWindow))
        }
        return candidates.max()
    }

    public func score(for entry: Entry, now: Date = Date()) -> Double {
        urgency(for: entry, now: now) * importanceMultiplier(for: entry) + quickWinBonus(for: entry, now: now)
    }

    /// In (0, 1); the strongest applicable time signal.
    func urgency(for entry: Entry, now: Date = Date()) -> Double {
        var components: [Double] = []

        if let deadline = entry.deadlineAt {
            let effortSeconds = Double(normalizedEffort(entry.effortMinutes)) * 60
            let slack = deadline.timeIntervalSince(now) - effortSeconds * Self.effortBuffer
            components.append(sigmoid(-slack / Self.deadlineTau))
        }

        if let scheduled = entry.scheduledAt {
            let until = scheduled.timeIntervalSince(now)
            if until <= Self.reminderLeadWindow {
                components.append(sigmoid(-until / Self.reminderTau))
            }
        }

        if entry.deadlineAt == nil && entry.scheduledAt == nil {
            let ageDays = max(0, now.timeIntervalSince(entry.createdAt) / Self.day)
            let creep = sigmoid((ageDays - Self.ageCreepMidpointDays) / Self.ageCreepWidthDays)
            components.append(Self.undatedFloor + (1 - Self.undatedFloor) * creep)
        }

        return components.max() ?? Self.undatedFloor
    }

    /// 0.75x (low) … 1.5x (critical); normal is 1.0x. Each snooze decays
    /// the underlying importance slightly — repeatedly deferred items
    /// stop shouting.
    func importanceMultiplier(for entry: Entry) -> Double {
        let value = Double(min(max(entry.importance ?? 2, 1), 4)) * 0.25
        let decayed = value * pow(Self.snoozeDecay, Double(min(entry.snoozeCount, 5)))
        return 0.5 + decayed
    }

    /// Small nudge so short undated tasks float above equally-stale long
    /// ones. Never applies to dated entries — effort already shapes their
    /// slack, and a bonus there could outrank a genuinely tighter deadline.
    private func quickWinBonus(for entry: Entry, now: Date) -> Double {
        guard entry.deadlineAt == nil, entry.scheduledAt == nil,
              let effort = entry.effortMinutes, effort <= 15 else {
            return 0
        }
        return 0.04
    }

    private func priorityDate(for entry: Entry) -> Date? {
        entry.deadlineAt ?? entry.scheduledAt
    }

    private func normalizedEffort(_ effort: Int?) -> Int {
        min(max(effort ?? 30, 5), 480)
    }

    private func sigmoid(_ x: Double) -> Double {
        1 / (1 + exp(-x))
    }

    private static let day = 86_400.0
    /// Sigmoid width for deadline slack: ~0.5 at zero slack, ~0.27 with two
    /// days of slack, ~0.97 a week overdue.
    private static let deadlineTau = 2 * day
    /// Working buffer applied to the effort estimate when computing slack —
    /// a 2h task starts ramping ~4h before its deadline, not 2h.
    private static let effortBuffer = 2.0
    /// Reminders surface this long before their fire time.
    private static let reminderLeadWindow = 30 * 60.0
    /// Sigmoid width for fired reminders: 0.5 at fire time, ~0.98 a day later.
    private static let reminderTau = day / 4
    /// Undated items start here and creep toward 1.0 with age so backlog
    /// never rots invisibly, crossing 0.5 at the midpoint.
    private static let undatedFloor = 0.08
    private static let ageCreepMidpointDays = 21.0
    private static let ageCreepWidthDays = 5.0
    private static let snoozeDecay = 0.9
}

struct QueueMetadataExtractor: Sendable {
    struct Result: Equatable, Sendable {
        let inferredType: Frontmatter.EntryType?
        let deadlineAt: Date?
        let scheduledAt: Date?
        let effortMinutes: Int?
        let importance: Int?
    }

    static func extract(
        from text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Result {
        let isReminder = contains(text, pattern: "\\b(?:remind me|notify me|alert me|ping me)\\b")
        let inferredType: Frontmatter.EntryType? = if isReminder {
            .reminder
        } else if looksActionable(text) {
            .task
        } else {
            nil
        }

        let date = parsedDate(from: text, now: now, defaultHour: isReminder ? 9 : 17, calendar: calendar)
        return Result(
            inferredType: inferredType,
            deadlineAt: isReminder ? nil : date,
            scheduledAt: isReminder ? date : nil,
            effortMinutes: parsedEffort(from: text),
            importance: parsedImportance(from: text)
        )
    }

    /// First line of `body` with capture syntax tokens (trailing bangs,
    /// `~30m` effort markers) removed, for display as a title.
    static func displayTitle(from body: String) -> String? {
        guard var line = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) else {
            return nil
        }
        for pattern in ["(?:^|\\s)!{1,4}(?=\\s|$)", "(?:^|\\s)~\\d+(?:\\.\\d+)?\\s*(?:m|min|mins|minutes|h|hr|hrs|hours)\\b"] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
            }
        }
        let cleaned = line
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parsedImportance(from text: String) -> Int? {
        if let match = firstMatch(in: text, pattern: "(!{1,4})(?=\\s|$)") {
            return match[0].count >= 2 ? 4 : 3
        }
        if contains(text, pattern: "\\b(?:urgent|asap|critical|top priority)\\b") {
            return 4
        }
        if contains(text, pattern: "\\b(?:important|high priority)\\b") {
            return 3
        }
        if contains(text, pattern: "\\b(?:low priority|someday|eventually|no rush|whenever)\\b") {
            return 1
        }
        return nil
    }

    private struct ParsedTime {
        let hour: Int
        let minute: Int
    }

    private static func looksActionable(_ text: String) -> Bool {
        contains(
            text,
            pattern: "\\b(?:todo|to do|task|need to|needs to|have to|must|should|call|email|send|finish|fix|write|review|follow up|pay|book|schedule|submit|ship|deploy|renew|cancel|prepare|buy|pick up)\\b"
        )
    }

    private static func parsedEffort(from text: String) -> Int? {
        if let match = firstMatch(
            in: text,
            pattern: "\\b(\\d{1,4})\\s*(?:m|min|mins|minute|minutes)\\b"
        ), let minutes = Int(match[0]) {
            return minutes
        }

        if let match = firstMatch(
            in: text,
            pattern: "\\b(\\d{1,2}(?:\\.\\d+)?)\\s*(?:h|hr|hrs|hour|hours)\\b"
        ), let hours = Double(match[0]) {
            return Int((hours * 60).rounded())
        }

        if contains(text, pattern: "\\bquick\\b") {
            return 10
        }

        if contains(text, pattern: "\\b(?:deep work|focus block)\\b") {
            return 120
        }

        return nil
    }

    private static func parsedDate(
        from text: String,
        now: Date,
        defaultHour: Int,
        calendar: Calendar
    ) -> Date? {
        let time = parsedTime(from: text)

        if let relative = relativeDate(from: text, now: now, calendar: calendar) {
            return relative
        }

        if let explicit = explicitDate(from: text, now: now, time: time, defaultHour: defaultHour, calendar: calendar) {
            return explicit
        }

        if contains(text, pattern: "\\btonight\\b") {
            return date(daysFrom: 0, now: now, time: time, defaultHour: 20, calendar: calendar)
        }

        if contains(text, pattern: "\\btomorrow\\b") {
            return date(daysFrom: 1, now: now, time: time, defaultHour: defaultHour, calendar: calendar)
        }

        if contains(text, pattern: "\\btoday\\b") {
            return date(daysFrom: 0, now: now, time: time, defaultHour: defaultHour, calendar: calendar)
        }

        if contains(text, pattern: "\\bnext week\\b") {
            return date(daysFrom: 7, now: now, time: time, defaultHour: defaultHour, calendar: calendar)
        }

        if let weekday = weekdayDate(from: text, now: now, time: time, defaultHour: defaultHour, calendar: calendar) {
            return weekday
        }

        return nil
    }

    private static func relativeDate(from text: String, now: Date, calendar: Calendar) -> Date? {
        guard let match = firstMatch(
            in: text,
            pattern: "\\bin\\s+(\\d{1,3})\\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)\\b"
        ), let value = Int(match[0]) else {
            return nil
        }

        let unit = match[1].lowercased()
        if unit.hasPrefix("m") {
            return calendar.date(byAdding: .minute, value: value, to: now)
        }
        if unit.hasPrefix("h") {
            return calendar.date(byAdding: .hour, value: value, to: now)
        }
        if unit.hasPrefix("w") {
            return calendar.date(byAdding: .day, value: value * 7, to: now)
        }
        return calendar.date(byAdding: .day, value: value, to: now)
    }

    private static func explicitDate(
        from text: String,
        now: Date,
        time: ParsedTime?,
        defaultHour: Int,
        calendar: Calendar
    ) -> Date? {
        if let match = firstMatch(in: text, pattern: "\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b"),
           let year = Int(match[0]), let month = Int(match[1]), let day = Int(match[2]) {
            return date(year: year, month: month, day: day, time: time, defaultHour: defaultHour, calendar: calendar)
        }

        guard let match = firstMatch(in: text, pattern: "\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b"),
              let month = Int(match[0]), let day = Int(match[1]) else {
            return nil
        }

        var year = match[2].nilIfEmpty.flatMap(Int.init) ?? calendar.component(.year, from: now)
        if year < 100 { year += 2000 }

        guard let candidate = date(year: year, month: month, day: day, time: time, defaultHour: defaultHour, calendar: calendar) else {
            return nil
        }
        if match[2].nilIfEmpty == nil && candidate < calendar.startOfDay(for: now) {
            return date(year: year + 1, month: month, day: day, time: time, defaultHour: defaultHour, calendar: calendar)
        }
        return candidate
    }

    private static func weekdayDate(
        from text: String,
        now: Date,
        time: ParsedTime?,
        defaultHour: Int,
        calendar: Calendar
    ) -> Date? {
        let weekdays: [(String, Int)] = [
            ("sun(?:day)?", 1),
            ("mon(?:day)?", 2),
            ("tue(?:sday)?", 3),
            ("wed(?:nesday)?", 4),
            ("thu(?:rsday)?", 5),
            ("fri(?:day)?", 6),
            ("sat(?:urday)?", 7),
        ]

        for (pattern, weekday) in weekdays where contains(text, pattern: "\\b(?:next\\s+)?\(pattern)\\b") {
            let current = calendar.component(.weekday, from: now)
            var days = (weekday - current + 7) % 7
            if days == 0 { days = 7 }
            return date(daysFrom: days, now: now, time: time, defaultHour: defaultHour, calendar: calendar)
        }
        return nil
    }

    private static func parsedTime(from text: String) -> ParsedTime? {
        if let match = firstMatch(
            in: text,
            pattern: "\\b(?:at|by|@)?\\s*(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b"
        ), let hour = Int(match[0]) {
            return ParsedTime(hour: hourIn24(hour, meridiem: match[2]), minute: Int(match[1]) ?? 0)
        }

        if let match = firstMatch(
            in: text,
            pattern: "\\b(?:at|by|@)\\s*(\\d{1,2}):(\\d{2})\\b"
        ), let hour = Int(match[0]), let minute = Int(match[1]) {
            return ParsedTime(hour: hour, minute: minute)
        }

        return nil
    }

    private static func date(
        daysFrom offset: Int,
        now: Date,
        time: ParsedTime?,
        defaultHour: Int,
        calendar: Calendar
    ) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return calendar.date(
            bySettingHour: time?.hour ?? defaultHour,
            minute: time?.minute ?? 0,
            second: 0,
            of: day
        )
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        time: ParsedTime?,
        defaultHour: Int,
        calendar: Calendar
    ) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            year: year,
            month: month,
            day: day,
            hour: time?.hour ?? defaultHour,
            minute: time?.minute ?? 0
        ))
    }

    private static func hourIn24(_ hour: Int, meridiem: String) -> Int {
        let normalized = hour % 12
        return meridiem.lowercased() == "pm" ? normalized + 12 : normalized
    }

    private static func contains(_ text: String, pattern: String) -> Bool {
        firstMatch(in: text, pattern: pattern) != nil
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { idx in
            let range = match.range(at: idx)
            guard let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

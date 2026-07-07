import Foundation

public struct QueueItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let body: String
    public let type: Frontmatter.EntryType
    public let createdAt: Date
    public let deadlineAt: Date?
    public let scheduledAt: Date?
    public let effortMinutes: Int?
    public let queueRank: Int
    public let queueScore: Double
    public let metadataConfidence: Double?
    public let tags: [String]

    public var priorityAt: Date? {
        deadlineAt ?? scheduledAt
    }
}

public actor QueueStore {
    public struct UndoRecord: Equatable, Sendable {
        public let url: URL
        public let frontmatter: Frontmatter
    }

    private struct ScannedEntry: Sendable {
        let url: URL
        let frontmatter: Frontmatter
        let body: String
    }

    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let scheduler: SchedulerService
    private let ranker: QueueRanker

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        scheduler: SchedulerService,
        ranker: QueueRanker = QueueRanker()
    ) {
        self.storage = storage
        self.writer = writer
        self.scheduler = scheduler
        self.ranker = ranker
    }

    @discardableResult
    public func reconcile(now: Date = Date()) async throws -> [QueueItem] {
        let scanned = scanInbox()
        let entries = scanned.map { entry in
            QueueRanker.Entry(
                id: entry.frontmatter.id,
                createdAt: entry.frontmatter.createdAt,
                deadlineAt: entry.frontmatter.deadlineAt,
                scheduledAt: entry.frontmatter.type == .reminder ? entry.frontmatter.scheduledAt : nil,
                effortMinutes: entry.frontmatter.effortMinutes
            )
        }
        let ranked = ranker.rank(entries, now: now)
        let rankByID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.entry.id, $0) })

        var items: [QueueItem] = []
        for entry in scanned {
            guard let rank = rankByID[entry.frontmatter.id] else { continue }
            var fm = entry.frontmatter
            if fm.queueRank != rank.rank || scoreChanged(fm.queueScore, rank.score) {
                fm.queueRank = rank.rank
                fm.queueScore = rank.score
                try writer.rewriteFrontmatter(at: entry.url, with: fm)
            }
            items.append(makeItem(from: entry, rank: rank))
        }

        return items.sorted { lhs, rhs in
            if lhs.queueRank != rhs.queueRank { return lhs.queueRank < rhs.queueRank }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public func markDone(_ item: QueueItem, completedAt: Date = Date()) async throws -> UndoRecord {
        let raw = try String(contentsOf: item.url, encoding: .utf8)
        let (fm, _) = try FrontmatterCodec.decode(raw)
        try await scheduler.markDone(entryURL: item.url, completedAt: completedAt)
        return UndoRecord(url: item.url, frontmatter: fm)
    }

    public func undo(_ record: UndoRecord) async throws {
        try writer.rewriteFrontmatter(at: record.url, with: record.frontmatter)
        _ = await scheduler.reconcile()
    }

    private func scanInbox() -> [ScannedEntry] {
        let inbox = storage.subdirectory(.inbox)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let raw = try? String(contentsOf: url, encoding: .utf8),
                      let (fm, body) = try? FrontmatterCodec.decode(raw),
                      fm.status == .active,
                      fm.type == .task || fm.type == .reminder else {
                    return nil
                }
                return ScannedEntry(url: url, frontmatter: fm, body: body)
            }
    }

    private func makeItem(from entry: ScannedEntry, rank: QueueRanker.RankedEntry) -> QueueItem {
        QueueItem(
            id: entry.frontmatter.id,
            url: entry.url,
            title: entry.frontmatter.title ?? Self.title(from: entry.body),
            body: entry.body,
            type: entry.frontmatter.type,
            createdAt: entry.frontmatter.createdAt,
            deadlineAt: entry.frontmatter.deadlineAt,
            scheduledAt: entry.frontmatter.type == .reminder ? entry.frontmatter.scheduledAt : nil,
            effortMinutes: entry.frontmatter.effortMinutes,
            queueRank: rank.rank,
            queueScore: rank.score,
            metadataConfidence: entry.frontmatter.metadataConfidence,
            tags: entry.frontmatter.tags
        )
    }

    private func scoreChanged(_ existing: Double?, _ next: Double) -> Bool {
        guard let existing else { return true }
        return abs(existing - next) > 0.0001
    }

    private static func title(from body: String) -> String {
        body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Untitled task"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

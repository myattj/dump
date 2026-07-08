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
    public let importance: Int?
    public let snoozedUntil: Date?
    public let snoozeCount: Int
    public let queueRank: Int
    public let queueScore: Double
    public let isLater: Bool
    public let wakeAt: Date?
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
        let hydrated = scanned.map(hydrateQueueMetadata)
        let entries = hydrated.map { entry in
            QueueRanker.Entry(
                id: entry.frontmatter.id,
                createdAt: entry.frontmatter.createdAt,
                deadlineAt: entry.frontmatter.deadlineAt,
                scheduledAt: entry.frontmatter.type == .reminder ? entry.frontmatter.scheduledAt : nil,
                effortMinutes: entry.frontmatter.effortMinutes,
                importance: entry.frontmatter.importance,
                snoozedUntil: entry.frontmatter.snoozedUntil,
                snoozeCount: entry.frontmatter.snoozeCount ?? 0
            )
        }
        let ranked = ranker.rank(entries, now: now)
        let rankByID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.entry.id, $0) })

        var items: [QueueItem] = []
        var metadataWritten = false
        for idx in hydrated.indices {
            let entry = hydrated[idx]
            let original = scanned[idx]
            guard let rank = rankByID[entry.frontmatter.id] else { continue }
            var fm = entry.frontmatter
            // Score drifts continuously with `now`; only a rank or metadata
            // change is worth a disk write (and the re-index it triggers).
            let metadataChanged = queueMetadataChanged(from: original.frontmatter, to: fm)
            if metadataChanged || fm.queueRank != rank.rank {
                fm.queueRank = rank.rank
                fm.queueScore = rank.score
                try writer.rewriteFrontmatter(at: entry.url, with: fm)
                metadataWritten = metadataWritten || metadataChanged
            }
            items.append(makeItem(from: entry, rank: rank))
        }

        // A hydrated deadline or schedule is a new fire date the scheduler
        // hasn't seen — arm it now rather than waiting for the next capture.
        if metadataWritten {
            _ = await scheduler.reconcile(now: now)
        }

        return items.sorted { lhs, rhs in
            if lhs.queueRank != rhs.queueRank { return lhs.queueRank < rhs.queueRank }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func hydrateQueueMetadata(_ entry: ScannedEntry) -> ScannedEntry {
        guard entry.frontmatter.metadataEdited != true else { return entry }
        let metadata = QueueMetadataExtractor.extract(from: entry.body, now: entry.frontmatter.createdAt)
        var fm = entry.frontmatter
        if fm.deadlineAt == nil {
            fm.deadlineAt = metadata.deadlineAt
        }
        if fm.type == .reminder, fm.scheduledAt == nil {
            fm.scheduledAt = metadata.scheduledAt
        }
        if fm.effortMinutes == nil {
            fm.effortMinutes = metadata.effortMinutes
        }
        if fm.importance == nil {
            fm.importance = metadata.importance
        }
        return ScannedEntry(url: entry.url, frontmatter: fm, body: entry.body)
    }

    private func queueMetadataChanged(from lhs: Frontmatter, to rhs: Frontmatter) -> Bool {
        lhs.deadlineAt != rhs.deadlineAt
            || lhs.scheduledAt != rhs.scheduledAt
            || lhs.effortMinutes != rhs.effortMinutes
            || lhs.importance != rhs.importance
            || lhs.snoozedUntil != rhs.snoozedUntil
            || lhs.snoozeCount != rhs.snoozeCount
    }

    public func markDone(_ item: QueueItem, completedAt: Date = Date()) async throws -> UndoRecord {
        let raw = try String(contentsOf: item.url, encoding: .utf8)
        let (fm, _) = try FrontmatterCodec.decode(raw)
        try await scheduler.markDone(entryURL: item.url, completedAt: completedAt)
        return UndoRecord(url: item.url, frontmatter: fm)
    }

    @discardableResult
    public func snooze(_ item: QueueItem, until: Date) async throws -> UndoRecord {
        try update(item) { fm in
            fm.snoozedUntil = until
            fm.snoozeCount = (fm.snoozeCount ?? 0) + 1
        }
    }

    @discardableResult
    public func wake(_ item: QueueItem) async throws -> UndoRecord {
        try update(item) { fm in
            fm.snoozedUntil = nil
        }
    }

    /// Applies a user edit to queue metadata and marks the entry as
    /// user-edited so the classifier and body re-extraction stop
    /// overriding it.
    @discardableResult
    public func editMetadata(
        _ item: QueueItem,
        mutate: @Sendable (inout Frontmatter) -> Void
    ) async throws -> UndoRecord {
        try update(item) { fm in
            mutate(&fm)
            fm.metadataEdited = true
        }
    }

    private func update(
        _ item: QueueItem,
        mutate: (inout Frontmatter) -> Void
    ) throws -> UndoRecord {
        let raw = try String(contentsOf: item.url, encoding: .utf8)
        var (fm, _) = try FrontmatterCodec.decode(raw)
        let undo = UndoRecord(url: item.url, frontmatter: fm)
        mutate(&fm)
        try writer.rewriteFrontmatter(at: item.url, with: fm)
        return undo
    }

    public func undo(_ record: UndoRecord) async throws {
        try writer.rewriteFrontmatter(at: record.url, with: record.frontmatter)
        _ = await scheduler.reconcile()
    }

    /// Writes a newly captured entry into the inbox. Runs on the store's
    /// actor so the file IO doesn't block the main actor during capture.
    public func add(
        body: String,
        seed: @escaping @Sendable (inout Frontmatter) -> Void
    ) throws -> MarkdownWriter.WriteResult {
        try writer.write(body: body, into: storage.subdirectory(.inbox), source: .capture, seedFrontmatter: seed)
    }

    /// Merges classifier output into an existing entry's frontmatter. Runs
    /// on the store's actor so the read/decode/rewrite happens off the main
    /// actor.
    public func applyClassification(
        at url: URL,
        merge: @Sendable (inout Frontmatter) -> Void
    ) throws {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var (fm, _) = try FrontmatterCodec.decode(raw)
        merge(&fm)
        try writer.rewriteFrontmatter(at: url, with: fm)
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
            title: entry.frontmatter.title ?? QueueMetadataExtractor.displayTitle(from: entry.body) ?? "Untitled task",
            body: entry.body,
            type: entry.frontmatter.type,
            createdAt: entry.frontmatter.createdAt,
            deadlineAt: entry.frontmatter.deadlineAt,
            scheduledAt: entry.frontmatter.type == .reminder ? entry.frontmatter.scheduledAt : nil,
            effortMinutes: entry.frontmatter.effortMinutes,
            importance: entry.frontmatter.importance,
            snoozedUntil: entry.frontmatter.snoozedUntil,
            snoozeCount: entry.frontmatter.snoozeCount ?? 0,
            queueRank: rank.rank,
            queueScore: rank.score,
            isLater: rank.bucket == .later,
            wakeAt: rank.wakeAt,
            metadataConfidence: entry.frontmatter.metadataConfidence,
            tags: entry.frontmatter.tags
        )
    }
}

import Foundation
import OSLog

/// Walks the inbox + meeting folders, finds active entries with a fire
/// date — `scheduled_at`, or `deadline_at` for tasks that only carry a
/// deadline — and reconciles the OS notification queue with them. Run on
/// launch and after every classification.
public actor SchedulerService {
    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let notifications: NotificationScheduling
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "scheduler")

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        notifications: NotificationScheduling
    ) {
        self.storage = storage
        self.writer = writer
        self.notifications = notifications
    }

    @discardableResult
    public func reconcile(now: Date = Date()) async -> Outcome {
        let candidates = enumerateCandidates()
        let pending = await notifications.pending()

        var scheduled: [String] = []
        var cancelled: [String] = []
        var canScheduleNotifications: Bool?

        for entry in candidates {
            let fireAt = Self.fireDate(for: entry.frontmatter)
            if entry.frontmatter.status == .active, let fireAt, fireAt > now {
                let nid = entry.frontmatter.notificationId ?? entry.frontmatter.id
                if !pending.contains(nid) {
                    if canScheduleNotifications == nil {
                        canScheduleNotifications = await notifications.requestAuthorizationIfNeeded()
                    }
                    guard canScheduleNotifications == true else { continue }

                    do {
                        try await notifications.schedule(
                            id: nid,
                            title: entry.frontmatter.title ?? "Reminder",
                            body: entry.preview,
                            fireAt: fireAt,
                            userInfo: ["entry_id": entry.frontmatter.id, "path": entry.url.path]
                        )

                        let current = try currentFrontmatter(at: entry.url)
                        guard current.status == .active, Self.fireDate(for: current) == fireAt else {
                            await notifications.cancel(ids: [nid])
                            cancelled.append(nid)
                            continue
                        }

                        scheduled.append(nid)
                        if current.notificationId == nil {
                            var updated = current
                            updated.notificationId = nid
                            try writer.rewriteFrontmatter(at: entry.url, with: updated)
                        }
                    } catch {
                        log.error("schedule failed for \(nid, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            } else if let nid = entry.frontmatter.notificationId, pending.contains(nid) {
                await notifications.cancel(ids: [nid])
                cancelled.append(nid)
            }
        }

        return Outcome(scheduled: scheduled, cancelled: cancelled)
    }

    /// A `scheduled_at` is an explicit "tell me then"; a task that only has
    /// a deadline still deserves to ring at that deadline instead of
    /// staying silent.
    static func fireDate(for fm: Frontmatter) -> Date? {
        fm.scheduledAt ?? fm.deadlineAt
    }

    /// Re-arms an entry's notification `interval` seconds from `now` — the
    /// banner's "Snooze 1h" action. Writes `scheduled_at` so the next
    /// reconcile agrees with the new fire time instead of cancelling it;
    /// ranking ignores `scheduled_at` on tasks, so a task's deadline and
    /// queue position are untouched.
    public func snoozeNotification(
        entryURL: URL,
        for interval: TimeInterval = 3_600,
        now: Date = Date()
    ) async throws {
        let raw = try String(contentsOf: entryURL, encoding: .utf8)
        var (fm, _) = try FrontmatterCodec.decode(raw)
        guard fm.status == .active else { return }
        fm.scheduledAt = now.addingTimeInterval(interval)
        try writer.rewriteFrontmatter(at: entryURL, with: fm)
        if let nid = fm.notificationId {
            await notifications.cancel(ids: [nid])
        }
        await reconcile(now: now)
    }

    public func markDone(entryURL: URL, completedAt: Date = Date()) async throws {
        let raw = try String(contentsOf: entryURL, encoding: .utf8)
        var (fm, _) = try FrontmatterCodec.decode(raw)
        fm.status = .done
        fm.completedAt = completedAt
        try writer.rewriteFrontmatter(at: entryURL, with: fm)
        if let nid = fm.notificationId {
            await notifications.cancel(ids: [nid])
        }
    }

    /// Clears every pending request owned by Dump. Used before changing the
    /// storage root so notifications cannot retain paths into the old root.
    public func cancelAllPending() async {
        let ids = Array(await notifications.pending())
        guard !ids.isEmpty else { return }
        await notifications.cancel(ids: ids)
    }

    public struct Outcome: Equatable, Sendable {
        public let scheduled: [String]
        public let cancelled: [String]
    }

    public struct Entry: Sendable {
        public let url: URL
        public let frontmatter: Frontmatter
        public let preview: String
    }

    func enumerateCandidates() -> [Entry] {
        var entries: [Entry] = []
        for dir in [storage.subdirectory(.inbox), storage.subdirectory(.meetings)] {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in urls where url.pathExtension == "md" {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard let (fm, body) = try? FrontmatterCodec.decode(raw) else { continue }
                let preview = body.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
                entries.append(Entry(url: url, frontmatter: fm, preview: preview))
            }
        }
        return entries
    }

    private func currentFrontmatter(at url: URL) throws -> Frontmatter {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let (fm, _) = try FrontmatterCodec.decode(raw)
        return fm
    }
}

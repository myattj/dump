import Foundation
import OSLog

/// Walks the inbox + meeting folders, finds entries with a `scheduled_at`
/// and `status: active`, and reconciles the OS notification queue with
/// them. Run on launch and after every classification.
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
        _ = await notifications.requestAuthorizationIfNeeded()

        let candidates = enumerateCandidates()
        let pending = await notifications.pending()

        var scheduled: [String] = []
        var cancelled: [String] = []

        for entry in candidates {
            let shouldFire = entry.frontmatter.status == .active && (entry.frontmatter.scheduledAt ?? .distantPast) > now
            if shouldFire {
                let nid = entry.frontmatter.notificationId ?? entry.frontmatter.id
                if !pending.contains(nid) {
                    do {
                        try await notifications.schedule(
                            id: nid,
                            title: entry.frontmatter.title ?? "Reminder",
                            body: entry.preview,
                            fireAt: entry.frontmatter.scheduledAt!,
                            userInfo: ["entry_id": entry.frontmatter.id, "path": entry.url.path]
                        )
                        scheduled.append(nid)
                        if entry.frontmatter.notificationId == nil {
                            var updated = entry.frontmatter
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
}

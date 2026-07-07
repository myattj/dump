import AppKit
import Combine
import Foundation
import OSLog

/// Top-level orchestrator owned by `DumpApp`. Holds long-lived services and
/// wires the capture/query/scheduler flows together. Constructed once on
/// first launch and kept alive for the lifetime of the process.
@MainActor
public final class AppCoordinator: ObservableObject {
    public let storage: StoragePreference
    public let writer: MarkdownWriter
    public let hotkeys: HotkeyManager
    public let capture: CaptureCoordinator
    public let query: QueryCoordinator
    public let queue: QueueCoordinator
    public let daemon: QMDDaemonController
    public let scheduler: SchedulerService
    public let classifierHub: ClassifierHub
    public let updates: UpdateController
    public let logger = Logger(subsystem: "com.joshmyatt.dump", category: "coordinator")

    public init(
        storage: StoragePreference = .shared,
        keychain: KeychainStore = .shared,
        notifications: NotificationScheduling? = nil,
        urlSession: URLSession = .shared
    ) {
        self.storage = storage
        let writer = MarkdownWriter()
        self.writer = writer
        let daemon = QMDDaemonController()
        self.daemon = daemon
        let classifierHub = ClassifierHub(
            keychain: keychain,
            urlSession: urlSession
        )
        self.classifierHub = classifierHub
        let scheduler = SchedulerService(
            storage: storage,
            writer: writer,
            notifications: notifications ?? UserNotificationCenterAdapter()
        )
        self.scheduler = scheduler

        let capture = CaptureCoordinator(
            storage: storage,
            writer: writer,
            classifier: classifierHub,
            scheduler: scheduler,
            daemon: daemon
        )
        self.capture = capture

        let queue = QueueCoordinator(
            storage: storage,
            writer: writer,
            classifier: classifierHub,
            scheduler: scheduler
        )
        self.queue = queue

        let query = QueryCoordinator(
            storage: storage,
            daemon: daemon,
            synthesizer: SynthesizerHub(
                keychain: keychain,
                urlSession: urlSession
            )
        )
        self.query = query

        self.hotkeys = HotkeyManager()
        self.updates = UpdateController()
    }

    public func start() {
        hotkeys.register(.capture, binding: .defaultCapture) { [weak self] in
            self?.capture.showQuick()
        }
        hotkeys.register(.query, binding: .defaultQuery) { [weak self] in
            self?.query.show()
        }
        hotkeys.register(.queue, binding: .defaultQueue) { [weak self] in
            self?.queue.show()
        }
        Task {
            await daemon.startIfNeeded()
            await bootstrapCollections()
        }
        Task { await scheduler.reconcile() }
        queue.refresh()
    }

    /// Registers `inbox/`, `meetings/`, `pdfs/` as qmd collections so the
    /// query engine can find captures. Idempotent — skips any name already
    /// known to qmd. Triggers a one-shot update+embed if anything got added.
    private func bootstrapCollections() async {
        let engine = QueryEngine(daemon: daemon)
        let existing = (try? await engine.collectionNames()) ?? []
        let known = Set(existing)
        let entries: [(name: String, subdir: StoragePreference.Subdir, glob: String)] = [
            ("inbox", .inbox, "**/*.md"),
            ("meetings", .meetings, "**/*.md"),
            ("pdfs", .pdfs, "**/*.md"),
        ]
        var added = false
        for entry in entries where !known.contains(entry.name) {
            let dir = storage.subdirectory(entry.subdir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try await engine.addCollection(name: entry.name, root: dir, glob: entry.glob)
                added = true
                logger.info("registered qmd collection \(entry.name, privacy: .public) -> \(dir.path, privacy: .public)")
            } catch {
                logger.error("failed to register \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if added {
            try? await engine.updateIndex()
            try? await engine.embed()
        }
    }

    public func stop() {
        hotkeys.unregisterAll()
        Task { await daemon.stop() }
    }
}

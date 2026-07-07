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
    public let hotkeyPreferences: HotkeyPreferenceStore
    public let capture: CaptureCoordinator
    public let query: QueryCoordinator
    public let queue: QueueCoordinator
    public let daemon: QMDDaemonController
    public let scheduler: SchedulerService
    public let classifierHub: ClassifierHub
    public let updates: UpdateController
    public let logger = Logger(subsystem: "com.joshmyatt.dump", category: "coordinator")

    private var heartbeat: Task<Void, Never>?
    private var hotkeyPreferenceObserver: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?

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

        let queue = QueueCoordinator(
            storage: storage,
            writer: writer,
            classifier: classifierHub,
            scheduler: scheduler
        )
        self.queue = queue

        let capture = CaptureCoordinator(
            storage: storage,
            writer: writer,
            classifier: classifierHub,
            scheduler: scheduler,
            daemon: daemon,
            onQueueChanged: { [weak queue] in queue?.refresh() }
        )
        self.capture = capture

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
        self.hotkeyPreferences = HotkeyPreferenceStore()
        self.updates = UpdateController()
    }

    public func start() {
        DiagnosticLog.prepare()
        DiagnosticLog.event(.info, category: "app", "starting Dump", metadata: [
            "version": Bundle.main.shortVersion,
            "storage": storage.root.path,
            "classifier_mode": ClassifierModePreference.read(from: .standard).rawValue,
        ])
        registerHotkeys()
        hotkeyPreferenceObserver?.cancel()
        hotkeyPreferenceObserver = hotkeyPreferences.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.registerHotkeys()
                }
            }
        Task {
            await daemon.startIfNeeded()
            DiagnosticLog.event(.info, category: "qmd", "daemon start completed", metadata: [
                "state": String(describing: await daemon.currentState()),
            ])
            await bootstrapCollections()
        }
        Task { await scheduler.reconcile() }
        queue.refresh()
        startQueueHeartbeat()
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        if let binding = hotkeyPreferences.binding(for: .capture) {
            hotkeys.register(.capture, binding: binding) { [weak self] in
                self?.capture.showQuick()
            }
        }
        if let binding = hotkeyPreferences.binding(for: .query) {
            hotkeys.register(.query, binding: binding) { [weak self] in
                self?.query.show()
            }
        }
        if let binding = hotkeyPreferences.binding(for: .queue) {
            hotkeys.register(.queue, binding: binding) { [weak self] in
                self?.queue.show()
            }
        }
        if let binding = hotkeyPreferences.binding(for: .meeting) {
            hotkeys.register(.meeting, binding: binding) { [weak self] in
                self?.capture.showMeeting()
            }
        }
    }

    /// Queue scores are time-relative, so a queue that only recomputes on
    /// user action goes stale: a pinned panel keeps yesterday's ordering
    /// and the menu-bar badge undercounts. A slow tick plus the two clock
    /// discontinuities (sleep, midnight) keep them honest. Rewrites are
    /// rank-change-gated in QueueStore, so idle ticks don't touch disk.
    private func startQueueHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.queue.refresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.queue.refresh() }
        }
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.queue.refresh() }
        }
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
                DiagnosticLog.event(.info, category: "qmd", "registered collection", metadata: [
                    "name": entry.name,
                    "path": dir.path,
                    "glob": entry.glob,
                ])
            } catch {
                logger.error("failed to register \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
                DiagnosticLog.event(.error, category: "qmd", "failed to register collection", metadata: [
                    "name": entry.name,
                    "path": dir.path,
                    "error": String(describing: error),
                ])
            }
        }
        if added {
            DiagnosticLog.event(.info, category: "qmd", "updating index after collection bootstrap")
            try? await engine.updateIndex()
            try? await engine.embed()
        }
    }

    public func stop() {
        DiagnosticLog.event(.info, category: "app", "stopping Dump")
        hotkeys.unregisterAll()
        hotkeyPreferenceObserver?.cancel()
        hotkeyPreferenceObserver = nil
        heartbeat?.cancel()
        heartbeat = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
            self.dayChangeObserver = nil
        }
        Task { await daemon.stop() }
    }
}

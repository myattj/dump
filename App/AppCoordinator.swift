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

    private var daemonStartup: Task<Void, Never>?
    private var storageTransition: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var hotkeyPreferenceObserver: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var storageTransitionGeneration: UInt = 0

    public init(
        storage: StoragePreference = .shared,
        keychain: KeychainStore = .shared,
        notifications: NotificationScheduling? = nil,
        urlSession: URLSession = .shared
    ) {
        self.storage = storage
        let writer = MarkdownWriter()
        self.writer = writer
        let daemon = QMDDaemonController(storage: storage)
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
            scheduler: scheduler,
            queryEngine: QueryEngine(daemon: daemon, storage: storage)
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
        daemonStartup?.cancel()
        daemonStartup = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.daemon.startIfNeeded()
            guard !Task.isCancelled else { return }
            DiagnosticLog.event(.info, category: "qmd", "daemon start completed", metadata: [
                "state": String(describing: await self.daemon.currentState()),
            ])
            await self.bootstrapCollections()
        }
        Task { await scheduler.reconcile() }
        queue.refresh()
        startQueueHeartbeat()
    }

    /// Failed registrations (e.g. combo held exclusively by another app),
    /// keyed by action, from the most recent `registerHotkeys()` pass.
    public private(set) var failedHotkeyActions: Set<HotkeyManager.Action> = []

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        var failed: Set<HotkeyManager.Action> = []
        if let binding = hotkeyPreferences.binding(for: .capture) {
            if !hotkeys.register(.capture, binding: binding, handler: { [weak self] in
                self?.capture.showQuick()
            }) { failed.insert(.capture) }
        }
        if let binding = hotkeyPreferences.binding(for: .query) {
            if !hotkeys.register(.query, binding: binding, handler: { [weak self] in
                self?.query.show()
            }) { failed.insert(.query) }
        }
        if let binding = hotkeyPreferences.binding(for: .queue) {
            if !hotkeys.register(.queue, binding: binding, handler: { [weak self] in
                self?.queue.show()
            }) { failed.insert(.queue) }
        }
        if let binding = hotkeyPreferences.binding(for: .meeting) {
            if !hotkeys.register(.meeting, binding: binding, handler: { [weak self] in
                self?.capture.showMeeting()
            }) { failed.insert(.meeting) }
        }
        failedHotkeyActions = failed
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

    /// Registers built-in capture folders and saved code folders as qmd
    /// collections. Idempotent unless a storage-root change requests a full
    /// rebind. Triggers one update+embed pass if anything was added.
    private func bootstrapCollections(forceRebind: Bool = false) async {
        let engine = QueryEngine(daemon: daemon)
        let existing = (try? await engine.collectionNames()) ?? []
        guard !Task.isCancelled else { return }
        let known = Set(existing)
        var entries: [(name: String, root: URL, glob: String, createDirectory: Bool)] = [
            ("inbox", storage.subdirectory(.inbox), "**/*.md", true),
            ("meetings", storage.subdirectory(.meetings), "**/*.md", true),
            ("pdfs", storage.subdirectory(.pdfs), "**/*.md", true),
        ]
        let savedCodeCollections = await CodeCollectionStore(engine: engine).list()
        guard !Task.isCancelled else { return }
        entries.append(contentsOf: savedCodeCollections.map { collection in
            (
                name: "code-\(collection.id)",
                root: URL(fileURLWithPath: collection.rootPath, isDirectory: true),
                glob: collection.glob,
                createDirectory: false
            )
        })
        var added = false
        for entry in entries {
            guard !Task.isCancelled else { return }
            if known.contains(entry.name) {
                guard forceRebind else { continue }
                do {
                    try await engine.removeCollection(name: entry.name)
                } catch {
                    logger.error("failed to remove stale \(entry.name, privacy: .public) collection: \(String(describing: error), privacy: .public)")
                    DiagnosticLog.event(.error, category: "qmd", "failed to remove stale collection", metadata: [
                        "name": entry.name,
                        "error": String(describing: error),
                    ])
                    continue
                }
            }
            if entry.createDirectory {
                try? FileManager.default.createDirectory(at: entry.root, withIntermediateDirectories: true)
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.root.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    DiagnosticLog.event(.warning, category: "qmd", "saved collection folder unavailable", metadata: [
                        "name": entry.name,
                    ])
                    continue
                }
            }
            do {
                try await engine.addCollection(name: entry.name, root: entry.root, glob: entry.glob)
                added = true
                logger.info("registered qmd collection \(entry.name, privacy: .public)")
                DiagnosticLog.event(.info, category: "qmd", "registered collection", metadata: [
                    "name": entry.name,
                    "glob": entry.glob,
                ])
            } catch {
                logger.error("failed to register \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
                DiagnosticLog.event(.error, category: "qmd", "failed to register collection", metadata: [
                    "name": entry.name,
                    "error": String(describing: error),
                ])
            }
        }
        if added, !Task.isCancelled {
            DiagnosticLog.event(.info, category: "qmd", "updating index after collection bootstrap")
            try? await engine.updateIndex()
            guard !Task.isCancelled else { return }
            try? await engine.embed()
        }
    }

    public func stop() async {
        DiagnosticLog.event(.info, category: "app", "stopping Dump")
        let startup = daemonStartup
        daemonStartup = nil
        startup?.cancel()
        let transition = storageTransition
        storageTransition = nil
        transition?.cancel()
        hotkeys.unregisterAll()
        hotkeyPreferenceObserver?.cancel()
        hotkeyPreferenceObserver = nil
        heartbeat?.cancel()
        heartbeat = nil
        storageTransitionGeneration &+= 1
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
            self.dayChangeObserver = nil
        }
        // Provider-backed capture classification and Ask synthesis are not
        // owned by qmd, so cancel and join them explicitly before the final
        // daemon teardown. Capture preserves any markdown write in progress.
        await capture.stop()
        await query.stop()
        await queue.stop()
        // The daemon owns every qmd CLI child, including work started from
        // capture, PDF import, settings, bootstrap, and the queue. Stop it
        // before waiting for those callers so no untracked child can survive.
        await daemon.stop()
        if let startup { await startup.value }
        if let transition { await transition.value }
    }

    public func setStorageRoot(_ url: URL) {
        transitionStorageRoot(to: url)
    }

    public func resetStorageRoot() {
        transitionStorageRoot(to: nil)
    }

    private func transitionStorageRoot(to url: URL?) {
        storageTransition?.cancel()
        storageTransitionGeneration &+= 1
        let generation = storageTransitionGeneration
        storageTransition = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.storageTransitionGeneration {
                    self.storageTransition = nil
                }
            }
            guard !Task.isCancelled else { return }
            await self.scheduler.cancelAllPending()
            guard !Task.isCancelled,
                  generation == self.storageTransitionGeneration else { return }
            if let url {
                self.storage.setRoot(url)
            } else {
                self.storage.reset()
            }
            DiagnosticLog.event(.info, category: "storage", "storage root changed")
            guard !Task.isCancelled else { return }
            await self.daemon.restart()
            guard !Task.isCancelled,
                  generation == self.storageTransitionGeneration else { return }
            await self.bootstrapCollections(forceRebind: true)
            guard !Task.isCancelled,
                  generation == self.storageTransitionGeneration else { return }
            _ = await self.scheduler.reconcile()
            guard !Task.isCancelled,
                  generation == self.storageTransitionGeneration else { return }
            self.queue.refresh()
        }
    }
}

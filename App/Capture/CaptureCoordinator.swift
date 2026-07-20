import AppKit
import Combine
import Foundation
import OSLog

/// Bridges the capture window, file writing, classifier, scheduler, and
/// daemon index update. The window closes before any of the slow work
/// happens so latency stays under 300ms.
@MainActor
public final class CaptureCoordinator: ObservableObject {
    /// Bumped the moment a capture is durably written — before the slow
    /// classify/index work — so the menu-bar icon can acknowledge the save
    /// without adding any latency to the submit path.
    @Published public private(set) var captureTick = 0

    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService
    private let daemon: QMDDaemonController
    private let queryEngine: QueryEngine
    private let pdfImporter: PDFImporter
    private let onQueueChanged: @MainActor @Sendable () -> Void
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "capture")
    private var acceptsSubmissions = true
    private var submissionTasks: [UUID: Task<Void, Never>] = [:]

    public private(set) lazy var quickWindow: CaptureWindowController = {
        CaptureWindowController { [weak self] body in
            self?.enqueueSubmission(body: body, source: .capture)
        }
    }()

    public private(set) lazy var meetingWindow: CaptureWindowController = {
        CaptureWindowController(positionKey: "dump.capture.meeting.origin") { [weak self] body in
            self?.enqueueSubmission(body: body, source: .meeting)
        }
    }()

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        classifier: ClassifierHub,
        scheduler: SchedulerService,
        daemon: QMDDaemonController,
        queryEngine: QueryEngine? = nil,
        onQueueChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.storage = storage
        self.writer = writer
        self.classifier = classifier
        self.scheduler = scheduler
        self.daemon = daemon
        self.queryEngine = queryEngine ?? QueryEngine(daemon: daemon)
        self.pdfImporter = PDFImporter(storage: storage, writer: writer)
        self.onQueueChanged = onQueueChanged
    }

    public func showQuick() { quickWindow.toggle() }
    public func showMeeting() { meetingWindow.toggle() }

    /// Registers the work synchronously with the coordinator before the
    /// capture event returns. That closes the quit race where an untracked
    /// task could launch a provider CLI after shutdown took its snapshot.
    func enqueueSubmission(body: String, source: Frontmatter.Source) {
        guard acceptsSubmissions else { return }
        let id = UUID()
        submissionTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.submissionTasks.removeValue(forKey: id) }
            await self.handleSubmission(body: body, source: source)
        }
    }

    public func handleSubmission(body: String, source: Frontmatter.Source) async {
        let dir = storage.subdirectory(source == .meeting ? .meetings : .inbox)
        do {
            // Hop off the main actor: the committed-exit animation is ticking on the
            // main thread right now, and createDirectory + the atomic write can stall
            // on slow or synced volumes (the storage root is user-configurable).
            let writer = self.writer
            let result = try await Task.detached(priority: .userInitiated) {
                try writer.write(body: body, into: dir, source: source) { fm in
                    if source == .meeting {
                        fm.type = .meeting
                        fm.meetingDate = Date()
                    }
                }
            }.value
            captureTick += 1
            // A quit must never sacrifice the durable markdown write. Once
            // it is safely on disk, cancellation skips all optional model,
            // scheduler, and qmd work.
            guard !Task.isCancelled else { return }
            await classifyAndPersist(at: result.url, body: body, source: source)
            guard !Task.isCancelled else { return }
            // The queue scans frontmatter on disk (QueueStore.scanInbox) — it needs
            // nothing from the qmd index or the scheduler. Refresh it as soon as the
            // classified entry is durable, not after the qmd update/embed CLI runs.
            if source != .meeting {
                onQueueChanged()
            }
            await scheduler.reconcile()
            guard !Task.isCancelled else { return }
            await indexUpdated(source: source)
        } catch {
            log.error("capture write failed: \(String(describing: error), privacy: .public)")
            // The panel already played the "sent" exit and the draft clears on
            // next open — recover the text so nothing is lost.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Your note couldn't be saved"
            alert.informativeText = "The text was copied to the clipboard so nothing is lost.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    private func classifyAndPersist(at url: URL, body: String, source: Frontmatter.Source) async {
        guard source != .meeting else { return }
        let result = await classifier.classify(body)
        guard !Task.isCancelled else { return }
        let metadata = QueueMetadataExtractor.extract(from: body)
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            var (fm, _) = try FrontmatterCodec.decode(raw)
            if result.type != .unknown {
                fm.type = result.type
            } else if let inferred = metadata.inferredType {
                fm.type = inferred
            }
            fm.title = result.title ?? fm.title
            fm.tags = result.tags.isEmpty ? fm.tags : result.tags
            fm.scheduledAt = result.scheduledAt ?? fm.scheduledAt ?? metadata.scheduledAt
            fm.deadlineAt = result.deadlineAt ?? fm.deadlineAt ?? metadata.deadlineAt
            fm.effortMinutes = result.effortMinutes ?? fm.effortMinutes ?? metadata.effortMinutes
            // Explicit syntax ("!!", "urgent") outranks the model's guess.
            fm.importance = metadata.importance ?? result.importance ?? fm.importance
            fm.metadataConfidence = result.metadataConfidence ?? fm.metadataConfidence
            fm.classifier = await classifier.activeIdentifier
            try writer.rewriteFrontmatter(at: url, with: fm)
        } catch {
            log.error("classify rewrite failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func indexUpdated(source: Frontmatter.Source) async {
        // qmd's CLI updates/embeds every collection at once. Cheap when nothing
        // changed; the `source` arg stays in the signature for future use.
        _ = source
        try? await queryEngine.updateIndex()
        try? await queryEngine.embed()
    }

    /// Stops accepting captures, cancels their optional post-write work, and
    /// joins every submission before application termination. A submission
    /// already writing its markdown is allowed to finish that durable step.
    public func stop() async {
        acceptsSubmissions = false
        let tasks = Array(submissionTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        submissionTasks.removeAll()
    }

    public func importPDF(at url: URL) async {
        do {
            let result = try pdfImporter.importPDF(at: url)
            log.info("imported \(result.extractedPages) of \(result.totalPages) pages from \(url.lastPathComponent, privacy: .public)")
            try? await queryEngine.updateIndex()
            try? await queryEngine.embed()
        } catch {
            log.error("pdf import failed: \(String(describing: error), privacy: .public)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import \u{201C}\(url.lastPathComponent)\u{201D}"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

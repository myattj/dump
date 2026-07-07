import AppKit
import Foundation
import OSLog

/// Bridges the capture window, file writing, classifier, scheduler, and
/// daemon index update. The window closes before any of the slow work
/// happens so latency stays under 300ms.
@MainActor
public final class CaptureCoordinator {
    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService
    private let daemon: QMDDaemonController
    private let queryEngine: QueryEngine
    private let pdfImporter: PDFImporter
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "capture")

    public private(set) lazy var quickWindow: CaptureWindowController = {
        CaptureWindowController { [weak self] body in
            await self?.handleSubmission(body: body, source: .capture)
        }
    }()

    public private(set) lazy var meetingWindow: CaptureWindowController = {
        CaptureWindowController { [weak self] body in
            await self?.handleSubmission(body: body, source: .meeting)
        }
    }()

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        classifier: ClassifierHub,
        scheduler: SchedulerService,
        daemon: QMDDaemonController
    ) {
        self.storage = storage
        self.writer = writer
        self.classifier = classifier
        self.scheduler = scheduler
        self.daemon = daemon
        self.queryEngine = QueryEngine(daemon: daemon)
        self.pdfImporter = PDFImporter(storage: storage, writer: writer)
    }

    public func showQuick() { quickWindow.toggle() }
    public func showMeeting() { meetingWindow.toggle() }

    public func handleSubmission(body: String, source: Frontmatter.Source) async {
        let dir = storage.subdirectory(source == .meeting ? .meetings : .inbox)
        do {
            let result = try writer.write(body: body, into: dir, source: source) { fm in
                if source == .meeting {
                    fm.type = .meeting
                    fm.meetingDate = Date()
                }
            }
            await classifyAndPersist(at: result.url, body: body, source: source)
            await indexUpdated(source: source)
            await scheduler.reconcile()
        } catch {
            log.error("capture write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func classifyAndPersist(at url: URL, body: String, source: Frontmatter.Source) async {
        guard source != .meeting else { return }
        let result = await classifier.classify(body)
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            var (fm, _) = try FrontmatterCodec.decode(raw)
            fm.type = result.type
            fm.title = result.title ?? fm.title
            fm.tags = result.tags.isEmpty ? fm.tags : result.tags
            fm.scheduledAt = result.scheduledAt
            fm.deadlineAt = result.deadlineAt
            fm.effortMinutes = result.effortMinutes
            fm.metadataConfidence = result.metadataConfidence
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

    public func importPDF(at url: URL) async {
        do {
            let result = try pdfImporter.importPDF(at: url)
            log.info("imported \(result.extractedPages) of \(result.totalPages) pages from \(url.lastPathComponent, privacy: .public)")
            try? await queryEngine.updateIndex()
            try? await queryEngine.embed()
        } catch {
            log.error("pdf import failed: \(String(describing: error), privacy: .public)")
        }
    }
}

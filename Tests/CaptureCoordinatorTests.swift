import XCTest
@testable import Dump

@MainActor
final class CaptureCoordinatorTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!
    var process: MockProcessLauncher!
    var transport: MockHTTPTransport!
    var daemon: QMDDaemonController!
    var qmdClient: MockQMDClient!
    var queryEngine: QueryEngine!
    var hub: ClassifierHub!
    var scheduler: SchedulerService!
    var notif: MockNotificationCenter!

    // Xcode 16 declares XCTest's async base hook as nonisolated, so an
    // @MainActor test case must perform its setup without calling that no-op.
    override func setUp() async throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-cap-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "cap.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
        process = MockProcessLauncher()
        transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200) }
        daemon = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(2)),
            process: process,
            transport: transport
        )
        await daemon.start()
        qmdClient = MockQMDClient()
        queryEngine = QueryEngine(client: qmdClient, storage: storage)
        notif = MockNotificationCenter()
        hub = ClassifierHub(
            keychain: KeychainStore(service: "cap.\(UUID())"),
            defaults: UserDefaults(suiteName: "cap-hub.\(UUID())")!,
            claude: StubClassifier(),
            ollama: StubClassifier()
        )
        scheduler = SchedulerService(storage: storage, writer: MarkdownWriter(), notifications: notif)
    }

    // See setUp(): the XCTest base implementation has no work to preserve.
    override func tearDown() async throws {
        await daemon?.stop()
        try? FileManager.default.removeItem(at: tempRoot)
        qmdClient = nil
        queryEngine = nil
    }

    func testQuickCaptureWritesFileAndClassifies() async throws {
        let coordinator = CaptureCoordinator(
            storage: storage,
            writer: MarkdownWriter(),
            classifier: hub,
            scheduler: scheduler,
            daemon: daemon,
            queryEngine: queryEngine
        )
        await coordinator.handleSubmission(body: "remind me to take vitamins", source: .capture)
        let inbox = storage.subdirectory(.inbox)
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(raw.contains("type: reminder")) // StubClassifier returns .reminder
        XCTAssertTrue(raw.contains("remind me to take vitamins"))
    }

    func testQuickCaptureFallsBackToLocalQueueMetadataWhenClassifierFails() async throws {
        let failingHub = ClassifierHub(
            keychain: KeychainStore(service: "cap.\(UUID())"),
            defaults: UserDefaults(suiteName: "cap-hub.\(UUID())")!,
            claude: ThrowingCaptureClassifier(),
            ollama: ThrowingCaptureClassifier()
        )
        let coordinator = CaptureCoordinator(
            storage: storage,
            writer: MarkdownWriter(),
            classifier: failingHub,
            scheduler: scheduler,
            daemon: daemon,
            queryEngine: queryEngine
        )

        await coordinator.handleSubmission(body: "send invoice tomorrow 15m", source: .capture)

        let inbox = storage.subdirectory(.inbox)
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(raw.contains("type: task"))
        XCTAssertTrue(raw.contains("deadline_at:"))
        XCTAssertTrue(raw.contains("effort_minutes: 15"))
    }

    func testMeetingCaptureUsesMeetingDirectoryAndType() async throws {
        let coordinator = CaptureCoordinator(
            storage: storage,
            writer: MarkdownWriter(),
            classifier: hub,
            scheduler: scheduler,
            daemon: daemon,
            queryEngine: queryEngine
        )
        await coordinator.handleSubmission(body: "marketing sync notes...", source: .meeting)
        let meetings = storage.subdirectory(.meetings)
        let files = try FileManager.default.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(raw.contains("type: meeting"))
        XCTAssertTrue(raw.contains("source: meeting"))
    }

    func testStopPreservesDurableCaptureAndJoinsClassification() async throws {
        let blockingClassifier = CancellationRecordingCaptureClassifier()
        let blockingHub = ClassifierHub(
            keychain: KeychainStore(service: "cap.\(UUID())"),
            defaults: UserDefaults(suiteName: "cap-hub.\(UUID())")!,
            claude: blockingClassifier,
            ollama: blockingClassifier
        )
        let coordinator = CaptureCoordinator(
            storage: storage,
            writer: MarkdownWriter(),
            classifier: blockingHub,
            scheduler: scheduler,
            daemon: daemon,
            queryEngine: queryEngine
        )

        coordinator.enqueueSubmission(body: "durable during shutdown", source: .capture)
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await blockingClassifier.hasStarted()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let didStart = await blockingClassifier.hasStarted()
        XCTAssertTrue(didStart)

        await coordinator.stop()

        let wasCancelled = await blockingClassifier.wasCancelled()
        XCTAssertTrue(wasCancelled)
        let inbox = storage.subdirectory(.inbox)
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(raw.contains("durable during shutdown"))
        XCTAssertTrue(qmdClient.cliCalls.isEmpty)
    }
}

struct StubClassifier: Classifier {
    let identifier = "stub"
    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        ClassifierResult(type: .reminder, title: "stubbed", tags: ["t"], scheduledAt: nil)
    }
}

struct ThrowingCaptureClassifier: Classifier {
    let identifier = "throwing"

    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        throw NSError(domain: "capture", code: 1)
    }
}

private actor CancellationRecordingCaptureClassifier: Classifier {
    nonisolated let identifier = "blocking-capture"
    private var started = false
    private var cancelled = false

    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return .unknown
    }

    func hasStarted() -> Bool { started }
    func wasCancelled() -> Bool { cancelled }
}

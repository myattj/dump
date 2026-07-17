import XCTest
@testable import Dump

final class QMDDaemonControllerTests: XCTestCase {
    func testStartLaunchesProcessAndReportsRunning() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200, body: Data()) }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport
        )
        await controller.start()
        if case .running = await controller.currentState() {} else {
            XCTFail("expected running, got \(await controller.currentState())")
        }
        XCTAssertEqual(process.launched.count, 1)
    }

    func testHealthFailureMarksCrashed() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in throw HTTPError.timeout }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .milliseconds(50), maxRestartAttempts: 0),
            process: process,
            transport: transport
        )
        await controller.start()
        if case .crashed = await controller.currentState() {} else {
            XCTFail("expected crashed, got \(await controller.currentState())")
        }
        let port = await controller.currentPort()
        XCTAssertNil(port)
        XCTAssertEqual(process.terminateCalls, 1)
    }

    func testStopReturnsToStopped() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200, body: Data()) }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport
        )
        await controller.start()
        await controller.stop()
        let state = await controller.currentState()
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(process.terminateCalls, 1)
    }

    func testStopDuringHealthCheckCannotReturnToRunning() async {
        let process = MockProcessLauncher()
        let transport = SuspendedHealthTransport()
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport
        )

        let startTask = Task { await controller.start() }
        await transport.waitForRequest()
        await controller.stop()
        await transport.resume(with: HTTPResponse(status: 200))
        await startTask.value

        let state = await controller.currentState()
        let port = await controller.currentPort()
        XCTAssertEqual(state, .stopped)
        XCTAssertNil(port)
        XCTAssertEqual(process.launched.count, 1)
        XCTAssertEqual(process.terminateCalls, 1)
    }

    func testCancelledQueuedStartDoesNotLaunchProcess() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200) }
        let controller = QMDDaemonController(process: process, transport: transport)
        let gate = AsyncGate()

        let startTask = Task {
            await gate.wait()
            await controller.start()
        }
        await gate.waitUntilBlocked()
        startTask.cancel()
        await gate.open()
        await startTask.value

        let state = await controller.currentState()
        XCTAssertEqual(state, .stopped)
        XCTAssertTrue(process.launched.isEmpty)
        XCTAssertEqual(process.terminateCalls, 0)
    }

    func testRecentLogReturnsRingBuffer() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200, body: Data()) }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport
        )
        await controller.start()
        process.simulateLine("hello world")
        // Give the actor a tick to process the message
        try? await Task.sleep(for: .milliseconds(50))
        let lines = await controller.recentLog()
        XCTAssertTrue(lines.contains("hello world"))
    }

    func testLaunchAndCLIEnvironmentFollowInjectedStoragePreference() async throws {
        let suiteName = "dump.daemon.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = StoragePreference(
            defaults: defaults,
            fallback: URL(fileURLWithPath: "/tmp/dump-original")
        )
        storage.setRoot(URL(fileURLWithPath: "/tmp/dump-moved"))

        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200, body: Data()) }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport,
            storage: storage
        )

        await controller.start()
        let environment = await controller.cliEnvironment()

        XCTAssertEqual(environment["QMD_DATA_DIR"], "/tmp/dump-moved")
        XCTAssertEqual(process.launched.first?.environment["QMD_DATA_DIR"], "/tmp/dump-moved")
    }

    func testExitFromStoppedGenerationDoesNotRestartReplacementProcess() async {
        let process = MockProcessLauncher()
        let transport = MockHTTPTransport()
        transport.setFallback { _ in HTTPResponse(status: 200, body: Data()) }
        let controller = QMDDaemonController(
            config: .init(startupGracePeriod: .seconds(5)),
            process: process,
            transport: transport
        )

        await controller.start()
        await controller.stop()
        await controller.start()
        process.simulateExit(code: 0, launchIndex: 0)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(process.launched.count, 2)
        if case .running = await controller.currentState() {} else {
            XCTFail("stale exit changed replacement state: \(await controller.currentState())")
        }
    }
}

private actor SuspendedHealthTransport: HTTPTransporting {
    private var requestStarted = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<HTTPResponse, Error>?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestStarted = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitForRequest() async {
        if requestStarted { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume(with response: HTTPResponse) {
        let continuation = responseContinuation
        responseContinuation = nil
        continuation?.resume(returning: response)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let observers = blockedObservers
            blockedObservers.removeAll()
            for observer in observers { observer.resume() }
        }
    }

    func waitUntilBlocked() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            blockedObservers.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

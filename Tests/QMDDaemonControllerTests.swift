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

    func testLaunchAndCLIUseSameIsolatedEnvironmentUnderInjectedStorageRoot() async throws {
        let suiteName = "dump.daemon.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let movedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-daemon-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: movedRoot) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedRoot.path))
        let storage = StoragePreference(
            defaults: defaults,
            fallback: URL(fileURLWithPath: "/tmp/dump-original")
        )
        storage.setRoot(movedRoot)

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
        let environment = try await controller.cliEnvironment()
        let qmdRoot = movedRoot.appendingPathComponent(".dump-qmd", isDirectory: true)
        let cacheDirectory = qmdRoot.appendingPathComponent("qmd", isDirectory: true)
        let configDirectory = qmdRoot.appendingPathComponent("config", isDirectory: true)
        let expectedEnvironment = [
            "XDG_CACHE_HOME": qmdRoot.path,
            "INDEX_PATH": cacheDirectory.appendingPathComponent("index.sqlite").path,
            "QMD_CONFIG_DIR": configDirectory.path,
        ]

        XCTAssertEqual(environment, expectedEnvironment)
        XCTAssertEqual(process.launched.first?.environment, expectedEnvironment)
        XCTAssertNil(environment["QMD_DATA_DIR"])
        var cacheIsDirectory: ObjCBool = false
        var configIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheDirectory.path,
            isDirectory: &cacheIsDirectory
        ))
        XCTAssertTrue(cacheIsDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configDirectory.path,
            isDirectory: &configIsDirectory
        ))
        XCTAssertTrue(configIsDirectory.boolValue)
    }

    func testStopCancelsAndAwaitsAllTrackedCLIWorkAndRejectsLateCommands() async throws {
        let suiteName = "dump.daemon.cli-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-daemon-cli-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let storage = StoragePreference(defaults: defaults, fallback: storageRoot)
        let executor = BlockingDaemonCLIExecutor()
        let process = MockProcessLauncher()
        let controller = QMDDaemonController(
            config: .init(runtimeDirectory: storageRoot),
            process: process,
            transport: MockHTTPTransport(),
            storage: storage,
            cliExecutor: { executable, arguments, environment in
                try await executor.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment
                )
            }
        )
        let first = Task { try await controller.runCLI(arguments: ["update"]) }
        let second = Task { try await controller.runCLI(arguments: ["embed"]) }

        let deadline = ContinuousClock.now + .seconds(2)
        while await executor.startedCount() < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard await executor.startedCount() == 2 else {
            first.cancel()
            second.cancel()
            await controller.stop()
            XCTFail("tracked CLI work did not start before timeout")
            return
        }

        await controller.stop()

        let counts = await executor.counts()
        XCTAssertEqual(counts.started, 2)
        XCTAssertEqual(counts.cancelled, 2)
        XCTAssertEqual(counts.finished, 2)
        XCTAssertEqual(process.terminateCalls, 1)
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected tracked CLI cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("unexpected CLI error: \(error)")
            }
        }

        do {
            _ = try await controller.runCLI(arguments: ["update"])
            XCTFail("expected commands submitted after stop to be rejected")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected late-command error: \(error)")
        }
        let finalStartedCount = await executor.startedCount()
        XCTAssertEqual(finalStartedCount, 2)
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

private actor BlockingDaemonCLIExecutor {
    private var started = 0
    private var cancelled = 0
    private var finished = 0

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> QMDCLIOutput {
        _ = executable
        _ = arguments
        _ = environment
        started += 1
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled += 1
            finished += 1
            throw CancellationError()
        }
        finished += 1
        return QMDCLIOutput(exitCode: 0, stdout: "", stderr: "")
    }

    func startedCount() -> Int { started }
    func counts() -> (started: Int, cancelled: Int, finished: Int) {
        (started, cancelled, finished)
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

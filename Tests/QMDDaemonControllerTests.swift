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

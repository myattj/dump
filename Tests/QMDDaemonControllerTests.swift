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
        XCTAssertEqual(process.orphansReaped, ["qmd"])
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
}

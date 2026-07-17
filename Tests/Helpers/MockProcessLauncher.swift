import Foundation
import os
@testable import Dump

public final class MockProcessLauncher: ProcessLaunching, @unchecked Sendable {
    public struct Launched: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: [String: String]
    }

    private struct State: @unchecked Sendable {
        var launched: [Launched] = []
        var terminateCalls = 0
        var lineHandler: (@Sendable (String) -> Void)?
        var exitHandlers: [(@Sendable (Int32) -> Void)] = []
        var launchError: Error?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var launched: [Launched] { state.withLock { $0.launched } }
    public var terminateCalls: Int { state.withLock { $0.terminateCalls } }

    public func setLaunchError(_ error: Error?) {
        state.withLock { $0.launchError = error }
    }

    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let throwable = state.withLock { s -> Error? in
            if let e = s.launchError { return e }
            s.launched.append(Launched(executable: executable, arguments: arguments, environment: environment))
            s.lineHandler = onLine
            s.exitHandlers.append(onExit)
            return nil
        }
        if let e = throwable { throw e }
    }

    public func terminate() {
        state.withLock { $0.terminateCalls += 1 }
    }

    public func simulateExit(code: Int32) {
        let handler = state.withLock { $0.exitHandlers.last }
        handler?(code)
    }

    public func simulateExit(code: Int32, launchIndex: Int) {
        let handler = state.withLock { state in
            state.exitHandlers.indices.contains(launchIndex) ? state.exitHandlers[launchIndex] : nil
        }
        handler?(code)
    }

    public func simulateLine(_ line: String) {
        let handler = state.withLock { $0.lineHandler }
        handler?(line)
    }
}

import Foundation
import os
@testable import Dump

/// In-memory fake QMDClienting for tests. Returns canned hits/status and
/// records every CLI invocation so callers can assert on argument lists
/// without spawning subprocesses.
public final class MockQMDClient: QMDClienting, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var hits: [QMDHit] = []
        var status: QMDStatus = QMDStatus(totalDocuments: 0, needsEmbedding: 0, hasVectorIndex: false, collections: [])
        var queryError: Error?
        var cliError: Error?
        var queries: [QMDQuery] = []
        var cliCalls: [[String]] = []
        var gets: [String] = []
        var fileContents: [String: String] = [:]
        var cliStdoutByFirstArg: [String: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func stubHits(_ hits: [QMDHit]) { state.withLock { $0.hits = hits } }
    public func stubStatus(_ status: QMDStatus) { state.withLock { $0.status = status } }
    public func stubFile(_ path: String, body: String) { state.withLock { $0.fileContents[path] = body } }
    public func setQueryError(_ error: Error?) { state.withLock { $0.queryError = error } }
    public func setCLIError(_ error: Error?) { state.withLock { $0.cliError = error } }
    public func stubCLIStdout(forFirstArg first: String, stdout: String) {
        state.withLock { $0.cliStdoutByFirstArg[first] = stdout }
    }

    public var queries: [QMDQuery] { state.withLock { $0.queries } }
    public var cliCalls: [[String]] { state.withLock { $0.cliCalls } }
    public var gets: [String] { state.withLock { $0.gets } }

    public func query(_ q: QMDQuery) async throws -> [QMDHit] {
        try state.withLock { s -> [QMDHit] in
            if let e = s.queryError { throw e }
            s.queries.append(q)
            return s.hits
        }
    }

    public func get(file: String, fromLine: Int?, maxLines: Int?) async throws -> String {
        state.withLock { s -> String in
            s.gets.append(file)
            return s.fileContents[file] ?? ""
        }
    }

    public func status() async throws -> QMDStatus {
        state.withLock { $0.status }
    }

    public func runCLI(arguments: [String]) async throws -> QMDCLIOutput {
        try state.withLock { s -> QMDCLIOutput in
            if let e = s.cliError { throw e }
            s.cliCalls.append(arguments)
            let stdout = arguments.first.flatMap { s.cliStdoutByFirstArg[$0] } ?? ""
            return QMDCLIOutput(exitCode: 0, stdout: stdout, stderr: "")
        }
    }
}

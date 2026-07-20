import Darwin
import Foundation
import XCTest
@testable import Dump

final class PlanBackedCLIClientTests: XCTestCase {
    func testClaudeCodeCommandUsesPrintModeAndPlanEnvironment() async throws {
        let store = makeStore(provider: .claudeCode)
        store.claudeCodeExecutablePath = "/tmp/claude"
        let runner = MockLocalPlanCommandRunner(result: .init(stdout: "answer\n", stderr: "", exitCode: 0))
        let client = PlanBackedCLIClient(configStore: store, runner: runner)

        let answer = try await client.complete(prompt: "hello")

        XCTAssertEqual(answer, "answer")
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable.path, "/tmp/claude")
        XCTAssertEqual(invocation.arguments.prefix(4), ["-p", "--output-format", "text", "--no-session-persistence"])
        XCTAssertFalse(invocation.arguments.contains("hello"))
        XCTAssertEqual(invocation.standardInput, Data("hello".utf8))
        XCTAssertEqual(invocation.environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(invocation.environment["OPENAI_API_KEY"], "")
    }

    func testCodexCommandUsesExecReadOnlyAndPlanEnvironment() async throws {
        let store = makeStore(provider: .codex)
        store.codexExecutablePath = "/tmp/codex"
        let runner = MockLocalPlanCommandRunner(result: .init(stdout: "codex answer\n", stderr: "", exitCode: 0))
        let client = PlanBackedCLIClient(configStore: store, runner: runner)

        let answer = try await client.complete(prompt: "summarize")

        XCTAssertEqual(answer, "codex answer")
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executable.path, "/tmp/codex")
        XCTAssertEqual(invocation.arguments.first, "exec")
        XCTAssertTrue(invocation.arguments.contains("--ephemeral"))
        XCTAssertTrue(invocation.arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(invocation.arguments.contains("--output-last-message"))
        XCTAssertEqual(invocation.arguments.last, "-")
        XCTAssertEqual(invocation.standardInput, Data("summarize".utf8))
        XCTAssertEqual(argument(after: "--sandbox", in: invocation.arguments), "read-only")
        XCTAssertEqual(invocation.environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(invocation.environment["OPENAI_API_KEY"], "")
    }

    func testCommandFailureIncludesProviderAndExitCode() async {
        let store = makeStore(provider: .codex)
        store.codexExecutablePath = "/tmp/codex"
        let runner = MockLocalPlanCommandRunner(result: .init(stdout: "", stderr: "not logged in", exitCode: 7))
        let client = PlanBackedCLIClient(configStore: store, runner: runner)

        do {
            _ = try await client.complete(prompt: "hello")
            XCTFail("expected commandFailed")
        } catch let error as PlanBackedCLIClient.PlanBackedError {
            XCTAssertEqual(error, .commandFailed(provider: .codex, exitCode: 7, stderr: "not logged in"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingExecutableThrows() async {
        let store = makeStore(provider: .claudeCode)
        let client = PlanBackedCLIClient(configStore: store, runner: MockLocalPlanCommandRunner())

        do {
            _ = try await client.complete(prompt: "hello")
            XCTFail("expected missingExecutable")
        } catch let error as PlanBackedCLIClient.PlanBackedError {
            XCTAssertEqual(error, .missingExecutable("claude"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class PlanBackedClassifierTests: XCTestCase {
    func testParsesJSONReplyWrappedInText() async throws {
        let store = makeStore(provider: .claudeCode)
        store.claudeCodeExecutablePath = "/tmp/claude"
        let stdout = """
        Sure:
        {"type":"task","title":"Ship plan mode","tags":["dump"],"scheduled_at":null,"deadline_at":"2026-07-08T18:00:00Z","effort_minutes":45,"importance":3,"metadata_confidence":0.82}
        """
        let runner = MockLocalPlanCommandRunner(result: .init(stdout: stdout, stderr: "", exitCode: 0))
        let classifier = PlanBackedClassifier(configStore: store, runner: runner)

        let result = try await classifier.classify("ship it tomorrow", now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(result.type, .task)
        XCTAssertEqual(result.title, "Ship plan mode")
        XCTAssertEqual(result.tags, ["dump"])
        XCTAssertNil(result.scheduledAt)
        XCTAssertNotNil(result.deadlineAt)
        XCTAssertEqual(result.effortMinutes, 45)
        XCTAssertEqual(result.importance, 3)
        XCTAssertEqual(result.metadataConfidence, 0.82)
    }
}

final class PlanBackedSynthesizerTests: XCTestCase {
    private func hit(_ docid: String, file: String, title: String? = nil, snippet: String = "") -> QMDHit {
        QMDHit(docid: docid, file: file, title: title, score: 1, context: nil, snippet: snippet)
    }

    func testSynthesizesAndExtractsCitations() async throws {
        let store = makeStore(provider: .claudeCode)
        store.claudeCodeExecutablePath = "/tmp/claude"
        let runner = MockLocalPlanCommandRunner(result: .init(stdout: "Use the first note [1].", stderr: "", exitCode: 0))
        let synthesizer = PlanBackedSynthesizer(configStore: store, runner: runner)

        let result = try await synthesizer.synthesize(
            query: "what now?",
            hits: [hit("#1", file: "inbox/a.md", title: "A", snippet: "alpha")]
        )

        XCTAssertEqual(result.text, "Use the first note [1].")
        XCTAssertEqual(result.citations.map(\.path), ["inbox/a.md"])
    }
}

final class PlanBackedConfigStoreTests: XCTestCase {
    func testPersistsPlanBackedSettings() {
        let store = makeStore(provider: .codex)
        store.claudeCodeExecutablePath = "/opt/homebrew/bin/claude"
        store.codexExecutablePath = "/opt/homebrew/bin/codex"

        XCTAssertEqual(store.planBackedProvider, .codex)
        XCTAssertEqual(store.claudeCodeExecutablePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(store.codexExecutablePath, "/opt/homebrew/bin/codex")
    }
}

final class SystemLocalPlanCommandRunnerTests: XCTestCase {
    func testLargeStandardInputReachesChildWithoutUsingArguments() async throws {
        let input = Data(repeating: 0x61, count: 1_048_576)
        let result = try await SystemLocalPlanCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/wc"),
            arguments: ["-c"],
            environment: [:],
            standardInput: input,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1048576")
    }

    func testTimeoutIsEnforcedWhenChildNeverReadsStandardInput() async throws {
        let started = ContinuousClock.now
        let result = try await SystemLocalPlanCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            environment: [:],
            standardInput: Data(repeating: 0x61, count: 1_048_576),
            timeout: 0.2
        )
        let elapsed = ContinuousClock.now - started

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let script = "i=0; while [ $i -lt 5000 ]; do echo stdout-$i; echo stderr-$i >&2; i=$((i+1)); done"
        let result = try await SystemLocalPlanCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: [:],
            standardInput: nil,
            timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("stdout-4999"))
        XCTAssertTrue(result.stderr.contains("stderr-4999"))
    }

    func testCancellationTerminatesAndJoinsExactOwnedProcess() async throws {
        let invocation = LocalPlanProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30; while :; do :; done"],
            environment: ProcessInfo.processInfo.environment,
            standardInput: nil,
            timeout: 30
        )
        let task = Task { try await invocation.run() }

        let launchDeadline = ContinuousClock.now + .seconds(2)
        var pid: pid_t?
        while pid == nil, ContinuousClock.now < launchDeadline {
            pid = invocation.runningProcessIdentifier()
            if pid == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let ownedPID = try XCTUnwrap(pid)
        var descendantPIDs: [pid_t] = []
        while descendantPIDs.isEmpty, ContinuousClock.now < launchDeadline {
            descendantPIDs = invocation.runningDescendantProcessIdentifiers()
            if descendantPIDs.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertFalse(descendantPIDs.isEmpty, "provider fixture did not launch its helper child")
        // Give the shell time to install its TERM handler so this also
        // exercises the verified SIGKILL fallback.
        try await Task.sleep(for: .milliseconds(100))

        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(Darwin.kill(ownedPID, 0), -1, "owned provider child survived cancellation")
        for descendantPID in descendantPIDs {
            XCTAssertEqual(
                Darwin.kill(descendantPID, 0),
                -1,
                "owned provider descendant \(descendantPID) survived cancellation"
            )
        }
    }

    func testCancellationBeforeLaunchCreatesNoChildSideEffect() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-cancel-before-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let invocation = LocalPlanProcessInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            environment: ProcessInfo.processInfo.environment,
            standardInput: nil,
            timeout: 5
        )

        invocation.cancel()
        do {
            _ = try await invocation.run()
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

final class PlanBackedExecutableResolverTests: XCTestCase {
    func testDetectsExecutablesFromPathEnvironment() throws {
        let directory = try makeExecutableDirectory(commands: ["claude", "codex"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let detection = PlanBackedExecutableResolver.detect(
            environment: ["PATH": directory.path],
            fallbackSearchPaths: []
        )

        XCTAssertEqual(detection.claudeCodePath, directory.appendingPathComponent("claude").path)
        XCTAssertEqual(detection.codexPath, directory.appendingPathComponent("codex").path)
        XCTAssertEqual(detection.availableProviders, [.claudeCode, .codex])
    }

    func testPreferredProviderPreservesCurrentWhenAvailable() {
        let detection = PlanBackedExecutableDetection(
            claudeCodePath: "/opt/homebrew/bin/claude",
            codexPath: "/opt/homebrew/bin/codex"
        )

        XCTAssertEqual(detection.preferredProvider(current: .codex), .codex)
    }

    func testPreferredProviderFallsBackWhenCurrentIsUnavailable() {
        let detection = PlanBackedExecutableDetection(
            claudeCodePath: "",
            codexPath: "/opt/homebrew/bin/codex"
        )

        XCTAssertEqual(detection.preferredProvider(current: .claudeCode), .codex)
    }
}

private func makeStore(provider: PlanBackedProvider) -> CustomLLMConfigStore {
    let defaults = UserDefaults(suiteName: "plan-backed-\(UUID().uuidString)")!
    let store = CustomLLMConfigStore(defaults: defaults)
    store.planBackedProvider = provider
    return store
}

private func argument(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    return arguments[valueIndex]
}

private func makeExecutableDirectory(commands: [String]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dump-plan-backed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for command in commands {
        let url = directory.appendingPathComponent(command)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return directory
}

private final class MockLocalPlanCommandRunner: LocalPlanCommandRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let standardInput: Data?
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private let result: LocalPlanCommandResult
    private(set) var invocations: [Invocation] = []

    init(result: LocalPlanCommandResult = .init(stdout: "", stderr: "", exitCode: 0)) {
        self.result = result
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> LocalPlanCommandResult {
        lock.withLock {
            invocations.append(.init(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                timeout: timeout
            ))
        }
        return result
    }
}

import Darwin
import Foundation

public enum PlanBackedProvider: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude_code"
    case codex = "codex"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var commandName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    public var docsURL: URL {
        switch self {
        case .claudeCode:
            return ProviderConnect.claudeCodeAuthURL
        case .codex:
            return ProviderConnect.codexAuthURL
        }
    }
}

public struct PlanBackedExecutableDetection: Equatable, Sendable {
    public let claudeCodePath: String
    public let codexPath: String

    public init(claudeCodePath: String, codexPath: String) {
        self.claudeCodePath = claudeCodePath
        self.codexPath = codexPath
    }

    public var availableProviders: [PlanBackedProvider] {
        PlanBackedProvider.allCases.filter { provider in
            !path(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var isEmpty: Bool {
        availableProviders.isEmpty
    }

    public func path(for provider: PlanBackedProvider) -> String {
        switch provider {
        case .claudeCode: return claudeCodePath
        case .codex: return codexPath
        }
    }

    public func preferredProvider(current: PlanBackedProvider) -> PlanBackedProvider? {
        let providers = availableProviders
        if providers.contains(current) {
            return current
        }
        return providers.first
    }
}

public struct LocalPlanCommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol LocalPlanCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> LocalPlanCommandResult
}

public final class SystemLocalPlanCommandRunner: LocalPlanCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> LocalPlanCommandResult {
        try await LocalPlanProcessInvocation(
            executable: executable,
            arguments: arguments,
            environment: Self.mergedEnvironment(environment),
            standardInput: standardInput,
            timeout: timeout
        ).run()
    }

    private static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = "\(fallbackPath):\(path)"
        } else {
            environment["PATH"] = fallbackPath
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }
}

/// Owns one provider CLI invocation. Cancellation always targets the exact
/// `Process` this instance launched, waits for it to exit, and reports
/// `CancellationError` to the caller instead of leaving a 90/120-second CLI
/// behind during app termination.
final class LocalPlanProcessInvocation: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let standardInput: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
    }

    func run() async throws -> LocalPlanCommandResult {
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try self.runSynchronously()
            }.value
        } onCancel: {
            self.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    func runningProcessIdentifier() -> pid_t? {
        lock.withLock {
            guard let process, process.isRunning else { return nil }
            return process.processIdentifier
        }
    }

    func runningDescendantProcessIdentifiers() -> [pid_t] {
        guard let pid = runningProcessIdentifier() else { return [] }
        return Self.descendantProcessIdentifiers(of: pid)
    }

    private func runSynchronously() throws -> LocalPlanCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCollector = ProcessPipeCollector(pipe: stdout)
        let stderrCollector = ProcessPipeCollector(pipe: stderr)

        // A pipe can block forever if the child launches but never reads
        // stdin. Stage the prompt in an unlinked, mode-0600 temporary file
        // instead: it never appears in argv or at a reusable filesystem path,
        // and the child can read it without backpressure from the parent.
        let inputHandle = try standardInput.map(Self.makeStandardInputHandle)
        defer { try? inputHandle?.close() }
        process.standardInput = inputHandle

        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        do {
            // Keep the lock across launch so cancellation cannot slip between
            // the preflight check and a child becoming live but unowned.
            try process.run()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
        lock.unlock()

        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            // Provider CLIs can launch helpers that inherit our stdout/stderr
            // pipes. Kill descendants first so one cannot keep pipe EOF open
            // after the root exits and make shutdown wait forever.
            Self.forceTerminateDescendants(of: process.processIdentifier)
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                Self.forceTerminateDescendants(of: process.processIdentifier)
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        let result = LocalPlanCommandResult(
            stdout: String(data: stdoutCollector.finish(), encoding: .utf8) ?? "",
            stderr: String(data: stderrCollector.finish(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
        let wasCancelled = lock.withLock {
            if self.process === process { self.process = nil }
            return cancelled
        }
        if wasCancelled { throw CancellationError() }
        return result
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        Self.forceTerminateDescendants(of: pid)
        process.terminate()
        Self.forceTerminateDescendants(of: pid)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceTerminateIfRunning(pid: pid)
        }
    }

    private func forceTerminateIfRunning(pid: pid_t) {
        let ownedProcess = lock.withLock { () -> Process? in
            guard let process, process.processIdentifier == pid else { return nil }
            return process
        }
        if let ownedProcess, ownedProcess.isRunning {
            Self.forceTerminateDescendants(of: pid)
            Darwin.kill(pid, SIGKILL)
        }
    }

    private static func forceTerminateDescendants(of rootPID: pid_t) {
        for pid in descendantProcessIdentifiers(of: rootPID).reversed() where pid > 1 {
            Darwin.kill(pid, SIGKILL)
        }
    }

    private static func descendantProcessIdentifiers(of rootPID: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []
        var pending = [rootPID]
        var seen = Set([rootPID])

        while let parent = pending.popLast() {
            for child in directChildProcessIdentifiers(of: parent)
            where child > 1 && seen.insert(child).inserted {
                descendants.append(child)
                pending.append(child)
            }
        }
        return descendants
    }

    private static func directChildProcessIdentifiers(of parentPID: pid_t) -> [pid_t] {
        let hint = proc_listchildpids(parentPID, nil, 0)
        guard hint > 0 else { return [] }
        // The sizing call is deliberately generous on macOS and the buffered
        // call returns a PID count (not a byte count). Allocate at least the
        // full hint so a wide provider process tree cannot be truncated.
        var pids = [pid_t](repeating: 0, count: max(Int(hint), 32))
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    private static func makeStandardInputHandle(_ data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-stdin-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forUpdating: url)
            do {
                try FileManager.default.removeItem(at: url)
                try handle.write(contentsOf: data)
                try handle.seek(toOffset: 0)
                return handle
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

public enum PlanBackedExecutableResolver {
    public static let fallbackSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    public static func resolve(
        configuredPath: String,
        commandName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallbackSearchPaths: [String] = PlanBackedExecutableResolver.fallbackSearchPaths
    ) -> URL? {
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let expanded = NSString(string: configured).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }

        var searchPaths = fallbackSearchPaths
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        searchPaths.append(contentsOf: pathEntries)

        var seen = Set<String>()
        for directory in searchPaths where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(commandName)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallbackSearchPaths: [String] = PlanBackedExecutableResolver.fallbackSearchPaths
    ) -> PlanBackedExecutableDetection {
        PlanBackedExecutableDetection(
            claudeCodePath: detectedPath(
                commandName: PlanBackedProvider.claudeCode.commandName,
                environment: environment,
                fileManager: fileManager,
                fallbackSearchPaths: fallbackSearchPaths
            ),
            codexPath: detectedPath(
                commandName: PlanBackedProvider.codex.commandName,
                environment: environment,
                fileManager: fileManager,
                fallbackSearchPaths: fallbackSearchPaths
            )
        )
    }

    public static func detectedPath(
        commandName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallbackSearchPaths: [String] = PlanBackedExecutableResolver.fallbackSearchPaths
    ) -> String {
        resolve(
            configuredPath: "",
            commandName: commandName,
            environment: environment,
            fileManager: fileManager,
            fallbackSearchPaths: fallbackSearchPaths
        )?.path ?? ""
    }
}

public struct PlanBackedCLIClient: Sendable {
    private let configStore: CustomLLMConfigStore
    private let runner: LocalPlanCommandRunning

    public init(
        configStore: CustomLLMConfigStore = .shared,
        runner: LocalPlanCommandRunning = SystemLocalPlanCommandRunner()
    ) {
        self.configStore = configStore
        self.runner = runner
    }

    public func complete(prompt: String, timeout: TimeInterval = 120) async throws -> String {
        let provider = configStore.planBackedProvider
        guard let executable = executableURL(for: provider) else {
            throw PlanBackedError.missingExecutable(provider.commandName)
        }

        switch provider {
        case .claudeCode:
            return try await runClaudeCode(executable: executable, prompt: prompt, timeout: timeout)
        case .codex:
            return try await runCodex(executable: executable, prompt: prompt, timeout: timeout)
        }
    }

    private func executableURL(for provider: PlanBackedProvider) -> URL? {
        let configuredPath: String
        switch provider {
        case .claudeCode:
            configuredPath = configStore.claudeCodeExecutablePath
        case .codex:
            configuredPath = configStore.codexExecutablePath
        }
        return PlanBackedExecutableResolver.resolve(
            configuredPath: configuredPath,
            commandName: provider.commandName
        )
    }

    private func runClaudeCode(executable: URL, prompt: String, timeout: TimeInterval) async throws -> String {
        let result = try await runner.run(
            executable: executable,
            arguments: [
                "-p",
                "--output-format", "text",
                "--no-session-persistence",
                "--max-turns", "1",
            ],
            environment: planBackedEnvironment,
            standardInput: Data(prompt.utf8),
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw PlanBackedError.commandFailed(
                provider: .claudeCode,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCodex(executable: URL, prompt: String, timeout: TimeInterval) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await runner.run(
            executable: executable,
            arguments: [
                "exec",
                "--ephemeral",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--color", "never",
                "--output-last-message", outputURL.path,
                "-",
            ],
            environment: planBackedEnvironment,
            standardInput: Data(prompt.utf8),
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw PlanBackedError.commandFailed(
                provider: .codex,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        if let output = try? String(contentsOf: outputURL, encoding: .utf8),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var planBackedEnvironment: [String: String] {
        [
            "ANTHROPIC_API_KEY": "",
            "OPENAI_API_KEY": "",
            "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
            "NO_COLOR": "1",
        ]
    }

    public enum PlanBackedError: Error, Equatable {
        case missingExecutable(String)
        case commandFailed(provider: PlanBackedProvider, exitCode: Int32, stderr: String)
        case malformedJSON
    }
}

public enum PlanBackedJSON {
    public static func extractJSONObjectData(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), let data = trimmed.data(using: .utf8) {
            return data
        }

        var depth = 0
        var start: String.Index?
        var isInString = false
        var isEscaped = false

        for index in trimmed.indices {
            let character = trimmed[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start {
                    let end = trimmed.index(after: index)
                    let json = String(trimmed[start..<end])
                    guard let data = json.data(using: .utf8) else { break }
                    return data
                }
            }
        }

        throw PlanBackedCLIClient.PlanBackedError.malformedJSON
    }
}

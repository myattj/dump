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
        try await Task.detached(priority: .utility) {
            try Self.runSync(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                timeout: timeout
            )
        }.value
    }

    private static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> LocalPlanCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)

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
        try process.run()
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        return LocalPlanCommandResult(
            stdout: String(data: stdoutCollector.finish(), encoding: .utf8) ?? "",
            stderr: String(data: stderrCollector.finish(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
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

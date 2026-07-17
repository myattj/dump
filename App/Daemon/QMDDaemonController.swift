import Foundation
import OSLog

/// Locally-running qmd search daemon. The app bundles Node + qmd at build
/// time under `.app/Contents/Resources/runtime/`; this actor launches the
/// process, holds the chosen port, handles health probes and restart, and
/// terminates only the process instance it launched.
public actor QMDDaemonController {
    public struct Config: Sendable {
        public var runtimeDirectory: URL?
        public var portRange: ClosedRange<Int>
        public var healthPath: String
        public var startupGracePeriod: Duration
        public var maxRestartAttempts: Int

        public init(
            runtimeDirectory: URL? = nil,
            portRange: ClosedRange<Int> = 49_152...49_252,
            healthPath: String = "/health",
            startupGracePeriod: Duration = .seconds(30),
            maxRestartAttempts: Int = 3
        ) {
            self.runtimeDirectory = runtimeDirectory
            self.portRange = portRange
            self.healthPath = healthPath
            self.startupGracePeriod = startupGracePeriod
            self.maxRestartAttempts = maxRestartAttempts
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case crashed(reason: String)
    }

    private let config: Config
    private let process: ProcessLaunching
    private let transport: HTTPTransporting
    private let storage: StoragePreference
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "qmd")

    private var state: State = .stopped
    private var port: Int?
    private var ringBuffer: [String] = []
    private var restartAttempts = 0
    private var launchGeneration: UInt = 0

    public init(
        config: Config = Config(),
        process: ProcessLaunching = SystemProcessLauncher(),
        transport: HTTPTransporting = HTTPTransport(),
        storage: StoragePreference = .shared
    ) {
        self.config = config
        self.process = process
        self.transport = transport
        self.storage = storage
    }

    public func currentState() -> State { state }
    public func currentPort() -> Int? {
        guard case .running(let port) = state else { return nil }
        return port
    }
    public func recentLog(limit: Int = 50) -> [String] { Array(ringBuffer.suffix(limit)) }

    /// Bundled `node` binary. Used by the CLI runner that backs qmd's
    /// write-side commands (collection management, update, embed).
    public func nodeExecutableURL() -> URL { nodeURL() }

    /// Path to qmd's CLI entrypoint inside the bundled runtime.
    public func qmdCLIScriptURL() -> URL { qmdEntryURL() }

    /// Environment passed to qmd CLI subprocesses so they read/write the same
    /// data directory as the long-running daemon.
    public func cliEnvironment() -> [String: String] {
        ["QMD_DATA_DIR": storage.root.path]
    }

    public func startIfNeeded() async {
        if case .running = state { return }
        await start()
    }

    public func start() async {
        guard !Task.isCancelled else { return }
        launchGeneration &+= 1
        let generation = launchGeneration
        state = .starting
        let chosen = pickPort()
        port = chosen
        DiagnosticLog.event(.info, category: "qmd", "starting daemon", metadata: [
            "port": String(chosen),
        ])
        let env = [
            "QMD_PORT": String(chosen),
            "QMD_DATA_DIR": storage.root.path,
        ]
        do {
            try Task.checkCancellation()
            try process.launch(
                executable: nodeURL(),
                arguments: [qmdEntryURL().path, "mcp", "--http", "--port", String(chosen)],
                environment: env,
                onLine: { [weak self] line in
                    Task { await self?.appendLog(line) }
                },
                onExit: { [weak self] code in
                    Task { await self?.handleExit(code: code, generation: generation) }
                }
            )
            try await waitForHealth(port: chosen)
            try Task.checkCancellation()
            guard generation == launchGeneration else { return }
            state = .running(port: chosen)
            restartAttempts = 0
            log.info("qmd up on \(chosen, privacy: .public)")
            DiagnosticLog.event(.info, category: "qmd", "daemon healthy", metadata: [
                "port": String(chosen),
            ])
        } catch is CancellationError {
            guard generation == launchGeneration else { return }
            launchGeneration &+= 1
            process.terminate()
            state = .stopped
            port = nil
        } catch {
            guard generation == launchGeneration else { return }
            launchGeneration &+= 1
            process.terminate()
            state = .crashed(reason: String(describing: error))
            port = nil
            log.error("qmd start failed: \(String(describing: error), privacy: .public)")
            DiagnosticLog.event(.error, category: "qmd", "daemon start failed", metadata: [
                "port": String(chosen),
                "error": String(describing: error),
            ])
        }
    }

    public func stop() async {
        DiagnosticLog.event(.info, category: "qmd", "stopping daemon", metadata: [
            "port": port.map(String.init) ?? "",
        ])
        launchGeneration &+= 1
        process.terminate()
        state = .stopped
        port = nil
    }

    public func restart() async {
        await stop()
        await start()
    }

    public func waitForHealthCheck() async throws {
        guard let chosen = port else { throw HealthError.notRunning }
        try await waitForHealth(port: chosen)
    }

    private func waitForHealth(port: Int) async throws {
        let deadline = ContinuousClock.now + config.startupGracePeriod
        let url = URL(string: "http://localhost:\(port)\(config.healthPath)")!
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let resp = try await transport.send(HTTPRequest(method: "GET", url: url, timeout: 2))
                if resp.status == 200 { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // ignore until grace period elapses
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HealthError.timedOut
    }

    private func handleExit(code: Int32, generation: UInt) async {
        guard generation == launchGeneration else { return }
        if state == .stopped { return }
        ringBuffer.append("[exit] code=\(code)")
        DiagnosticLog.event(.warning, category: "qmd", "daemon exited", metadata: [
            "code": String(code),
            "restart_attempt": String(restartAttempts + 1),
        ])
        restartAttempts += 1
        if restartAttempts <= config.maxRestartAttempts {
            log.warning("qmd exited (\(code)), restart \(self.restartAttempts)/\(self.config.maxRestartAttempts)")
            await start()
        } else {
            state = .crashed(reason: "exited with \(code) after \(restartAttempts) restart attempts")
            port = nil
            log.error("qmd gave up after \(self.restartAttempts) restart attempts")
            DiagnosticLog.event(.error, category: "qmd", "daemon restart limit reached", metadata: [
                "code": String(code),
                "restart_attempts": String(restartAttempts),
            ])
        }
    }

    private func appendLog(_ line: String) {
        ringBuffer.append(line)
        if ringBuffer.count > 500 { ringBuffer.removeFirst(ringBuffer.count - 500) }
        DiagnosticLog.event(.debug, category: "qmd.process", line)
    }

    private func pickPort() -> Int {
        for candidate in config.portRange where SystemProcessLauncher.isPortFree(candidate) {
            return candidate
        }
        return config.portRange.lowerBound
    }

    private func nodeURL() -> URL {
        let base = config.runtimeDirectory ?? bundledRuntimeDirectory()
        return base.appendingPathComponent("node/bin/node")
    }

    private func qmdEntryURL() -> URL {
        let base = config.runtimeDirectory ?? bundledRuntimeDirectory()
        return base.appendingPathComponent("qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js")
    }

    private func bundledRuntimeDirectory() -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("runtime", isDirectory: true) {
            return resource
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dump-runtime")
    }

    public enum HealthError: Error, Equatable {
        case timedOut
        case notRunning
    }
}

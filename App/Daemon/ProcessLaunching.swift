import Foundation

/// Process launching is non-trivial to test, so the daemon controller talks
/// to a small protocol that fakes can substitute. The system implementation
/// wraps `Foundation.Process` plus EOF-watchdog patterns for clean death.
public protocol ProcessLaunching: Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws

    func terminate()

    func reapOrphans(named name: String)
}

public final class SystemProcessLauncher: ProcessLaunching, @unchecked Sendable {
    private var process: Process?
    private var pipe: Pipe?

    public init() {}

    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        var fullEnv = ProcessInfo.processInfo.environment
        for (k, v) in environment { fullEnv[k] = v }
        proc.environment = fullEnv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.terminationHandler = { p in
            onExit(p.terminationStatus)
        }
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(whereSeparator: { $0.isNewline }) {
                onLine(String(line))
            }
        }
        try proc.run()
        self.process = proc
        self.pipe = pipe
    }

    public func terminate() {
        process?.terminate()
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
    }

    public func reapOrphans(named name: String) {
        // Best-effort: find prior qmd processes for this user and SIGTERM them.
        // We deliberately keep this conservative — only match basename to avoid
        // killing unrelated `node` processes.
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-f", "@tobilu/qmd/dist/cli/qmd.js"]
        try? task.run()
        task.waitUntilExit()
    }

    public static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                Darwin.bind(fd, ptr, size)
            }
        }
        return result == 0
    }
}

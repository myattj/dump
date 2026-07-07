import AppKit
import Foundation

public enum DiagnosticLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct NetworkDiagnosticRecord: Sendable {
    public enum Phase: String, Sendable {
        case started
        case finished
        case failed
    }

    public var date: Date
    public var id: String
    public var phase: Phase
    public var category: String
    public var method: String
    public var url: String
    public var host: String
    public var path: String
    public var status: Int?
    public var durationMS: Int?
    public var requestBytes: Int?
    public var responseBytes: Int?
    public var errorDomain: String?
    public var errorCode: Int?
    public var errorDescription: String?

    public init(
        date: Date = Date(),
        id: String,
        phase: Phase,
        category: String,
        method: String,
        url: String,
        host: String,
        path: String,
        status: Int? = nil,
        durationMS: Int? = nil,
        requestBytes: Int? = nil,
        responseBytes: Int? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorDescription: String? = nil
    ) {
        self.date = date
        self.id = id
        self.phase = phase
        self.category = category
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.status = status
        self.durationMS = durationMS
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }
}

public enum DiagnosticLog {
    public static let subsystem = "com.joshmyatt.dump"

    public static var logsDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Dump", isDirectory: true)
    }

    public static var appLogURL: URL {
        logsDirectory.appendingPathComponent("dump.jsonl")
    }

    public static var networkLogURL: URL {
        logsDirectory.appendingPathComponent("network.jsonl")
    }

    public static func prepare() {
        Task.detached(priority: .utility) {
            await DiagnosticLogWriter.shared.prepareFiles()
        }
    }

    public static func event(
        _ level: DiagnosticLogLevel = .info,
        category: String,
        _ message: String,
        metadata: [String: String] = [:],
        date: Date = Date()
    ) {
        let entry = DiagnosticEvent(date: date, level: level, category: category, message: message, metadata: metadata)
        Task.detached(priority: .utility) {
            await DiagnosticLogWriter.shared.writeEvent(entry)
        }
    }

    public static func network(_ record: NetworkDiagnosticRecord) {
        Task.detached(priority: .utility) {
            await DiagnosticLogWriter.shared.writeNetwork(record)
        }
    }

    @MainActor
    public static func openLogsDirectory() {
        ensureFilesExist()
        NSWorkspace.shared.open(logsDirectory)
    }

    @MainActor
    public static func openAppLog() {
        ensureFilesExist()
        NSWorkspace.shared.open(appLogURL)
    }

    @MainActor
    public static func openNetworkLog() {
        ensureFilesExist()
        NSWorkspace.shared.open(networkLogURL)
    }

    @MainActor
    public static func copyTailCommandToPasteboard() {
        ensureFilesExist()
        let command = "tail -F \(shellEscaped(appLogURL.path)) \(shellEscaped(networkLogURL.path))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        event(.info, category: "diagnostics", "copied log tail command")
    }

    private static func ensureFilesExist() {
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        for url in [appLogURL, networkLogURL] where !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct DiagnosticEvent: Sendable {
    var date: Date
    var level: DiagnosticLogLevel
    var category: String
    var message: String
    var metadata: [String: String]
}

private actor DiagnosticLogWriter {
    static let shared = DiagnosticLogWriter()

    private let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private let backupCount = 3
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func prepareFiles() {
        try? FileManager.default.createDirectory(at: DiagnosticLog.logsDirectory, withIntermediateDirectories: true)
        createFileIfNeeded(DiagnosticLog.appLogURL)
        createFileIfNeeded(DiagnosticLog.networkLogURL)
    }

    func writeEvent(_ event: DiagnosticEvent) {
        var object: [String: Any] = [
            "ts": formatter.string(from: event.date),
            "kind": "event",
            "level": event.level.rawValue,
            "category": event.category,
            "message": event.message,
        ]
        if !event.metadata.isEmpty {
            object["meta"] = event.metadata
        }
        writeJSONObject(object, to: DiagnosticLog.appLogURL)
    }

    func writeNetwork(_ record: NetworkDiagnosticRecord) {
        var object: [String: Any] = [
            "ts": formatter.string(from: record.date),
            "kind": "network",
            "id": record.id,
            "phase": record.phase.rawValue,
            "category": record.category,
            "method": record.method,
            "url": record.url,
            "host": record.host,
            "path": record.path,
        ]
        if let status = record.status { object["status"] = status }
        if let durationMS = record.durationMS { object["duration_ms"] = durationMS }
        if let requestBytes = record.requestBytes { object["request_bytes"] = requestBytes }
        if let responseBytes = record.responseBytes { object["response_bytes"] = responseBytes }
        if let errorDomain = record.errorDomain { object["error_domain"] = errorDomain }
        if let errorCode = record.errorCode { object["error_code"] = errorCode }
        if let errorDescription = record.errorDescription { object["error"] = errorDescription }

        writeJSONObject(object, to: DiagnosticLog.appLogURL)
        writeJSONObject(object, to: DiagnosticLog.networkLogURL)
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) {
        prepareFiles()
        rotateIfNeeded(url)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let newline = "\n".data(using: .utf8) else {
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: newline)
        } catch {
            // Diagnostics must never make app behavior depend on file I/O.
        }
    }

    private func createFileIfNeeded(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size >= maxFileBytes else { return }

        let oldest = rotatedURL(for: url, index: backupCount)
        try? FileManager.default.removeItem(at: oldest)

        if backupCount > 1 {
            for index in stride(from: backupCount - 1, through: 1, by: -1) {
                let source = rotatedURL(for: url, index: index)
                let destination = rotatedURL(for: url, index: index + 1)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(at: source, to: destination)
                }
            }
        }

        let firstBackup = rotatedURL(for: url, index: 1)
        try? FileManager.default.moveItem(at: url, to: firstBackup)
        createFileIfNeeded(url)
    }

    private func rotatedURL(for url: URL, index: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(index)")
    }
}

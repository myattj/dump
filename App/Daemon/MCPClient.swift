import Foundation
import OSLog

/// Speaks MCP-over-HTTP (the Streamable HTTP transport) to qmd's `POST /mcp`
/// endpoint for read operations, and shells out to the bundled qmd CLI for
/// the few write operations qmd doesn't expose over MCP.
///
/// MCP requires the client to `initialize` once per session and quote the
/// returned `Mcp-Session-Id` header on every subsequent call. We cache the
/// session per-port so it survives across requests; if the daemon restarts
/// on a new port (or the cached session 404s) we re-initialize transparently.
public actor MCPClient: QMDClienting {
    private let daemon: QMDDaemonController
    private let transport: HTTPTransporting
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "mcp")

    private var sessionPort: Int?
    private var sessionID: String?

    public init(daemon: QMDDaemonController, transport: HTTPTransporting = HTTPTransport()) {
        self.daemon = daemon
        self.transport = transport
    }

    // MARK: - QMDClienting

    public func query(_ q: QMDQuery) async throws -> [QMDHit] {
        var args: [String: AnyEncodable] = [
            "searches": AnyEncodable(q.searches),
            "limit": AnyEncodable(q.limit),
            "rerank": AnyEncodable(q.rerank),
        ]
        if let collections = q.collections { args["collections"] = AnyEncodable(collections) }
        if let intent = q.intent { args["intent"] = AnyEncodable(intent) }
        if let minScore = q.minScore { args["minScore"] = AnyEncodable(minScore) }

        let envelope = try await call(tool: "query", arguments: args)
        guard let structured = envelope.structuredContent else {
            return []
        }
        return try decode(QueryResult.self, from: structured).results
    }

    public func get(file: String, fromLine: Int? = nil, maxLines: Int? = nil) async throws -> String {
        var args: [String: AnyEncodable] = ["file": AnyEncodable(file)]
        if let fromLine { args["fromLine"] = AnyEncodable(fromLine) }
        if let maxLines { args["maxLines"] = AnyEncodable(maxLines) }
        let envelope = try await call(tool: "get", arguments: args)
        return envelope.textContent
    }

    public func status() async throws -> QMDStatus {
        let envelope = try await call(tool: "status", arguments: [:])
        guard let structured = envelope.structuredContent else {
            throw QMDClientError.malformedResponse("status returned no structuredContent")
        }
        return try decode(QMDStatus.self, from: structured)
    }

    public func runCLI(arguments: [String]) async throws -> QMDCLIOutput {
        let node = await daemon.nodeExecutableURL()
        let script = await daemon.qmdCLIScriptURL()
        let env = await daemon.cliEnvironment()

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = node
            process.arguments = [script.path] + arguments
            var fullEnv = ProcessInfo.processInfo.environment
            for (k, v) in env { fullEnv[k] = v }
            process.environment = fullEnv

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = QMDCLIOutput(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
            if output.exitCode != 0 {
                throw QMDClientError.cliFailed(exitCode: output.exitCode, stderr: output.stderr)
            }
            return output
        }.value
    }

    // MARK: - MCP plumbing

    private struct CallEnvelope {
        let textContent: String
        let structuredContent: Any?
    }

    private func call(tool: String, arguments: [String: AnyEncodable]) async throws -> CallEnvelope {
        guard let port = await daemon.currentPort() else { throw QMDClientError.daemonUnavailable }
        DiagnosticLog.event(.debug, category: "mcp", "calling qmd tool", metadata: [
            "tool": tool,
            "port": String(port),
        ])
        do {
            try await ensureSession(port: port)

            // Flatten AnyEncodable to JSON-serializable Any before handing off — if we
            // nest AnyEncodable inside another AnyEncodable, the inner `encode(to:)`
            // base64-encodes its payload and qmd silently returns no hits.
            let argsAny = try arguments.mapValues { try $0.toJSONObject() }
            let body = try jsonRPCRaw(
                method: "tools/call",
                params: [
                    "name": tool,
                    "arguments": argsAny,
                ]
            )
            let resp = try await postMCP(port: port, body: body, expectSession: true)
            // qmd may invalidate the cached session if it restarted; one retry is fine.
            if resp.status == 404 || resp.status == 400 {
                DiagnosticLog.event(.warning, category: "mcp", "cached session rejected", metadata: [
                    "tool": tool,
                    "port": String(port),
                    "status": String(resp.status),
                ])
                sessionID = nil
                try await ensureSession(port: port)
                let retried = try await postMCP(port: port, body: body, expectSession: true)
                let envelope = try parseEnvelope(retried)
                DiagnosticLog.event(.debug, category: "mcp", "qmd tool completed after retry", metadata: [
                    "tool": tool,
                    "port": String(port),
                ])
                return envelope
            }
            let envelope = try parseEnvelope(resp)
            DiagnosticLog.event(.debug, category: "mcp", "qmd tool completed", metadata: [
                "tool": tool,
                "port": String(port),
            ])
            return envelope
        } catch {
            DiagnosticLog.event(.error, category: "mcp", "qmd tool failed", metadata: [
                "tool": tool,
                "port": String(port),
                "error": String(describing: error),
            ])
            throw error
        }
    }

    private func ensureSession(port: Int) async throws {
        if sessionID != nil, sessionPort == port { return }
        sessionPort = port
        sessionID = nil

        let body = try jsonRPCRaw(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: String](),
                "clientInfo": [
                    "name": "dump",
                    "version": "0.1.0",
                ],
            ]
        )
        let initResp = try await postMCP(port: port, body: body, expectSession: false)
        guard (200..<300).contains(initResp.status) else {
            throw QMDClientError.mcpError(code: initResp.status, message: String(data: initResp.body, encoding: .utf8) ?? "")
        }
        guard let sid = headerCaseInsensitive(initResp.headers, "mcp-session-id"), !sid.isEmpty else {
            throw QMDClientError.malformedResponse("initialize did not return mcp-session-id")
        }
        sessionID = sid

        // MCP requires the client to send notifications/initialized after init.
        let notifyBody = try jsonRPCRaw(method: "notifications/initialized", params: nil, includeID: false)
        _ = try await postMCP(port: port, body: notifyBody, expectSession: true)
        log.debug("mcp session \(sid, privacy: .public) on port \(port, privacy: .public)")
        DiagnosticLog.event(.debug, category: "mcp", "initialized session", metadata: [
            "port": String(port),
            "session": String(sid.prefix(8)),
        ])
    }

    private func postMCP(port: Int, body: Data, expectSession: Bool) async throws -> HTTPResponse {
        let url = URL(string: "http://localhost:\(port)/mcp")!
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if expectSession, let sid = sessionID {
            headers["Mcp-Session-Id"] = sid
        }
        return try await transport.send(HTTPRequest(method: "POST", url: url, headers: headers, body: body, timeout: 30))
    }

    private func parseEnvelope(_ resp: HTTPResponse) throws -> CallEnvelope {
        guard (200..<300).contains(resp.status) else {
            throw QMDClientError.mcpError(code: resp.status, message: String(data: resp.body, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: resp.body, options: [])
        guard let obj = json as? [String: Any] else {
            throw QMDClientError.malformedResponse("response is not a JSON object")
        }
        if let err = obj["error"] as? [String: Any] {
            let code = err["code"] as? Int ?? -1
            let message = err["message"] as? String ?? ""
            throw QMDClientError.mcpError(code: code, message: message)
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw QMDClientError.malformedResponse("response missing result")
        }
        var text = ""
        if let content = result["content"] as? [[String: Any]] {
            text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return CallEnvelope(textContent: text, structuredContent: result["structuredContent"])
    }

    private func jsonRPCRaw(method: String, params: [String: Any]?, includeID: Bool = true) throws -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if includeID { obj["id"] = UUID().uuidString }
        if let params { obj["params"] = params }
        return try JSONSerialization.data(withJSONObject: obj, options: [])
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw QMDClientError.malformedResponse(String(describing: error))
        }
    }

    private func headerCaseInsensitive(_ headers: [String: String], _ key: String) -> String? {
        for (k, v) in headers where k.caseInsensitiveCompare(key) == .orderedSame {
            return v
        }
        return nil
    }

    private struct QueryResult: Decodable {
        let results: [QMDHit]
    }
}

/// Erased Encodable used to build JSON-RPC param maps without leaning on
/// AnyHashable. Carries the value forward as a JSONSerialization-friendly
/// object so the wire layer can use plain JSONSerialization on the way out.
struct AnyEncodable: Encodable, @unchecked Sendable {
    private let _toJSON: () throws -> Any

    init<T: Encodable>(_ value: T) {
        self._toJSON = {
            let data = try JSONEncoder().encode(value)
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
    }

    func encode(to encoder: Encoder) throws {
        let obj = try _toJSON()
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        var container = encoder.singleValueContainer()
        // Round-trip via a JSONDecoder-compatible container — keeps the
        // ad-hoc dict shape without needing a typed wrapper for every value.
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let str = json as? String { try container.encode(str) }
            else if let int = json as? Int { try container.encode(int) }
            else if let dbl = json as? Double { try container.encode(dbl) }
            else if let bool = json as? Bool { try container.encode(bool) }
            else { try container.encode(data) }
        }
    }

    func toJSONObject() throws -> Any { try _toJSON() }
}

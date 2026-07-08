import Foundation
import OSLog

/// Minimal JSON HTTP client used by every outbound integration. Defined as
/// a protocol so tests inject a stub instead of touching the network.
public protocol HTTPTransporting: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Response body as it arrives, one line per element (SSE / NDJSON).
    /// Throws `HTTPError.status` for non-2xx responses.
    func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error>
}

public extension HTTPTransporting {
    /// Buffered fallback: one `send()`, then the body replayed line by line.
    /// Keeps test stubs and simple transports compiling; `HTTPTransport`
    /// overrides with true incremental delivery.
    func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    guard (200..<300).contains(response.status) else {
                        throw HTTPError.status(response.status, String(data: response.body, encoding: .utf8) ?? "")
                    }
                    let body = String(data: response.body, encoding: .utf8) ?? ""
                    for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
                        // CRLF-delimited SSE bodies leave a trailing CR per line.
                        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
                        if !line.isEmpty { continuation.yield(String(line)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = .init()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPError: Error, Equatable {
    case status(Int, String)
    case malformedResponse
    case decoding(String)
    case timeout
}

/// Production implementation backed by `URLSession`.
public struct HTTPTransport: HTTPTransporting {
    private static let log = Logger(subsystem: DiagnosticLog.subsystem, category: "network")

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let requestID = Self.requestID()
        let diagnostics = Self.diagnostics(for: request)
        let startedAt = Date()
        Self.log.debug("http start id=\(requestID, privacy: .public) category=\(diagnostics.category, privacy: .public) method=\(request.method, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public)")
        DiagnosticLog.network(NetworkDiagnosticRecord(
            date: startedAt,
            id: requestID,
            phase: .started,
            category: diagnostics.category,
            method: request.method,
            url: diagnostics.redactedURL,
            host: diagnostics.host,
            path: diagnostics.path,
            requestBytes: request.body?.count
        ))

        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.timeoutInterval = request.timeout
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await session.data(for: req)
            let durationMS = Self.durationMS(since: startedAt)
            guard let http = response as? HTTPURLResponse else {
                Self.log.error("http malformed id=\(requestID, privacy: .public) method=\(request.method, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public) duration_ms=\(durationMS, privacy: .public)")
                throw HTTPError.malformedResponse
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                if let k = pair.key as? String, let v = pair.value as? String { acc[k] = v }
            }
            DiagnosticLog.network(NetworkDiagnosticRecord(
                id: requestID,
                phase: .finished,
                category: diagnostics.category,
                method: request.method,
                url: diagnostics.redactedURL,
                host: diagnostics.host,
                path: diagnostics.path,
                status: http.statusCode,
                durationMS: durationMS,
                requestBytes: request.body?.count,
                responseBytes: data.count
            ))
            Self.log.info("http finish id=\(requestID, privacy: .public) status=\(http.statusCode, privacy: .public) method=\(request.method, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public) duration_ms=\(durationMS, privacy: .public) response_bytes=\(data.count, privacy: .public)")
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            let durationMS = Self.durationMS(since: startedAt)
            let nsError = error as NSError
            DiagnosticLog.network(NetworkDiagnosticRecord(
                id: requestID,
                phase: .failed,
                category: diagnostics.category,
                method: request.method,
                url: diagnostics.redactedURL,
                host: diagnostics.host,
                path: diagnostics.path,
                durationMS: durationMS,
                requestBytes: request.body?.count,
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                errorDescription: nsError.localizedDescription
            ))
            Self.log.error("http failed id=\(requestID, privacy: .public) method=\(request.method, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public) duration_ms=\(durationMS, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                let requestID = Self.requestID()
                let diagnostics = Self.diagnostics(for: request)
                let startedAt = Date()
                Self.log.debug("http stream start id=\(requestID, privacy: .public) category=\(diagnostics.category, privacy: .public) method=\(request.method, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public)")

                var req = URLRequest(url: request.url)
                req.httpMethod = request.method
                req.httpBody = request.body
                req.timeoutInterval = request.timeout
                for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw HTTPError.malformedResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line + "\n"
                            if errorBody.count > 4096 { break }
                        }
                        throw HTTPError.status(http.statusCode, errorBody)
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    Self.log.info("http stream finish id=\(requestID, privacy: .public) status=\(http.statusCode, privacy: .public) duration_ms=\(Self.durationMS(since: startedAt), privacy: .public)")
                    continuation.finish()
                } catch {
                    let nsError = error as NSError
                    Self.log.error("http stream failed id=\(requestID, privacy: .public) url=\(diagnostics.redactedURL, privacy: .public) duration_ms=\(Self.durationMS(since: startedAt), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct RequestDiagnostics {
        let redactedURL: String
        let host: String
        let path: String
        let category: String
    }

    private static func diagnostics(for request: HTTPRequest) -> RequestDiagnostics {
        let host = request.url.host ?? ""
        let path = request.url.path.isEmpty ? "/" : request.url.path
        return RequestDiagnostics(
            redactedURL: redactedURL(request.url),
            host: host,
            path: path,
            category: category(host: host, path: path)
        )
    }

    private static func redactedURL(_ url: URL) -> String {
        let scheme = url.scheme.map { "\($0)://" } ?? ""
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query == nil ? "" : "?<redacted>"
        return "\(scheme)\(host)\(port)\(path)\(query)"
    }

    private static func category(host: String, path: String) -> String {
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1" {
            if path == "/health" { return "qmd.health" }
            if path == "/mcp" { return "qmd.mcp" }
            if path.hasPrefix("/api/") { return "ollama" }
            return "local"
        }
        if lowerHost.contains("anthropic") { return "anthropic" }
        if lowerHost.contains("openai") { return "openai" }
        if lowerHost.contains("bedrock") || lowerHost.contains("amazonaws.com") { return "bedrock" }
        return "custom"
    }

    private static func requestID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func durationMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}

public extension HTTPTransporting {
    func sendJSON<T: Decodable>(_ request: HTTPRequest, decode: T.Type) async throws -> T {
        let response = try await send(request)
        guard (200..<300).contains(response.status) else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw HTTPError.status(response.status, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw HTTPError.decoding(String(describing: error))
        }
    }
}

extension HTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .status(code, _): "The server returned an error (HTTP \(code))."
        case .malformedResponse: "The server returned an unreadable response."
        case let .decoding(detail): "Couldn't read the server's response. (\(detail))"
        case .timeout: "The request timed out."
        }
    }
}

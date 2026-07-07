import Foundation
import os
@testable import Dump

/// Records every outgoing request and replays canned responses keyed by URL
/// path. Designed for clarity in tests, not throughput.
public final class MockHTTPTransport: HTTPTransporting, @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private struct State: Sendable {
        var handlers: [String: Handler] = [:]
        var fallback: Handler?
        var sentRequests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func stub(path: String, handler: @escaping Handler) {
        state.withLock { $0.handlers[path] = handler }
    }

    public func stub(path: String, status: Int = 200, json: Any) {
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        stub(path: path) { _ in
            HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
        }
    }

    public func setFallback(_ handler: @escaping Handler) {
        state.withLock { $0.fallback = handler }
    }

    public var sentRequests: [HTTPRequest] {
        state.withLock { $0.sentRequests }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler: Handler? = state.withLock { s in
            s.sentRequests.append(request)
            return s.handlers[request.url.path] ?? s.fallback
        }
        guard let handler else {
            throw HTTPError.malformedResponse
        }
        return try handler(request)
    }
}

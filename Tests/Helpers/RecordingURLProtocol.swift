import Foundation
import os

/// URLProtocol test double for exercising the production URLSession transport.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let url: URL?
        let body: Data?
    }

    private struct State: @unchecked Sendable {
        var requests: [RecordedRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    static func reset() {
        state.withLock { $0.requests.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(url: request.url, body: Self.readBody(from: request))
        Self.state.withLock { $0.requests.append(recorded) }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Data(#"{"message":{"role":"assistant","content":"{\"type\":\"note\",\"title\":\"Updated\"}"}}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

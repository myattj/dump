import Foundation

/// Minimal JSON HTTP client used by every outbound integration. Defined as
/// a protocol so tests inject a stub instead of touching the network.
public protocol HTTPTransporting: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
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
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.timeoutInterval = request.timeout
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.malformedResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let k = pair.key as? String, let v = pair.value as? String { acc[k] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
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

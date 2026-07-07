import XCTest
import os
@testable import Dump

/// Regression coverage for the MCP wire format. Earlier versions wrapped the
/// `tools/call` arguments in `AnyEncodable`, and Swift's default Codable
/// chain base64-encoded any non-scalar payload — so qmd received a string
/// where it expected an object and silently returned no hits. These tests
/// pin the on-the-wire shape so the bug can't return.
final class MCPClientTests: XCTestCase {
    func testQueryArgumentsAreSentAsRealJSONObject() async throws {
        let transport = MockHTTPTransport()
        let captured = OSAllocatedUnfairLock<Data?>(initialState: nil)
        transport.setFallback { req in
            if req.url.path == "/mcp" {
                let isInitialize = req.body.flatMap {
                    String(data: $0, encoding: .utf8)?.contains("\"method\":\"initialize\"")
                } ?? false
                if isInitialize {
                    return HTTPResponse(
                        status: 200,
                        headers: ["Mcp-Session-Id": "sid-1"],
                        body: Data("{\"result\":{}}".utf8)
                    )
                }
                if let body = req.body {
                    captured.withLock { $0 = body }
                }
                let payload: [String: Any] = [
                    "result": [
                        "content": [["type": "text", "text": ""]],
                        "structuredContent": ["results": []],
                    ]
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                return HTTPResponse(status: 200, headers: [:], body: data)
            }
            return HTTPResponse(status: 404)
        }

        let daemon = QMDDaemonController(
            process: MockProcessLauncher(),
            transport: transport
        )
        await daemon.start()
        let client = MCPClient(daemon: daemon, transport: transport)

        _ = try await client.query(QMDQuery(
            searches: [
                QMDSearchTerm(type: .lex, query: "hello"),
                QMDSearchTerm(type: .vec, query: "hello"),
            ],
            limit: 10,
            rerank: true
        ))

        let body = captured.withLock { $0 }
        XCTAssertNotNil(body, "tools/call request was not captured")
        let callBody = (try? JSONSerialization.jsonObject(with: body!)) as? [String: Any] ?? [:]
        let params = callBody["params"] as? [String: Any]
        let arguments = params?["arguments"] as? [String: Any]
        XCTAssertNotNil(arguments, "arguments must serialize as a JSON object, not a string")
        let searches = arguments?["searches"] as? [[String: Any]]
        XCTAssertNotNil(searches, "searches must be an array of objects, not a base64 string")
        XCTAssertEqual(searches?.count, 2)
        XCTAssertEqual(searches?.first?["type"] as? String, "lex")
        XCTAssertEqual(searches?.first?["query"] as? String, "hello")
        XCTAssertEqual(arguments?["limit"] as? Int, 10)
        XCTAssertEqual(arguments?["rerank"] as? Bool, true)
    }
}

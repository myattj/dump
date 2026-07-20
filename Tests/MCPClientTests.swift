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
            if req.url.path == "/health" {
                return HTTPResponse(status: 200)
            }
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

    func testModelBackedQueryGetsExtendedTimeoutWithoutBroadeningOtherMCPRequests() async throws {
        let transport = MockHTTPTransport()
        let queryAttempts = OSAllocatedUnfairLock(initialState: 0)
        transport.setFallback { req in
            if req.url.path == "/health" {
                return HTTPResponse(status: 200)
            }
            guard req.url.path == "/mcp",
                  let body = req.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = object["method"] as? String else {
                return HTTPResponse(status: 404)
            }

            if method == "initialize" {
                return HTTPResponse(
                    status: 200,
                    headers: ["Mcp-Session-Id": "sid-timeout"],
                    body: Data("{\"result\":{}}".utf8)
                )
            }
            if method == "notifications/initialized" {
                return HTTPResponse(status: 200, body: Data("{\"result\":{}}".utf8))
            }

            let params = object["params"] as? [String: Any]
            let tool = params?["name"] as? String
            let structuredContent: [String: Any]
            switch tool {
            case "query":
                let attempt = queryAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    return HTTPResponse(status: 404)
                }
                structuredContent = ["results": []]
            case "status":
                structuredContent = [
                    "totalDocuments": 0,
                    "needsEmbedding": 0,
                    "hasVectorIndex": false,
                    "collections": [],
                ]
            default:
                return HTTPResponse(status: 404)
            }
            let response: [String: Any] = [
                "result": [
                    "content": [],
                    "structuredContent": structuredContent,
                ],
            ]
            return HTTPResponse(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: response)
            )
        }

        let daemon = QMDDaemonController(
            process: MockProcessLauncher(),
            transport: transport
        )
        await daemon.start()
        let client = MCPClient(daemon: daemon, transport: transport)

        _ = try await client.query(QMDQuery(
            searches: [QMDSearchTerm(type: .vec, query: "cold model")],
            rerank: true
        ))
        _ = try await client.status()

        let calls = transport.sentRequests.compactMap { request -> (method: String, tool: String?, timeout: TimeInterval)? in
            guard request.url.path == "/mcp",
                  let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = object["method"] as? String else {
                return nil
            }
            let params = object["params"] as? [String: Any]
            return (method, params?["name"] as? String, request.timeout)
        }

        XCTAssertEqual(calls.filter { $0.method == "initialize" }.map(\.timeout), [30, 30])
        XCTAssertEqual(calls.filter { $0.method == "notifications/initialized" }.map(\.timeout), [30, 30])
        XCTAssertEqual(
            calls.filter { $0.tool == "query" }.map(\.timeout),
            [TimeInterval(10 * 60), TimeInterval(10 * 60)]
        )
        XCTAssertEqual(calls.filter { $0.tool == "status" }.map(\.timeout), [30])
    }

    func testCLIProcessCancellationTerminatesOwnedProcess() async throws {
        let runner = QMDCLIProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: ProcessInfo.processInfo.environment
        )
        let task = Task { try await runner.run() }

        var launchedPID: pid_t?
        for _ in 0..<200 {
            if let pid = runner.runningProcessIdentifier() {
                launchedPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(launchedPID)
        defer {
            if Darwin.kill(pid, 0) == 0 {
                Darwin.kill(pid, SIGKILL)
            }
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation owns and terminates this exact child.
        }

        for _ in 0..<200 where Darwin.kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
    }
}

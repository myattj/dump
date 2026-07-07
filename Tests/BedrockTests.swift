import XCTest
@testable import Dump

final class BedrockClassifierTests: XCTestCase {
    func testClassifiesThroughConverseAndSignsRequest() async throws {
        let transport = MockHTTPTransport()
        transport.setFallback { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.url.host, "bedrock-runtime.us-east-1.amazonaws.com")
            XCTAssertTrue(request.url.absoluteString.contains("/model/anthropic.claude-3-haiku-20240307-v1%3A0/converse"))
            XCTAssertEqual(request.headers["X-Amz-Date"], "20260102T030405Z")
            XCTAssertEqual(request.headers["X-Amz-Security-Token"], "session")
            XCTAssertTrue(request.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIA_TEST/20260102/us-east-1/bedrock/aws4_request") == true)

            let body = try JSONSerialization.jsonObject(with: request.body ?? Data(), options: []) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.first?["role"] as? String, "user")

            return HTTPResponse(status: 200, json: [
                "output": [
                    "message": [
                        "role": "assistant",
                        "content": [[
                            "text": """
                            {"type":"reminder","title":"Stand up","tags":["health"],"scheduled_at":"2026-05-16T09:00:00Z","deadline_at":"2026-05-16T09:30:00Z","effort_minutes":10,"metadata_confidence":0.9}
                            """
                        ]]
                    ]
                ]
            ])
        }

        let keychain = InMemoryKeychain()
        try keychain.set("AKIA_TEST", for: .bedrockAccessKeyID)
        try keychain.set("SECRET", for: .bedrockSecretAccessKey)
        try keychain.set("session", for: .bedrockSessionToken)
        let store = makeBedrockConfig()
        let classifier = BedrockClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: transport,
            clock: { fixedDate }
        )

        let result = try await classifier.classify("stand up at 9", now: fixedDate)
        XCTAssertEqual(result.type, .reminder)
        XCTAssertEqual(result.title, "Stand up")
        XCTAssertEqual(result.tags, ["health"])
        XCTAssertNotNil(result.scheduledAt)
        XCTAssertNotNil(result.deadlineAt)
        XCTAssertEqual(result.effortMinutes, 10)
        XCTAssertEqual(result.metadataConfidence, 0.9)
    }

    func testThrowsWhenCredentialsMissing() async {
        let classifier = BedrockClassifier(
            keychain: KeychainStore(service: "bedrock.tests.\(UUID())"),
            configStore: makeBedrockConfig(),
            transport: MockHTTPTransport(),
            clock: { fixedDate }
        )
        do {
            _ = try await classifier.classify("hi", now: fixedDate)
            XCTFail("expected missingCredentials")
        } catch let error as BedrockError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class BedrockSynthesizerTests: XCTestCase {
    private func hit(_ docid: String, file: String, title: String? = nil, snippet: String = "") -> QMDHit {
        QMDHit(docid: docid, file: file, title: title, score: 1, context: nil, snippet: snippet)
    }

    func testSynthesizesAndExtractsCitations() async throws {
        let transport = MockHTTPTransport()
        transport.setFallback { _ in
            HTTPResponse(status: 200, json: [
                "output": [
                    "message": [
                        "role": "assistant",
                        "content": [["text": "Per [1], do the thing."]]
                    ]
                ]
            ])
        }
        let keychain = InMemoryKeychain()
        try keychain.set("AKIA_TEST", for: .bedrockAccessKeyID)
        try keychain.set("SECRET", for: .bedrockSecretAccessKey)
        let synth = BedrockSynthesizer(
            keychain: keychain.asKeychainStore(),
            configStore: makeBedrockConfig(),
            transport: transport,
            clock: { fixedDate }
        )

        let result = try await synth.synthesize(
            query: "Q",
            hits: [hit("#1", file: "inbox/a.md", title: "Alpha", snippet: "alpha")]
        )
        XCTAssertEqual(result.text, "Per [1], do the thing.")
        XCTAssertEqual(result.citations.first?.path, "inbox/a.md")
    }
}

private let fixedDate: Date = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "2026-01-02T03:04:05Z")!
}()

private func makeBedrockConfig(
    region: String = "us-east-1",
    classifierModelID: String = "anthropic.claude-3-haiku-20240307-v1:0",
    synthesizerModelID: String = "anthropic.claude-3-5-sonnet-20240620-v1:0"
) -> CustomLLMConfigStore {
    let defaults = UserDefaults(suiteName: "bedrock-\(UUID().uuidString)")!
    let store = CustomLLMConfigStore(defaults: defaults)
    store.bedrockRegion = region
    store.bedrockClassifierModelID = classifierModelID
    store.bedrockSynthesizerModelID = synthesizerModelID
    return store
}

private extension HTTPResponse {
    init(status: Int, json: Any) {
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        self.init(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
}

import XCTest
@testable import Dump

final class ClaudeClassifierTests: XCTestCase {
    func testParsesToolUseResponse() async throws {
        let keychain = InMemoryKeychain()
        try keychain.set("sk-ant-test", for: .anthropicAPIKey)
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/messages", json: [
            "content": [[
                "type": "tool_use",
                "input": [
                    "type": "reminder",
                    "title": "Do laundry",
                    "tags": ["home", "chores"],
                    "scheduled_at": "2026-05-16T18:00:00Z",
                    "deadline_at": "2026-05-17T18:00:00Z",
                    "effort_minutes": 30,
                    "metadata_confidence": 0.82,
                ]
            ]]
        ])
        let classifier = ClaudeClassifier(keychain: keychain.asKeychainStore(), transport: transport)
        let result = try await classifier.classify("remind me to do laundry at 6pm", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.type, .reminder)
        XCTAssertEqual(result.title, "Do laundry")
        XCTAssertEqual(result.tags, ["home", "chores"])
        XCTAssertNotNil(result.scheduledAt)
        XCTAssertNotNil(result.deadlineAt)
        XCTAssertEqual(result.effortMinutes, 30)
        XCTAssertEqual(result.metadataConfidence, 0.82)
    }

    func testThrowsWhenAPIKeyMissing() async {
        let keychain = InMemoryKeychain()
        let transport = MockHTTPTransport()
        let classifier = ClaudeClassifier(keychain: keychain.asKeychainStore(), transport: transport)
        do {
            _ = try await classifier.classify("anything", now: Date())
            XCTFail("expected missingAPIKey")
        } catch let e as ClaudeClassifier.ClassifierError {
            XCTAssertEqual(e, .missingAPIKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUpstreamErrorBubbles() async {
        let keychain = InMemoryKeychain()
        try? keychain.set("k", for: .anthropicAPIKey)
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/messages") { _ in HTTPResponse(status: 500, body: Data("boom".utf8)) }
        let classifier = ClaudeClassifier(keychain: keychain.asKeychainStore(), transport: transport)
        do {
            _ = try await classifier.classify("anything", now: Date())
            XCTFail("expected upstream")
        } catch let e as ClaudeClassifier.ClassifierError {
            guard case .upstream(let status, _) = e else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class OllamaClassifierTests: XCTestCase {
    func testParsesJSONReply() async throws {
        let transport = MockHTTPTransport()
        let inner = """
        {"type":"reminder","title":"Stand up","tags":["meeting"],"scheduled_at":"2026-05-16T09:00:00Z","deadline_at":"2026-05-16T09:30:00Z","effort_minutes":10,"metadata_confidence":0.9}
        """
        transport.stub(path: "/api/chat", json: [
            "message": ["role": "assistant", "content": inner]
        ])
        let classifier = OllamaClassifier(transport: transport)
        let result = try await classifier.classify("stand-up at 9am tomorrow", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.type, .reminder)
        XCTAssertEqual(result.title, "Stand up")
        XCTAssertEqual(result.tags, ["meeting"])
        XCTAssertNotNil(result.deadlineAt)
        XCTAssertEqual(result.effortMinutes, 10)
        XCTAssertEqual(result.metadataConfidence, 0.9)
    }

    func testAvailabilityProbe() async {
        let transport = MockHTTPTransport()
        transport.stub(path: "/api/tags") { _ in HTTPResponse(status: 200) }
        let yes = await OllamaClassifier.isAvailable(transport: transport)
        XCTAssertTrue(yes)
    }
}

final class ClassifierHubTests: XCTestCase {
    func testRoutesToCloudByDefault() async {
        let (claude, ollama) = (ProbeClassifier(id: "claude"), ProbeClassifier(id: "ollama"))
        let hub = makeHub(claude: claude, ollama: ollama)
        _ = await hub.classify("hi")
        XCTAssertEqual(claude.calls, 1)
        XCTAssertEqual(ollama.calls, 0)
    }

    func testSwitchingModeRoutesToOllama() async {
        let (claude, ollama) = (ProbeClassifier(id: "claude"), ProbeClassifier(id: "ollama"))
        let hub = makeHub(claude: claude, ollama: ollama)
        await hub.setMode(.local)
        _ = await hub.classify("hi")
        XCTAssertEqual(ollama.calls, 1)
        let id = await hub.activeIdentifier
        XCTAssertEqual(id, "ollama")
    }

    func testFailureReturnsUnknown() async {
        let claude = FailingClassifier()
        let hub = makeHub(claude: claude, ollama: claude)
        let result = await hub.classify("x")
        XCTAssertEqual(result, .unknown)
    }

    private func makeHub(claude: Classifier, ollama: Classifier) -> ClassifierHub {
        ClassifierHub(
            keychain: KeychainStore(service: "test.\(UUID())"),
            defaults: UserDefaults(suiteName: "hub-\(UUID())")!,
            claude: claude,
            ollama: ollama
        )
    }
}

final class ProbeClassifier: Classifier, @unchecked Sendable {
    let identifier: String
    private(set) var calls: Int = 0
    init(id: String) { self.identifier = id }
    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        calls += 1
        return ClassifierResult(type: .note, title: "probe")
    }
}

struct FailingClassifier: Classifier {
    let identifier = "fail"
    func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        throw NSError(domain: "x", code: 1)
    }
}

/// Test-friendly Keychain replacement. KeychainStore is final, so we wrap.
final class InMemoryKeychain: @unchecked Sendable {
    private var storage: [String: String] = [:]
    func set(_ value: String?, for key: KeychainStore.Key) throws {
        if let value, !value.isEmpty { storage[key.rawValue] = value }
        else { storage.removeValue(forKey: key.rawValue) }
    }
    func string(for key: KeychainStore.Key) -> String? { storage[key.rawValue] }

    /// Wraps in a real KeychainStore that backs onto a one-off service so
    /// reads/writes go to the real OS keychain — used for classifier tests
    /// that need a string round-tripping through `KeychainStore` directly.
    func asKeychainStore() -> KeychainStore {
        let store = KeychainStore(service: "dump.tests.\(UUID().uuidString)")
        for (k, v) in storage {
            if let key = KeychainStore.Key(rawValue: k) {
                try? store.set(v, for: key)
            }
        }
        return store
    }
}

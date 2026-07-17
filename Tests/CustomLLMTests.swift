import XCTest
@testable import Dump

final class CustomLLMClassifierTests: XCTestCase {
    private func makeConfigStore(
        baseURL: String = "https://gateway.example.com/v1",
        classifierModel: String = "gpt-4o-mini",
        synthesizerModel: String = "gpt-4o"
    ) -> CustomLLMConfigStore {
        let defaults = UserDefaults(suiteName: "custom-llm-\(UUID().uuidString)")!
        let store = CustomLLMConfigStore(defaults: defaults)
        store.baseURL = baseURL
        store.classifierModel = classifierModel
        store.synthesizerModel = synthesizerModel
        return store
    }

    func testParsesJSONReply() async throws {
        let transport = MockHTTPTransport()
        let inner = """
        {"type":"reminder","title":"Stand up","tags":["meeting"],"scheduled_at":"2026-05-16T09:00:00Z","deadline_at":"2026-05-16T09:30:00Z","effort_minutes":10,"importance":2,"metadata_confidence":0.9}
        """
        transport.stub(path: "/v1/chat/completions", json: [
            "choices": [["message": ["role": "assistant", "content": inner]]]
        ])
        let keychain = InMemoryKeychain()
        try keychain.set("sk-test", for: .customLLMAPIKey)
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: makeConfigStore(),
            transport: transport
        )
        let result = try await classifier.classify("stand-up at 9am", now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result.type, .reminder)
        XCTAssertEqual(result.title, "Stand up")
        XCTAssertEqual(result.tags, ["meeting"])
        XCTAssertNotNil(result.scheduledAt)
        XCTAssertNotNil(result.deadlineAt)
        XCTAssertEqual(result.effortMinutes, 10)
        XCTAssertEqual(result.importance, 2)
        XCTAssertEqual(result.metadataConfidence, 0.9)
    }

    func testSendsBearerAuthHeader() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/chat/completions", json: [
            "choices": [["message": ["role": "assistant", "content": "{\"type\":\"note\"}"]]]
        ])
        let keychain = InMemoryKeychain()
        try keychain.set("sk-test-key", for: .customLLMAPIKey)
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: makeConfigStore(),
            transport: transport
        )
        _ = try await classifier.classify("hi", now: Date())
        let sent = transport.sentRequests.first
        XCTAssertEqual(sent?.headers["Authorization"], "Bearer sk-test-key")
        XCTAssertEqual(sent?.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent?.url.absoluteString, "https://gateway.example.com/v1/chat/completions")
    }

    func testNormalizesBaseURLWithoutV1() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/chat/completions", json: [
            "choices": [["message": ["role": "assistant", "content": "{\"type\":\"note\"}"]]]
        ])
        let keychain = InMemoryKeychain()
        try keychain.set("k", for: .customLLMAPIKey)
        let store = makeConfigStore(baseURL: "https://gateway.example.com/")
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: transport
        )
        _ = try await classifier.classify("hi", now: Date())
        XCTAssertEqual(transport.sentRequests.first?.url.absoluteString, "https://gateway.example.com/v1/chat/completions")
    }

    func testHonoursFullChatCompletionsPath() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/chat/completions", json: [
            "choices": [["message": ["role": "assistant", "content": "{\"type\":\"note\"}"]]]
        ])
        let keychain = InMemoryKeychain()
        try keychain.set("k", for: .customLLMAPIKey)
        let store = makeConfigStore(baseURL: "https://gateway.example.com/v1/chat/completions")
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: transport
        )
        _ = try await classifier.classify("hi", now: Date())
        XCTAssertEqual(transport.sentRequests.first?.url.absoluteString, "https://gateway.example.com/v1/chat/completions")
    }

    func testThrowsWhenAPIKeyMissing() async {
        let keychain = InMemoryKeychain()
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: makeConfigStore(),
            transport: MockHTTPTransport()
        )
        do {
            _ = try await classifier.classify("hi", now: Date())
            XCTFail("expected missingAPIKey")
        } catch let e as CustomLLMClassifier.CustomLLMError {
            XCTAssertEqual(e, .missingAPIKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testThrowsWhenBaseURLMissing() async {
        let keychain = InMemoryKeychain()
        try? keychain.set("k", for: .customLLMAPIKey)
        let store = makeConfigStore(baseURL: "")
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: MockHTTPTransport()
        )
        do {
            _ = try await classifier.classify("hi", now: Date())
            XCTFail("expected missingBaseURL")
        } catch let e as CustomLLMClassifier.CustomLLMError {
            XCTAssertEqual(e, .missingBaseURL)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testThrowsWhenModelMissing() async {
        let keychain = InMemoryKeychain()
        try? keychain.set("k", for: .customLLMAPIKey)
        let store = makeConfigStore(classifierModel: "")
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: MockHTTPTransport()
        )
        do {
            _ = try await classifier.classify("hi", now: Date())
            XCTFail("expected missingModel")
        } catch let e as CustomLLMClassifier.CustomLLMError {
            XCTAssertEqual(e, .missingModel)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUpstreamErrorBubbles() async {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/chat/completions") { _ in
            HTTPResponse(status: 500, body: Data("oops".utf8))
        }
        let keychain = InMemoryKeychain()
        try? keychain.set("k", for: .customLLMAPIKey)
        let classifier = CustomLLMClassifier(
            keychain: keychain.asKeychainStore(),
            configStore: makeConfigStore(),
            transport: transport
        )
        do {
            _ = try await classifier.classify("hi", now: Date())
            XCTFail("expected upstream")
        } catch let e as CustomLLMClassifier.CustomLLMError {
            guard case .upstream(let status, _) = e else { return XCTFail("wrong case") }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class CustomLLMSynthesizerTests: XCTestCase {
    private func hit(_ docid: String, file: String, title: String? = nil, snippet: String = "") -> QMDHit {
        QMDHit(docid: docid, file: file, title: title, score: 1, context: nil, snippet: snippet)
    }

    func testSynthesisCallSucceedsAndCitesHits() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/chat/completions", json: [
            "choices": [["message": ["role": "assistant", "content": "Per [1], do X."]]]
        ])
        let keychain = InMemoryKeychain()
        try keychain.set("k", for: .customLLMAPIKey)
        let defaults = UserDefaults(suiteName: "synth-\(UUID().uuidString)")!
        let store = CustomLLMConfigStore(defaults: defaults)
        store.baseURL = "https://gateway.example.com"
        store.synthesizerModel = "gpt-4o"
        let synth = CustomLLMSynthesizer(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: transport
        )
        let result = try await synth.synthesize(
            query: "Q",
            hits: [hit("#1", file: "x/p", title: "First", snippet: "...")]
        )
        XCTAssertTrue(result.text.contains("Per [1]"))
        XCTAssertEqual(result.citations.first?.path, "x/p")
        XCTAssertEqual(transport.sentRequests.first?.headers["Authorization"], "Bearer k")
    }
}

final class OllamaSynthesizerTests: XCTestCase {
    private func hit(_ docid: String, file: String, title: String? = nil, snippet: String = "") -> QMDHit {
        QMDHit(docid: docid, file: file, title: title, score: 1, context: nil, snippet: snippet)
    }

    func testSynthesisCallSucceedsAndCitesHits() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/api/chat", json: [
            "message": ["role": "assistant", "content": "Local answer [1]."]
        ])
        let synth = OllamaSynthesizer(
            transport: transport,
            endpoint: URL(string: "http://127.0.0.1:11434/api/chat")!,
            model: "llama3.2:3b"
        )
        let result = try await synth.synthesize(
            query: "Q",
            hits: [hit("#1", file: "x/p", title: "First", snippet: "...")]
        )
        XCTAssertEqual(result.text, "Local answer [1].")
        XCTAssertEqual(result.citations.first?.path, "x/p")
    }
}

final class SynthesizerHubTests: XCTestCase {
    func testCloudModeRoutesToClaude() async throws {
        let claude = StubSynth(answer: "from claude")
        let custom = StubSynth(answer: "from custom")
        let defaults = UserDefaults(suiteName: "hub-synth-\(UUID().uuidString)")!
        defaults.set(ClassifierMode.cloud.rawValue, forKey: ClassifierModePreference.defaultsKey)
        let hub = SynthesizerHub(defaults: defaults, claude: claude, custom: custom)
        let r = try await hub.synthesize(query: "Q", hits: [])
        XCTAssertEqual(r.text, "from claude")
    }

    func testCustomModeRoutesToCustom() async throws {
        let claude = StubSynth(answer: "from claude")
        let custom = StubSynth(answer: "from custom")
        let defaults = UserDefaults(suiteName: "hub-synth-\(UUID().uuidString)")!
        defaults.set(ClassifierMode.custom.rawValue, forKey: ClassifierModePreference.defaultsKey)
        let hub = SynthesizerHub(defaults: defaults, claude: claude, custom: custom)
        let r = try await hub.synthesize(query: "Q", hits: [])
        XCTAssertEqual(r.text, "from custom")
    }

    func testSubscriptionModeRoutesToPlanBacked() async throws {
        let claude = StubSynth(answer: "from claude")
        let planBacked = StubSynth(answer: "from plan")
        let defaults = UserDefaults(suiteName: "hub-synth-\(UUID().uuidString)")!
        defaults.set(ClassifierMode.subscription.rawValue, forKey: ClassifierModePreference.defaultsKey)
        let hub = SynthesizerHub(defaults: defaults, claude: claude, planBacked: planBacked)
        let r = try await hub.synthesize(query: "Q", hits: [])
        XCTAssertEqual(r.text, "from plan")
    }

    func testLocalModeRoutesToOllama() async throws {
        let claude = StubSynth(answer: "from claude")
        let ollama = StubSynth(answer: "from ollama")
        let custom = StubSynth(answer: "from custom")
        let defaults = UserDefaults(suiteName: "hub-synth-\(UUID().uuidString)")!
        defaults.set(ClassifierMode.local.rawValue, forKey: ClassifierModePreference.defaultsKey)
        let hub = SynthesizerHub(defaults: defaults, claude: claude, ollama: ollama, custom: custom)
        let r = try await hub.synthesize(query: "Q", hits: [])
        XCTAssertEqual(r.text, "from ollama")
    }

    func testBedrockModeRoutesToBedrock() async throws {
        let claude = StubSynth(answer: "from claude")
        let bedrock = StubSynth(answer: "from bedrock")
        let defaults = UserDefaults(suiteName: "hub-synth-\(UUID().uuidString)")!
        defaults.set(ClassifierMode.bedrock.rawValue, forKey: ClassifierModePreference.defaultsKey)
        let hub = SynthesizerHub(defaults: defaults, claude: claude, bedrock: bedrock)
        let r = try await hub.synthesize(query: "Q", hits: [])
        XCTAssertEqual(r.text, "from bedrock")
    }
}

final class ClassifierHubCustomRoutingTests: XCTestCase {
    func testCustomModeRoutesToCustom() async {
        let claude = ProbeClassifier(id: "claude")
        let ollama = ProbeClassifier(id: "ollama")
        let custom = ProbeClassifier(id: "custom")
        let bedrock = ProbeClassifier(id: "bedrock")
        let defaults = UserDefaults(suiteName: "hub-\(UUID().uuidString)")!
        let hub = ClassifierHub(
            keychain: KeychainStore(service: "test.\(UUID())"),
            defaults: defaults,
            claude: claude,
            ollama: ollama,
            custom: custom,
            bedrock: bedrock
        )
        await hub.setMode(.custom)
        _ = await hub.classify("hi")
        XCTAssertEqual(custom.calls, 1)
        XCTAssertEqual(claude.calls, 0)
        let id = await hub.activeIdentifier
        XCTAssertEqual(id, "custom")
    }

    func testBedrockModeRoutesToBedrock() async {
        let claude = ProbeClassifier(id: "claude")
        let ollama = ProbeClassifier(id: "ollama")
        let custom = ProbeClassifier(id: "custom")
        let bedrock = ProbeClassifier(id: "bedrock")
        let defaults = UserDefaults(suiteName: "hub-\(UUID().uuidString)")!
        let hub = ClassifierHub(
            keychain: KeychainStore(service: "test.\(UUID())"),
            defaults: defaults,
            claude: claude,
            ollama: ollama,
            custom: custom,
            bedrock: bedrock
        )
        await hub.setMode(.bedrock)
        _ = await hub.classify("hi")
        XCTAssertEqual(bedrock.calls, 1)
        XCTAssertEqual(claude.calls, 0)
        let id = await hub.activeIdentifier
        XCTAssertEqual(id, "bedrock")
    }

    func testSubscriptionModeRoutesToPlanBacked() async {
        let claude = ProbeClassifier(id: "claude")
        let planBacked = ProbeClassifier(id: "plan")
        let ollama = ProbeClassifier(id: "ollama")
        let custom = ProbeClassifier(id: "custom")
        let bedrock = ProbeClassifier(id: "bedrock")
        let defaults = UserDefaults(suiteName: "hub-\(UUID().uuidString)")!
        let hub = ClassifierHub(
            keychain: KeychainStore(service: "test.\(UUID())"),
            defaults: defaults,
            claude: claude,
            planBacked: planBacked,
            ollama: ollama,
            custom: custom,
            bedrock: bedrock
        )
        await hub.setMode(.subscription)
        _ = await hub.classify("hi")
        XCTAssertEqual(planBacked.calls, 1)
        XCTAssertEqual(claude.calls, 0)
        let id = await hub.activeIdentifier
        XCTAssertEqual(id, "plan")
    }
}

final class CustomLLMConfigStoreTests: XCTestCase {
    func testAnthropicMessagesURLDefaultsToAnthropic() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        XCTAssertEqual(store.anthropicMessagesURL()?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testAnthropicMessagesURLAppendsV1Messages() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        store.anthropicEndpoint = "https://proxy.example.com"
        XCTAssertEqual(store.anthropicMessagesURL()?.absoluteString, "https://proxy.example.com/v1/messages")
    }

    func testAnthropicMessagesURLHonoursExistingPath() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        store.anthropicEndpoint = "https://proxy.example.com/v1/messages"
        XCTAssertEqual(store.anthropicMessagesURL()?.absoluteString, "https://proxy.example.com/v1/messages")
    }

    func testAnthropicMessagesURLRejectsInsecureOrMalformedOverrides() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        for endpoint in [
            "http://proxy.example.com",
            "file:///tmp/messages",
            "https:///missing-host",
            "https://user:password@proxy.example.com",
        ] {
            store.anthropicEndpoint = endpoint
            XCTAssertFalse(store.isValidAnthropicEndpoint(endpoint))
            XCTAssertNil(store.anthropicMessagesURL())
        }
    }

    func testChatCompletionsURLRequiresHostedHTTPS() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        XCTAssertEqual(
            store.chatCompletionsURL(for: "https://gateway.example.com/v1")?.absoluteString,
            "https://gateway.example.com/v1/chat/completions"
        )
        XCTAssertNil(store.chatCompletionsURL(for: "http://gateway.example.com/v1"))
        XCTAssertNil(store.chatCompletionsURL(for: "http://localhost:8080/v1"))
        XCTAssertNil(store.chatCompletionsURL(for: "file:///tmp/gateway"))
        XCTAssertNil(store.chatCompletionsURL(for: "gateway.example.com/v1"))
    }

    func testOllamaChatURLDefaultsAndNormalizesBaseURL() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        XCTAssertEqual(store.ollamaChatURL().absoluteString, "http://127.0.0.1:11434/api/chat")
        store.ollamaBaseURL = "http://localhost:11434/"
        XCTAssertEqual(store.ollamaChatURL().absoluteString, "http://localhost:11434/api/chat")
    }

    func testOllamaAllowsLoopbackHTTPAndRejectsRemoteHTTP() {
        let store = CustomLLMConfigStore(defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!)
        store.ollamaBaseURL = "http://127.0.0.2:11434"
        XCTAssertEqual(store.ollamaChatURL().absoluteString, "http://127.0.0.2:11434/api/chat")

        store.ollamaBaseURL = "http://ollama.example.com:11434"
        XCTAssertEqual(store.ollamaChatURL().absoluteString, "http://127.0.0.1:11434/api/chat")

        store.ollamaBaseURL = "https://ollama.example.com"
        XCTAssertEqual(store.ollamaChatURL().absoluteString, "https://ollama.example.com/api/chat")
    }
}

final class ProviderConnectTests: XCTestCase {
    func testEnvironmentValueTrimsAndIgnoresEmptyValues() {
        XCTAssertEqual(
            ProviderConnect.environmentValue(for: .openAI, environment: ["OPENAI_API_KEY": "  sk-test  "]),
            "sk-test"
        )
        XCTAssertNil(ProviderConnect.environmentValue(for: .anthropic, environment: ["ANTHROPIC_API_KEY": "   "]))
        XCTAssertNil(ProviderConnect.environmentValue(for: .openAI, environment: [:]))
    }

    func testProviderURLsAndOpenAIDefaults() {
        XCTAssertEqual(ProviderConnect.anthropicAPIKeysURL.absoluteString, "https://console.anthropic.com/settings/keys")
        XCTAssertEqual(ProviderConnect.openAIAPIKeysURL.absoluteString, "https://platform.openai.com/api-keys")
        XCTAssertEqual(ProviderConnect.openAIBaseURL, "https://api.openai.com/v1")
    }
}

private struct StubSynth: Synthesizing {
    let answer: String
    func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        SynthesisResult(text: answer, citations: [])
    }
}

// MARK: - Streaming synthesis

final class StreamingSynthesisTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return deltas
    }

    private func queryHit() -> QueryEngine.Hit {
        QueryEngine.Hit(docid: "d1", file: "notes/a.md", title: "A", score: 1.0, context: nil, snippet: "alpha")
    }

    func testClaudeStreamParsesSSEDeltas() async throws {
        let keychain = InMemoryKeychain()
        try keychain.set("sk-ant-test", for: .anthropicAPIKey)
        let transport = MockHTTPTransport()
        let sse = """
        event: message_start
        data: {"type":"message_start"}
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world [1]"}}
        data: {"type":"message_stop"}
        """
        transport.setFallback { _ in
            HTTPResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let synth = ClaudeSynthesizer(keychain: keychain.asKeychainStore(), transport: transport)
        let deltas = try await collect(synth.synthesizeStream(query: "q", hits: [queryHit()]))
        XCTAssertEqual(deltas, ["Hello", " world [1]"])
    }

    func testClaudeStreamSurfacesMidStreamErrorEvent() async throws {
        let keychain = InMemoryKeychain()
        try keychain.set("sk-ant-test", for: .anthropicAPIKey)
        let transport = MockHTTPTransport()
        let sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        """
        transport.setFallback { _ in
            HTTPResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let synth = ClaudeSynthesizer(keychain: keychain.asKeychainStore(), transport: transport)
        do {
            _ = try await collect(synth.synthesizeStream(query: "q", hits: []))
            XCTFail("expected upstream error")
        } catch let ClaudeSynthesizer.SynthesisError.upstream(status, message) {
            XCTAssertEqual(status, 200)
            XCTAssertEqual(message, "Overloaded")
        }
    }

    func testClaudeStreamMapsHTTPStatusToUpstream() async throws {
        let keychain = InMemoryKeychain()
        try keychain.set("sk-ant-test", for: .anthropicAPIKey)
        let transport = MockHTTPTransport()
        transport.setFallback { _ in
            HTTPResponse(status: 429, headers: [:], body: Data("rate limited".utf8))
        }
        let synth = ClaudeSynthesizer(keychain: keychain.asKeychainStore(), transport: transport)
        do {
            _ = try await collect(synth.synthesizeStream(query: "q", hits: []))
            XCTFail("expected upstream error")
        } catch let ClaudeSynthesizer.SynthesisError.upstream(status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    func testOllamaStreamParsesNDJSONAndStopsAtDone() async throws {
        let transport = MockHTTPTransport()
        let ndjson = """
        {"message":{"role":"assistant","content":"Local"},"done":false}
        {"message":{"role":"assistant","content":" answer"},"done":false}
        {"message":{"role":"assistant","content":""},"done":true}
        """
        transport.setFallback { _ in
            HTTPResponse(status: 200, headers: [:], body: Data(ndjson.utf8))
        }
        let synth = OllamaSynthesizer(
            transport: transport,
            endpoint: URL(string: "http://localhost:11434/api/chat")!,
            model: "llama3"
        )
        let deltas = try await collect(synth.synthesizeStream(query: "q", hits: []))
        XCTAssertEqual(deltas, ["Local", " answer"])
    }

    func testOllamaStreamSurfacesErrorLine() async throws {
        let transport = MockHTTPTransport()
        let ndjson = """
        {"message":{"role":"assistant","content":"par"},"done":false}
        {"error":"model ran out of memory"}
        """
        transport.setFallback { _ in
            HTTPResponse(status: 200, headers: [:], body: Data(ndjson.utf8))
        }
        let synth = OllamaSynthesizer(
            transport: transport,
            endpoint: URL(string: "http://localhost:11434/api/chat")!,
            model: "llama3"
        )
        do {
            _ = try await collect(synth.synthesizeStream(query: "q", hits: []))
            XCTFail("expected upstream error")
        } catch let OllamaClassifier.OllamaError.upstream(status, message) {
            XCTAssertEqual(status, 200)
            XCTAssertEqual(message, "model ran out of memory")
        }
    }

    func testCustomLLMStreamParsesSSEAndStopsAtDone() async throws {
        let keychain = InMemoryKeychain()
        try keychain.set("sk-test", for: .customLLMAPIKey)
        let defaults = UserDefaults(suiteName: "stream-\(UUID().uuidString)")!
        let store = CustomLLMConfigStore(defaults: defaults)
        store.baseURL = "https://api.example.com/v1"
        store.synthesizerModel = "gpt-test"
        let transport = MockHTTPTransport()
        let sse = """
        data: {"choices":[{"delta":{"content":"Open"}}]}
        data: {"choices":[{"delta":{"content":"AI style"}}]}
        data: [DONE]
        """
        transport.setFallback { _ in
            HTTPResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let synth = CustomLLMSynthesizer(
            keychain: keychain.asKeychainStore(),
            configStore: store,
            transport: transport
        )
        let deltas = try await collect(synth.synthesizeStream(query: "q", hits: []))
        XCTAssertEqual(deltas, ["Open", "AI style"])
    }

    func testDefaultStreamYieldsBufferedTextOnceAndSkipsEmpty() async throws {
        let full = try await collect(StubSynth(answer: "whole answer").synthesizeStream(query: "q", hits: []))
        XCTAssertEqual(full, ["whole answer"])
        let empty = try await collect(StubSynth(answer: "").synthesizeStream(query: "q", hits: []))
        XCTAssertEqual(empty, [])
    }
}

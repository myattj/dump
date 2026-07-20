import Foundation

public struct SynthesisResult: Equatable, Sendable {
    public let text: String
    public let citations: [Citation]
    public let label: String

    public init(text: String, citations: [Citation], label: String = "Synthesised answer") {
        self.text = text
        self.citations = citations
        self.label = label
    }

    public struct Citation: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public let index: Int
        public let path: String
        public let title: String

        public init(index: Int, path: String, title: String) {
            self.index = index
            self.path = path
            self.title = title
        }

        public static func == (lhs: Citation, rhs: Citation) -> Bool {
            lhs.index == rhs.index && lhs.path == rhs.path && lhs.title == rhs.title
        }
    }
}

public protocol Synthesizing: Sendable {
    func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult
    /// Yields partial answer text as tokens arrive; finishes when generation
    /// completes. Citations are extracted by the caller from the full text.
    func synthesizeStream(query: String, hits: [QueryEngine.Hit]) -> AsyncThrowingStream<String, Error>
}

public extension Synthesizing {
    /// One-shot fallback wrapping the buffered call, so backends (and test
    /// fakes) adopt true token streaming incrementally.
    func synthesizeStream(query: String, hits: [QueryEngine.Hit]) -> AsyncThrowingStream<String, Error> {
        let state = OneShotSynthesisStreamState()
        return AsyncThrowingStream(unfolding: {
            try Task.checkCancellation()
            guard state.claim() else { return nil }
            // `unfolding` executes in the consumer's task. Cancellation now
            // propagates structurally into buffered backends (notably the
            // Codex/Claude CLI runner), and joining the query task also joins
            // the provider process instead of merely cancelling a hidden
            // producer task.
            let result = try await synthesize(query: query, hits: hits)
            // An empty element would read as a "first token" upstream and
            // animate in an empty answer card.
            return result.text.isEmpty ? nil : result.text
        })
    }
}

private final class OneShotSynthesisStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// Calls Claude Sonnet with the user's question plus the top hits from
/// qmd. Asks for an answer that cites snippets by their index. Falls back
/// gracefully if the API key isn't present.
public struct ClaudeSynthesizer: Synthesizing {
    private let keychain: KeychainStore
    private let transport: HTTPTransporting
    private let endpointOverride: URL?
    private let configStore: CustomLLMConfigStore
    private let model: String

    public init(
        keychain: KeychainStore = .shared,
        transport: HTTPTransporting = HTTPTransport(),
        endpoint: URL? = nil,
        configStore: CustomLLMConfigStore = .shared,
        model: String = "claude-sonnet-4-6"
    ) {
        self.keychain = keychain
        self.transport = transport
        self.endpointOverride = endpoint
        self.configStore = configStore
        self.model = model
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        guard let key = keychain.string(for: .anthropicAPIKey), !key.isEmpty else {
            throw SynthesisError.missingAPIKey
        }
        guard let endpoint = endpointOverride ?? configStore.anthropicMessagesURL() else {
            throw SynthesisError.invalidEndpoint
        }
        let prompt = Self.buildPrompt(query: query, hits: hits)
        let payload = MessagesRequest(
            model: model,
            maxTokens: 800,
            system: Self.systemPrompt,
            messages: [.init(role: "user", content: prompt)]
        )
        let body = try JSONEncoder.anthropic.encode(payload)
        let req = HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            ],
            body: body,
            timeout: 60
        )
        let resp = try await transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw SynthesisError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder.anthropic.decode(MessagesResponse.self, from: resp.body)
        let text = decoded.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let citations = Self.extractCitations(from: text, hits: hits)
        return SynthesisResult(text: text, citations: citations)
    }

    /// True token streaming over the Messages API's SSE mode
    /// (`content_block_delta` events carry the text).
    public func synthesizeStream(query: String, hits: [QueryEngine.Hit]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = keychain.string(for: .anthropicAPIKey), !key.isEmpty else {
                        throw SynthesisError.missingAPIKey
                    }
                    guard let endpoint = endpointOverride ?? configStore.anthropicMessagesURL() else {
                        throw SynthesisError.invalidEndpoint
                    }
                    let prompt = Self.buildPrompt(query: query, hits: hits)
                    let payload = MessagesRequest(
                        model: model,
                        maxTokens: 800,
                        system: Self.systemPrompt,
                        messages: [.init(role: "user", content: prompt)],
                        stream: true
                    )
                    let body = try JSONEncoder.anthropic.encode(payload)
                    let req = HTTPRequest(
                        method: "POST",
                        url: endpoint,
                        headers: [
                            "x-api-key": key,
                            "anthropic-version": "2023-06-01",
                            "content-type": "application/json",
                            "accept": "text/event-stream",
                        ],
                        body: body,
                        timeout: 60
                    )
                    for try await line in transport.streamLines(req) {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder.anthropic.decode(StreamEvent.self, from: data) else { continue }
                        // Anthropic can deliver failures as SSE error events
                        // on a 200 response — surface, don't truncate silently.
                        if event.type == "error" {
                            throw SynthesisError.upstream(200, event.error?.message ?? "stream error")
                        }
                        if event.type == "content_block_delta", let text = event.delta?.text, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch let HTTPError.status(code, message) {
                    continuation.finish(throwing: SynthesisError.upstream(code, message))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let systemPrompt = """
    You answer questions using ONLY the provided snippets. Cite sources
    inline as bracketed numbers like [1]. If the snippets don't answer the
    question, say so plainly. Keep answers tight — one paragraph unless the
    user asked for detail.
    """

    static func buildPrompt(query: String, hits: [QueryEngine.Hit]) -> String {
        var s = "Question: \(query)\n\nSnippets:\n"
        for (i, hit) in hits.enumerated() {
            s += "[\(i + 1)] \(hit.title ?? hit.file)\n\(hit.snippet)\n\n"
        }
        return s
    }

    static func extractCitations(from text: String, hits: [QueryEngine.Hit]) -> [SynthesisResult.Citation] {
        var indices = Set<Int>()
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        while !scanner.isAtEnd {
            if scanner.scanString("[") != nil,
               let n = scanner.scanInt(),
               scanner.scanString("]") != nil {
                indices.insert(n)
            } else {
                _ = scanner.scanCharacter()
            }
        }
        return indices.sorted().compactMap { idx in
            guard idx > 0, idx <= hits.count else { return nil }
            let hit = hits[idx - 1]
            return SynthesisResult.Citation(index: idx, path: hit.file, title: hit.title ?? hit.file)
        }
    }

    public enum SynthesisError: Error, Equatable {
        case missingAPIKey
        case invalidEndpoint
        case upstream(Int, String)
    }

    struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Msg]
        var stream: Bool? = nil
        enum CodingKeys: String, CodingKey { case model, system, messages, stream; case maxTokens = "max_tokens" }
        struct Msg: Encodable { let role: String; let content: String }
    }

    struct MessagesResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    struct StreamEvent: Decodable {
        let type: String
        let delta: Delta?
        let error: ErrorPayload?
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct ErrorPayload: Decodable {
            let type: String?
            let message: String?
        }
    }
}

extension ClaudeSynthesizer.SynthesisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Anthropic API key — add one in Settings → Classifier."
        case .invalidEndpoint:
            "The saved Anthropic endpoint is not a valid HTTPS URL. Update it in Settings → Classifier."
        case let .upstream(status, _):
            "Claude returned an error (HTTP \(status)). Try again in a moment."
        }
    }
}

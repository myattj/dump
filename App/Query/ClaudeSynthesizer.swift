import Foundation

public struct SynthesisResult: Equatable, Sendable {
    public let text: String
    public let citations: [Citation]

    public init(text: String, citations: [Citation]) {
        self.text = text
        self.citations = citations
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
            url: endpointOverride ?? configStore.anthropicMessagesURL(),
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
        case upstream(Int, String)
    }

    struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Msg]
        enum CodingKeys: String, CodingKey { case model, system, messages; case maxTokens = "max_tokens" }
        struct Msg: Encodable { let role: String; let content: String }
    }

    struct MessagesResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}

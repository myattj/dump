import Foundation

/// Same OpenAI-compatible Chat Completions endpoint as `CustomLLMClassifier`,
/// but asks for free-form text and reuses `ClaudeSynthesizer.buildPrompt`
/// and `extractCitations` so cite-by-index behaves identically.
public struct CustomLLMSynthesizer: Synthesizing {
    private let keychain: KeychainStore
    private let configStore: CustomLLMConfigStore
    private let transport: HTTPTransporting

    public init(
        keychain: KeychainStore = .shared,
        configStore: CustomLLMConfigStore = .shared,
        transport: HTTPTransporting = HTTPTransport()
    ) {
        self.keychain = keychain
        self.configStore = configStore
        self.transport = transport
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        guard let key = keychain.string(for: .customLLMAPIKey), !key.isEmpty else {
            throw CustomLLMClassifier.CustomLLMError.missingAPIKey
        }
        guard let url = configStore.chatCompletionsURL() else {
            throw CustomLLMClassifier.CustomLLMError.missingBaseURL
        }
        let model = configStore.synthesizerModel
        guard !model.isEmpty else { throw CustomLLMClassifier.CustomLLMError.missingModel }

        let prompt = ClaudeSynthesizer.buildPrompt(query: query, hits: hits)
        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: ClaudeSynthesizer.systemPrompt),
                .init(role: "user", content: prompt),
            ],
            temperature: 0.2,
            maxTokens: 800
        )
        let body = try JSONEncoder().encode(payload)
        let req = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json",
            ],
            body: body,
            timeout: 60
        )
        let resp = try await transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw CustomLLMClassifier.CustomLLMError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: resp.body)
        let text = (envelope.choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let citations = ClaudeSynthesizer.extractCitations(from: text, hits: hits)
        return SynthesisResult(text: text, citations: citations)
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let temperature: Double
        let maxTokens: Int
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
        struct Msg: Encodable { let role: String; let content: String }
    }

    struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let role: String?; let content: String }
    }
}

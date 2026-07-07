import Foundation

/// Answer synthesis through Amazon Bedrock Runtime's Converse API.
public struct BedrockSynthesizer: Synthesizing {
    private let keychain: KeychainStore
    private let configStore: CustomLLMConfigStore
    private let transport: HTTPTransporting
    private let clock: @Sendable () -> Date

    public init(
        keychain: KeychainStore = .shared,
        configStore: CustomLLMConfigStore = .shared,
        transport: HTTPTransporting = HTTPTransport(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.configStore = configStore
        self.transport = transport
        self.clock = clock
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        let region = configStore.bedrockRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else { throw BedrockError.missingRegion }
        let modelID = configStore.bedrockSynthesizerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw BedrockError.missingModel }

        let client = BedrockRuntimeClient(
            region: region,
            credentials: try BedrockClassifier.credentials(from: keychain),
            transport: transport,
            clock: clock
        )
        let prompt = ClaudeSynthesizer.buildPrompt(query: query, hits: hits)
        let text = try await client.converse(
            modelID: modelID,
            systemPrompt: ClaudeSynthesizer.systemPrompt,
            userText: prompt,
            maxTokens: 800,
            temperature: 0.2
        )
        return SynthesisResult(
            text: text,
            citations: ClaudeSynthesizer.extractCitations(from: text, hits: hits)
        )
    }
}

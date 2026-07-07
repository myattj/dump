import Foundation

/// Routes synthesis to the backend matching the classifier-mode toggle.
public actor SynthesizerHub: Synthesizing {
    private let claude: Synthesizing
    private let ollama: Synthesizing
    private let custom: Synthesizing
    private let bedrock: Synthesizing
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(
        keychain: KeychainStore = .shared,
        configStore: CustomLLMConfigStore = .shared,
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard,
        claude: Synthesizing? = nil,
        ollama: Synthesizing? = nil,
        custom: Synthesizing? = nil,
        bedrock: Synthesizing? = nil
    ) {
        let transport = HTTPTransport(session: urlSession)
        self.defaults = defaults
        self.claude = claude ?? ClaudeSynthesizer(keychain: keychain, transport: transport, configStore: configStore)
        self.ollama = ollama ?? OllamaSynthesizer(transport: transport, endpoint: configStore.ollamaChatURL(), model: configStore.ollamaModel)
        self.custom = custom ?? CustomLLMSynthesizer(keychain: keychain, configStore: configStore, transport: transport)
        self.bedrock = bedrock ?? BedrockSynthesizer(keychain: keychain, configStore: configStore, transport: transport)
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        let mode = ClassifierModePreference.read(from: defaults)
        let backend: Synthesizing
        switch mode {
        case .cloud:
            backend = claude
        case .local:
            backend = ollama
        case .custom:
            backend = custom
        case .bedrock:
            backend = bedrock
        }
        return try await backend.synthesize(query: query, hits: hits)
    }
}

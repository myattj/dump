import Foundation

/// Routes synthesis to the backend matching the classifier-mode toggle.
public actor SynthesizerHub: Synthesizing {
    private let claude: Synthesizing
    private let planBacked: Synthesizing
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
        planBacked: Synthesizing? = nil,
        ollama: Synthesizing? = nil,
        custom: Synthesizing? = nil,
        bedrock: Synthesizing? = nil
    ) {
        let transport = HTTPTransport(session: urlSession)
        self.defaults = defaults
        self.claude = claude ?? ClaudeSynthesizer(keychain: keychain, transport: transport, configStore: configStore)
        self.planBacked = planBacked ?? PlanBackedSynthesizer(configStore: configStore)
        self.ollama = ollama ?? OllamaSynthesizer(transport: transport, endpoint: configStore.ollamaChatURL(), model: configStore.ollamaModel)
        self.custom = custom ?? CustomLLMSynthesizer(keychain: keychain, configStore: configStore, transport: transport)
        self.bedrock = bedrock ?? BedrockSynthesizer(keychain: keychain, configStore: configStore, transport: transport)
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        try await currentBackend.synthesize(query: query, hits: hits)
    }

    /// Forwarded explicitly — without this, calls through the `Synthesizing`
    /// existential would hit the protocol's buffered one-shot default and
    /// silently swallow the backend's true token streaming.
    public nonisolated func synthesizeStream(query: String, hits: [QueryEngine.Hit]) -> AsyncThrowingStream<String, Error> {
        currentBackend.synthesizeStream(query: query, hits: hits)
    }

    /// nonisolated so the non-async stream requirement can route without an
    /// actor hop — all state it reads is immutable (`let` backends) or the
    /// already-nonisolated defaults.
    private nonisolated var currentBackend: Synthesizing {
        switch ClassifierModePreference.read(from: defaults) {
        case .cloud: claude
        case .subscription: planBacked
        case .local: ollama
        case .custom: custom
        case .bedrock: bedrock
        }
    }
}

import Foundation

/// `UserDefaults` is thread-safe, but the macOS 15 SDK does not declare it
/// `Sendable`. Keep it inside one audited wrapper so the synchronous streaming
/// requirement can read the current provider without crossing the actor.
private final class SynthesizerModeReader: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func read() -> ClassifierMode {
        ClassifierModePreference.read(from: defaults)
    }
}

/// Routes synthesis to the backend matching the classifier-mode toggle.
public actor SynthesizerHub: Synthesizing {
    private let claude: Synthesizing
    private let planBacked: Synthesizing
    private let ollama: Synthesizing
    private let custom: Synthesizing
    private let bedrock: Synthesizing
    private let modeReader: SynthesizerModeReader

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
        self.modeReader = SynthesizerModeReader(defaults: defaults)
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
    /// actor hop — all state it reads is immutable and Sendable.
    private nonisolated var currentBackend: Synthesizing {
        switch modeReader.read() {
        case .cloud: claude
        case .subscription: planBacked
        case .local: ollama
        case .custom: custom
        case .bedrock: bedrock
        }
    }
}

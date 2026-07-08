import Foundation

/// User-supplied connection details for an OpenAI-compatible HTTPS endpoint
/// (Azure OpenAI, vLLM/LiteLLM/OpenRouter gateways, enterprise proxies, etc.).
/// Base URL + model names live in UserDefaults; the API key lives in Keychain
/// under `KeychainStore.Key.customLLMAPIKey`.
public final class CustomLLMConfigStore: @unchecked Sendable {
    public static let shared = CustomLLMConfigStore()

    public enum DefaultsKey {
        public static let baseURL = "dump.classifier.custom.baseURL"
        public static let classifierModel = "dump.classifier.custom.classifierModel"
        public static let synthesizerModel = "dump.classifier.custom.synthesizerModel"
        public static let anthropicEndpoint = "dump.classifier.anthropic.endpoint"
        public static let ollamaBaseURL = "dump.classifier.ollama.baseURL"
        public static let ollamaModel = "dump.classifier.ollama.model"
        public static let bedrockRegion = "dump.classifier.bedrock.region"
        public static let bedrockClassifierModelID = "dump.classifier.bedrock.classifierModelID"
        public static let bedrockSynthesizerModelID = "dump.classifier.bedrock.synthesizerModelID"
        public static let planBackedProvider = "dump.classifier.plan.provider"
        public static let claudeCodeExecutablePath = "dump.classifier.plan.claudeCodeExecutablePath"
        public static let codexExecutablePath = "dump.classifier.plan.codexExecutablePath"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var baseURL: String {
        get { defaults.string(forKey: DefaultsKey.baseURL) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.baseURL) }
    }

    public var classifierModel: String {
        get { defaults.string(forKey: DefaultsKey.classifierModel) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.classifierModel) }
    }

    public var synthesizerModel: String {
        get { defaults.string(forKey: DefaultsKey.synthesizerModel) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.synthesizerModel) }
    }

    /// Optional override for the Anthropic Messages endpoint. Lets users route
    /// `ClaudeClassifier` + `ClaudeSynthesizer` through a corporate HTTPS proxy
    /// that speaks the Anthropic protocol. Empty string = use the default.
    public var anthropicEndpoint: String {
        get { defaults.string(forKey: DefaultsKey.anthropicEndpoint) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.anthropicEndpoint) }
    }

    /// Base URL for a local Ollama server. Stored as a base instead of the
    /// final `/api/chat` endpoint so settings can present the familiar host.
    public var ollamaBaseURL: String {
        get { defaults.string(forKey: DefaultsKey.ollamaBaseURL) ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: DefaultsKey.ollamaBaseURL) }
    }

    public var ollamaModel: String {
        get { defaults.string(forKey: DefaultsKey.ollamaModel) ?? "llama3.2:3b" }
        set { defaults.set(newValue, forKey: DefaultsKey.ollamaModel) }
    }

    /// AWS Region for Bedrock Runtime, e.g. `us-east-1`.
    public var bedrockRegion: String {
        get { defaults.string(forKey: DefaultsKey.bedrockRegion) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.bedrockRegion) }
    }

    /// Model ID, inference profile ID, or ARN used for fast structured
    /// classification through Bedrock Converse.
    public var bedrockClassifierModelID: String {
        get { defaults.string(forKey: DefaultsKey.bedrockClassifierModelID) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.bedrockClassifierModelID) }
    }

    /// Model ID, inference profile ID, or ARN used for answer synthesis
    /// through Bedrock Converse.
    public var bedrockSynthesizerModelID: String {
        get { defaults.string(forKey: DefaultsKey.bedrockSynthesizerModelID) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.bedrockSynthesizerModelID) }
    }

    /// Which local official CLI powers plan-backed usage. The selected CLI
    /// owns authentication with the user's paid ChatGPT or Claude plan.
    public var planBackedProvider: PlanBackedProvider {
        get {
            let raw = defaults.string(forKey: DefaultsKey.planBackedProvider) ?? PlanBackedProvider.claudeCode.rawValue
            return PlanBackedProvider(rawValue: raw) ?? .claudeCode
        }
        set { defaults.set(newValue.rawValue, forKey: DefaultsKey.planBackedProvider) }
    }

    public var claudeCodeExecutablePath: String {
        get { defaults.string(forKey: DefaultsKey.claudeCodeExecutablePath) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.claudeCodeExecutablePath) }
    }

    public var codexExecutablePath: String {
        get { defaults.string(forKey: DefaultsKey.codexExecutablePath) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.codexExecutablePath) }
    }

    /// Resolves the Anthropic Messages URL the Claude clients should hit:
    /// either the user-supplied override (any of "https://host",
    /// "https://host/v1", "https://host/v1/messages") or api.anthropic.com.
    public func anthropicMessagesURL() -> URL {
        let trimmed = anthropicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fallback = URL(string: "https://api.anthropic.com/v1/messages")!
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return fallback }
        let path = url.path
        if path.hasSuffix("/messages") { return url }
        if path.contains("/v") { return url.appendingPathComponent("messages") }
        return url.appendingPathComponent("v1/messages")
    }

    /// Builds the `/chat/completions` URL from the user-supplied base. Accepts
    /// "https://host", "https://host/v1", or "https://host/v1/chat/completions"
    /// and normalizes to the right shape.
    public func chatCompletionsURL() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        let path = url.path
        if path.hasSuffix("/chat/completions") { return url }
        if path.contains("/v") { return url.appendingPathComponent("chat/completions") }
        return url.appendingPathComponent("v1/chat/completions")
    }

    public func ollamaChatURL() -> URL {
        let trimmed = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fallback = URL(string: "http://127.0.0.1:11434/api/chat")!
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return fallback }
        if url.path.hasSuffix("/api/chat") { return url }
        return url.appendingPathComponent("api/chat")
    }
}

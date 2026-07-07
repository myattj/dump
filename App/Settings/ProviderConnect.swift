import Foundation

public enum ProviderConnect {
    public static let anthropicAPIKeysURL = URL(string: "https://console.anthropic.com/settings/keys")!
    public static let openAIAPIKeysURL = URL(string: "https://platform.openai.com/api-keys")!

    public static let openAIBaseURL = "https://api.openai.com/v1"
    public static let openAIClassifierModel = "gpt-4o-mini"
    public static let openAISynthesizerModel = "gpt-4o"

    public enum EnvironmentKey: String, Sendable {
        case anthropic = "ANTHROPIC_API_KEY"
        case openAI = "OPENAI_API_KEY"
    }

    public static func environmentValue(
        for key: EnvironmentKey,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let value = environment[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

import Foundation

public enum ProviderConnect {
    public static let anthropicAPIKeysURL = URL(string: "https://console.anthropic.com/settings/keys")!
    public static let openAIAPIKeysURL = URL(string: "https://platform.openai.com/api-keys")!
    public static let bedrockModelAccessURL = URL(string: "https://console.aws.amazon.com/bedrock/home#/modelaccess")!

    public static let openAIBaseURL = "https://api.openai.com/v1"
    public static let openAIClassifierModel = "gpt-4o-mini"
    public static let openAISynthesizerModel = "gpt-4o"
    public static let bedrockRegion = "us-east-1"
    public static let bedrockClassifierModelID = "anthropic.claude-3-haiku-20240307-v1:0"
    public static let bedrockSynthesizerModelID = "anthropic.claude-3-5-sonnet-20240620-v1:0"

    public enum EnvironmentKey: String, Sendable {
        case anthropic = "ANTHROPIC_API_KEY"
        case openAI = "OPENAI_API_KEY"
        case awsAccessKeyID = "AWS_ACCESS_KEY_ID"
        case awsSecretAccessKey = "AWS_SECRET_ACCESS_KEY"
        case awsSessionToken = "AWS_SESSION_TOKEN"
        case awsRegion = "AWS_REGION"
        case awsDefaultRegion = "AWS_DEFAULT_REGION"
    }

    public static func environmentValue(
        for key: EnvironmentKey,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let value = environment[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

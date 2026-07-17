import Foundation

/// Hits an OpenAI-compatible Chat Completions endpoint
/// (`POST {base}/v1/chat/completions`) and parses the assistant message as
/// JSON conforming to the classifier schema. Designed for enterprise gateways
/// (Azure OpenAI, vLLM, LiteLLM, OpenRouter, etc.) where the user pastes their
/// own HTTPS URL, model name, and API key.
public struct CustomLLMClassifier: Classifier {
    public var identifier: String { "custom:\(configStore.classifierModel)" }

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

    public func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        guard let key = keychain.string(for: .customLLMAPIKey), !key.isEmpty else {
            throw CustomLLMError.missingAPIKey
        }
        guard let url = configStore.chatCompletionsURL() else {
            throw CustomLLMError.missingBaseURL
        }
        let model = configStore.classifierModel
        guard !model.isEmpty else { throw CustomLLMError.missingModel }

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt(now: now)),
                .init(role: "user", content: text),
            ],
            temperature: 0,
            responseFormat: .init(type: "json_object")
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
            throw CustomLLMError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: resp.body)
        guard let content = envelope.choices.first?.message.content,
              let json = content.data(using: .utf8) else {
            throw CustomLLMError.malformed
        }
        let parsed = try JSONDecoder().decode(JSONResult.self, from: json)
        return ClassifierResult(
            type: Frontmatter.EntryType(rawValue: parsed.type) ?? .unknown,
            title: parsed.title,
            tags: parsed.tags ?? [],
            scheduledAt: parsed.scheduled_at.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            deadlineAt: parsed.deadline_at.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            effortMinutes: parsed.effort_minutes,
            importance: ClassifierResult.normalizedImportance(parsed.importance),
            metadataConfidence: parsed.metadata_confidence
        )
    }

    static func systemPrompt(now: Date) -> String {
        let iso = ISO8601DateFormatter.anthropic.string(from: now)
        return """
        Classify the user's note. Reply ONLY with JSON of the form:
        {"type":"task|reminder|note|idea|reference|unknown","title":"...","tags":["..."],"scheduled_at":"ISO-8601 or null","deadline_at":"ISO-8601 or null","effort_minutes":30,"importance":3,"metadata_confidence":0.8}
        Use "reminder" only for explicit remind/notify/alert requests.
        Use "task" for actionable work, including work with due dates.
        scheduled_at is only a notification fire time. deadline_at is for due
        dates/target dates used in the task queue. Estimate effort_minutes when
        inferable from the text. importance is 1 (low) to 4 (critical); set it
        only when the text signals priority, else null. Current time: \(iso).
        Title ≤ 60 chars. Up to 5 lowercase tags.
        """
    }

    public enum CustomLLMError: Error, Equatable {
        case missingAPIKey
        case missingBaseURL
        case missingModel
        case upstream(Int, String)
        case malformed
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let temperature: Double
        let responseFormat: ResponseFormat
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case responseFormat = "response_format"
        }
        struct Msg: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
    }

    struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let role: String?; let content: String }
    }

    struct JSONResult: Decodable {
        let type: String
        let title: String?
        let tags: [String]?
        let scheduled_at: String?
        let deadline_at: String?
        let effort_minutes: Int?
        let importance: Int?
        let metadata_confidence: Double?
    }
}

extension CustomLLMClassifier.CustomLLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key for the custom endpoint — add one in Settings → Classifier."
        case .missingBaseURL:
            "The custom endpoint needs a valid HTTPS base URL in Settings → Classifier."
        case .missingModel:
            "No model name for the custom endpoint — set one in Settings → Classifier."
        case let .upstream(status, _):
            "The custom endpoint returned an error (HTTP \(status))."
        case .malformed:
            "The custom endpoint returned an unreadable response."
        }
    }
}

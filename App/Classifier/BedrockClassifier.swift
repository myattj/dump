import Foundation

/// Classifies captures through Amazon Bedrock Runtime's Converse API.
/// Works with any Bedrock model/profile that supports text messages and can
/// reliably emit a small JSON object.
public struct BedrockClassifier: Classifier {
    public var identifier: String { "bedrock:\(configStore.bedrockClassifierModelID)" }

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

    public func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        let region = configStore.bedrockRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else { throw BedrockError.missingRegion }
        let modelID = configStore.bedrockClassifierModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw BedrockError.missingModel }
        let client = BedrockRuntimeClient(
            region: region,
            credentials: try Self.credentials(from: keychain),
            transport: transport,
            clock: clock
        )
        let reply = try await client.converse(
            modelID: modelID,
            systemPrompt: Self.systemPrompt(now: now),
            userText: text,
            maxTokens: 256,
            temperature: 0
        )
        guard let json = Self.jsonObjectData(from: reply) else { throw BedrockError.malformedResponse }
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
        Classify the user's note. Reply only with compact JSON of the form:
        {"type":"task|reminder|note|idea|reference|unknown","title":"...","tags":["..."],"scheduled_at":"ISO-8601 or null","deadline_at":"ISO-8601 or null","effort_minutes":30,"importance":3,"metadata_confidence":0.8}
        Use "reminder" only for explicit remind/notify/alert requests.
        Use "task" for actionable work, including work with due dates.
        scheduled_at is only a notification fire time. deadline_at is for due
        dates/target dates used in the task queue. Estimate effort_minutes when
        inferable from the text. importance is 1 (low) to 4 (critical); set it
        only when the text signals priority, else null. Current time: \(iso).
        Title <= 60 chars. Up to 5 lowercase tags.
        """
    }

    static func credentials(from keychain: KeychainStore) throws -> BedrockCredentials {
        guard let accessKeyID = keychain.string(for: .bedrockAccessKeyID), !accessKeyID.isEmpty,
              let secretAccessKey = keychain.string(for: .bedrockSecretAccessKey), !secretAccessKey.isEmpty else {
            throw BedrockError.missingCredentials
        }
        return BedrockCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: keychain.string(for: .bedrockSessionToken)
        )
    }

    static func jsonObjectData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else {
            return nil
        }
        return data
    }

    private struct JSONResult: Decodable {
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

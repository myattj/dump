import Foundation

/// Classifies captures through an official local CLI that is already signed
/// in with the user's paid ChatGPT or Claude plan. Dump never stores provider
/// tokens for this path.
public struct PlanBackedClassifier: Classifier {
    public var identifier: String { "plan:\(configStore.planBackedProvider.rawValue)" }

    private let configStore: CustomLLMConfigStore
    private let client: PlanBackedCLIClient

    public init(
        configStore: CustomLLMConfigStore = .shared,
        client: PlanBackedCLIClient? = nil,
        runner: LocalPlanCommandRunning = SystemLocalPlanCommandRunner()
    ) {
        self.configStore = configStore
        self.client = client ?? PlanBackedCLIClient(configStore: configStore, runner: runner)
    }

    public func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        let output = try await client.complete(prompt: Self.prompt(text: text, now: now), timeout: 90)
        let data = try PlanBackedJSON.extractJSONObjectData(from: output)
        let parsed = try JSONDecoder().decode(JSONResult.self, from: data)
        return ClassifierResult(
            type: Frontmatter.EntryType(rawValue: parsed.type) ?? .unknown,
            title: parsed.title,
            tags: parsed.tags ?? [],
            scheduledAt: parsed.scheduledAt.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            deadlineAt: parsed.deadlineAt.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            effortMinutes: parsed.effortMinutes,
            importance: ClassifierResult.normalizedImportance(parsed.importance),
            metadataConfidence: parsed.metadataConfidence
        )
    }

    static func prompt(text: String, now: Date) -> String {
        let iso = ISO8601DateFormatter.anthropic.string(from: now)
        return """
        Classify this Dump capture. Use only the provided capture text.

        Return exactly one JSON object and no markdown:
        {"type":"task|reminder|note|idea|reference|unknown","title":"...","tags":["..."],"scheduled_at":"ISO-8601 or null","deadline_at":"ISO-8601 or null","effort_minutes":30,"importance":3,"metadata_confidence":0.8}

        Rules:
        - reminder: explicit remind/notify/alert requests.
        - task: actionable work, including work with due dates.
        - idea: speculative thought.
        - reference: durable information to recall later.
        - note: catch-all observation.
        - scheduled_at is only a notification fire time.
        - deadline_at is for due dates or target dates used in a task queue.
        - effort_minutes is an estimate only when inferable.
        - importance is 1 low to 4 critical; set null when priority is neutral.
        - metadata_confidence is 0.0 to 1.0.
        - title is at most 60 characters.
        - tags are lowercase, up to 5.

        Current time: \(iso)

        Capture:
        \(text)
        """
    }

    struct JSONResult: Decodable {
        let type: String
        let title: String?
        let tags: [String]?
        let scheduledAt: String?
        let deadlineAt: String?
        let effortMinutes: Int?
        let importance: Int?
        let metadataConfidence: Double?

        enum CodingKeys: String, CodingKey {
            case type, title, tags, importance
            case scheduledAt = "scheduled_at"
            case deadlineAt = "deadline_at"
            case effortMinutes = "effort_minutes"
            case metadataConfidence = "metadata_confidence"
        }
    }
}

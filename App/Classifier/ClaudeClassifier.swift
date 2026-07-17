import Foundation

/// Anthropic Messages API call that asks Haiku to assign one of our entry
/// types, optionally extract a scheduled-at, and produce a tight title +
/// tags. Uses the tool-use protocol to force structured output.
public struct ClaudeClassifier: Classifier {
    public let identifier = "claude-haiku-4-5"

    private let keychain: KeychainStore
    private let transport: HTTPTransporting
    private let endpointOverride: URL?
    private let configStore: CustomLLMConfigStore
    private let model: String

    public init(
        keychain: KeychainStore = .shared,
        transport: HTTPTransporting = HTTPTransport(),
        endpoint: URL? = nil,
        configStore: CustomLLMConfigStore = .shared,
        model: String = "claude-haiku-4-5"
    ) {
        self.keychain = keychain
        self.transport = transport
        self.endpointOverride = endpoint
        self.configStore = configStore
        self.model = model
    }

    public func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        guard let key = keychain.string(for: .anthropicAPIKey), !key.isEmpty else {
            throw ClassifierError.missingAPIKey
        }
        guard let endpoint = endpointOverride ?? configStore.anthropicMessagesURL() else {
            throw ClassifierError.invalidEndpoint
        }
        let payload = MessagesRequest(
            model: model,
            maxTokens: 256,
            system: Self.systemPrompt(now: now),
            messages: [.init(role: "user", content: text)],
            tools: [.classifyTool],
            toolChoice: .init(type: "tool", name: Self.toolName)
        )
        let body = try JSONEncoder.anthropic.encode(payload)
        let req = HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            ],
            body: body,
            timeout: 30
        )
        let resp = try await transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw ClassifierError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder.anthropic.decode(MessagesResponse.self, from: resp.body)
        guard let tool = decoded.content.first(where: { $0.type == "tool_use" }),
              let input = tool.input else {
            throw ClassifierError.malformed
        }
        return ClassifierResult(
            type: Frontmatter.EntryType(rawValue: input.type) ?? .unknown,
            title: input.title,
            tags: input.tags ?? [],
            scheduledAt: input.scheduledAt.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            deadlineAt: input.deadlineAt.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            effortMinutes: input.effortMinutes,
            importance: ClassifierResult.normalizedImportance(input.importance),
            metadataConfidence: input.metadataConfidence
        )
    }

    private static let toolName = "classify_entry"

    static func systemPrompt(now: Date) -> String {
        let iso = ISO8601DateFormatter.anthropic.string(from: now)
        return """
        You classify short personal notes into one of these types:
        task | reminder | note | idea | reference | unknown.

        - reminder: asks to be reminded/notified/alerted at a time
        - task: actionable work, including work with a due date/deadline
        - idea: speculative thought
        - reference: durable information to recall later
        - note: catch-all observation

        Current time: \(iso). Set scheduled_at only for explicit reminder or
        notification fire times. Set deadline_at for due dates, target dates,
        or natural task timing used for queue ordering. Estimate effort_minutes
        from phrases like "quick", "deep work", "15m", "two hours"; omit it if
        unclear. Set importance from 1 (low) to 4 (critical) only when the text
        signals priority — urgency words, stakes, or explicit emphasis; omit it
        when neutral. Give metadata_confidence from 0.0 to 1.0, a tight ≤60-char
        title, and up to 5 lowercase tags. Call the classify_entry tool exactly
        once.
        """
    }

    public enum ClassifierError: Error, Equatable {
        case missingAPIKey
        case invalidEndpoint
        case upstream(Int, String)
        case malformed
    }

    // MARK: - Wire types
    struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let tools: [Tool]
        let toolChoice: ToolChoice

        enum CodingKeys: String, CodingKey {
            case model, system, messages, tools
            case maxTokens = "max_tokens"
            case toolChoice = "tool_choice"
        }

        struct Message: Encodable { let role: String; let content: String }
        struct Tool: Encodable {
            let name: String
            let description: String
            let inputSchema: ToolSchema
            enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }

            static let classifyTool = Tool(
                name: ClaudeClassifier.toolName,
                description: "Classify the user's note and return structured fields.",
                inputSchema: ToolSchema(
                    type: "object",
                    properties: [
                        "type": .init(type: "string", enum: ["task", "reminder", "note", "idea", "reference", "unknown"]),
                        "title": .init(type: "string"),
                        "tags": .init(type: "array", items: .init(type: "string")),
                        "scheduled_at": .init(type: "string", description: "ISO-8601 reminder notification time if explicit, else omit."),
                        "deadline_at": .init(type: "string", description: "ISO-8601 task deadline/target time if present, else omit."),
                        "effort_minutes": .init(type: "integer", description: "Estimated effort in minutes if inferable."),
                        "importance": .init(type: "integer", description: "1 low … 4 critical; omit when the text signals no priority."),
                        "metadata_confidence": .init(type: "number", description: "Confidence from 0.0 to 1.0."),
                    ],
                    required: ["type"]
                )
            )
        }
        struct ToolSchema: Encodable {
            let type: String
            let properties: [String: Property]
            let required: [String]
            struct Property: Encodable {
                let type: String
                var description: String? = nil
                var `enum`: [String]? = nil
                var items: Box? = nil
                init(type: String, description: String? = nil, enum: [String]? = nil, items: Property? = nil) {
                    self.type = type
                    self.description = description
                    self.enum = `enum`
                    self.items = items.map(Box.init)
                }
                struct Box: Encodable {
                    let type: String
                    init(_ p: Property) { self.type = p.type }
                }
            }
        }
        struct ToolChoice: Encodable { let type: String; let name: String }
    }

    struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        struct ContentBlock: Decodable {
            let type: String
            let input: ToolInput?
        }
        struct ToolInput: Decodable {
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
}

extension JSONEncoder {
    static let anthropic: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let anthropic: JSONDecoder = {
        JSONDecoder()
    }()
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let anthropic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

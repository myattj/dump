import Foundation

/// Hits a locally-running Ollama instance at 127.0.0.1:11434. Asks the
/// model to emit JSON conforming to the classifier schema and parses what
/// comes back. The JSON-mode prompt is deliberately strict.
public struct OllamaClassifier: Classifier {
    public let identifier: String
    private let transport: HTTPTransporting
    private let endpoint: URL
    private let model: String

    public init(
        transport: HTTPTransporting = HTTPTransport(),
        endpoint: URL = CustomLLMConfigStore.shared.ollamaChatURL(),
        model: String = CustomLLMConfigStore.shared.ollamaModel
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.model = model
        self.identifier = "ollama:\(model)"
    }

    public func classify(_ text: String, now: Date) async throws -> ClassifierResult {
        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt(now: now)),
                .init(role: "user", content: text),
            ],
            stream: false,
            format: "json",
            options: .init(temperature: 0)
        )
        let body = try JSONEncoder().encode(payload)
        let req = HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: 60
        )
        let resp = try await transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw OllamaError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: resp.body)
        guard let json = envelope.message.content.data(using: .utf8) else {
            throw OllamaError.malformed
        }
        let parsed = try JSONDecoder().decode(JSONResult.self, from: json)
        let type = Frontmatter.EntryType(rawValue: parsed.type) ?? .unknown
        return ClassifierResult(
            type: type,
            title: parsed.title,
            tags: parsed.tags ?? [],
            scheduledAt: parsed.scheduled_at.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            deadlineAt: parsed.deadline_at.flatMap { ISO8601DateFormatter.anthropic.date(from: $0) },
            effortMinutes: parsed.effort_minutes,
            importance: ClassifierResult.normalizedImportance(parsed.importance),
            metadataConfidence: parsed.metadata_confidence
        )
    }

    public static func isAvailable(transport: HTTPTransporting = HTTPTransport(),
                                   probe: URL = URL(string: "http://127.0.0.1:11434/api/tags")!) async -> Bool {
        do {
            let resp = try await transport.send(HTTPRequest(method: "GET", url: probe, timeout: 1))
            return resp.status == 200
        } catch {
            return false
        }
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

    public enum OllamaError: Error, Equatable {
        case upstream(Int, String)
        case malformed
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let stream: Bool
        let format: String
        let options: Options
        struct Msg: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double }
    }

    struct ChatResponse: Decodable {
        let message: Msg
        struct Msg: Decodable { let role: String; let content: String }
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

extension OllamaClassifier.OllamaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .upstream(status, _):
            "Ollama returned an error (HTTP \(status)). Is the model pulled and running?"
        case .malformed:
            "Ollama returned an unreadable response."
        }
    }
}

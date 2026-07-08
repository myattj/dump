import Foundation

/// Local answer synthesis through Ollama's `/api/chat` endpoint.
public struct OllamaSynthesizer: Synthesizing {
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
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        let prompt = ClaudeSynthesizer.buildPrompt(query: query, hits: hits)
        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: ClaudeSynthesizer.systemPrompt),
                .init(role: "user", content: prompt),
            ],
            stream: false,
            options: .init(temperature: 0.2)
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
            throw OllamaClassifier.OllamaError.upstream(resp.status, String(data: resp.body, encoding: .utf8) ?? "")
        }
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: resp.body)
        let text = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return SynthesisResult(
            text: text,
            citations: ClaudeSynthesizer.extractCitations(from: text, hits: hits)
        )
    }

    /// True token streaming: Ollama's chat endpoint emits NDJSON — one
    /// `{"message":{"content":…},"done":…}` object per line.
    public func synthesizeStream(query: String, hits: [QueryEngine.Hit]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = ClaudeSynthesizer.buildPrompt(query: query, hits: hits)
                    let payload = ChatRequest(
                        model: model,
                        messages: [
                            .init(role: "system", content: ClaudeSynthesizer.systemPrompt),
                            .init(role: "user", content: prompt),
                        ],
                        stream: true,
                        options: .init(temperature: 0.2)
                    )
                    let body = try JSONEncoder().encode(payload)
                    let req = HTTPRequest(
                        method: "POST",
                        url: endpoint,
                        headers: ["Content-Type": "application/json"],
                        body: body,
                        timeout: 60
                    )
                    for try await line in transport.streamLines(req) {
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data) else { continue }
                        // Ollama reports failures (model OOM, runner crash) as
                        // an NDJSON error line on a 200 response.
                        if let err = chunk.error, !err.isEmpty {
                            throw OllamaClassifier.OllamaError.upstream(200, err)
                        }
                        if let text = chunk.message?.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch let HTTPError.status(code, message) {
                    continuation.finish(throwing: OllamaClassifier.OllamaError.upstream(code, message))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let stream: Bool
        let options: Options
        struct Msg: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double }
    }

    private struct ChatResponse: Decodable {
        let message: Msg
        struct Msg: Decodable { let role: String; let content: String }
    }

    private struct ChatStreamChunk: Decodable {
        let message: Msg?
        let done: Bool?
        let error: String?
        struct Msg: Decodable { let content: String? }
    }
}

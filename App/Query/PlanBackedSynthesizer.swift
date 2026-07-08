import Foundation

/// Synthesizes Ask-mode answers through the selected official local CLI
/// (Claude Code or Codex) using that CLI's existing subscription login.
public struct PlanBackedSynthesizer: Synthesizing {
    private let client: PlanBackedCLIClient

    public init(
        configStore: CustomLLMConfigStore = .shared,
        client: PlanBackedCLIClient? = nil,
        runner: LocalPlanCommandRunning = SystemLocalPlanCommandRunner()
    ) {
        self.client = client ?? PlanBackedCLIClient(configStore: configStore, runner: runner)
    }

    public func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        let prompt = """
        \(ClaudeSynthesizer.systemPrompt)

        \(ClaudeSynthesizer.buildPrompt(query: query, hits: hits))
        """
        let text = try await client.complete(prompt: prompt, timeout: 120)
        let citations = ClaudeSynthesizer.extractCitations(from: text, hits: hits)
        return SynthesisResult(text: text, citations: citations)
    }
}

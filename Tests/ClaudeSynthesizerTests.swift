import XCTest
@testable import Dump

final class ClaudeSynthesizerTests: XCTestCase {
    private func hit(_ docid: String, file: String, title: String? = nil, snippet: String = "") -> QMDHit {
        QMDHit(docid: docid, file: file, title: title, score: 1, context: nil, snippet: snippet)
    }

    func testExtractsCitationIndicesFromAnswer() {
        let hits = [
            hit("#1", file: "inbox/a.md", title: "Alpha"),
            hit("#2", file: "inbox/b.md", title: "Beta"),
            hit("#3", file: "inbox/c.md", title: "Gamma"),
        ]
        let citations = ClaudeSynthesizer.extractCitations(
            from: "We saw it in [1] and again in [3].",
            hits: hits
        )
        XCTAssertEqual(citations.map(\.index), [1, 3])
        XCTAssertEqual(citations.map(\.path), ["inbox/a.md", "inbox/c.md"])
    }

    func testIgnoresOutOfRangeCitations() {
        let hits = [hit("#1", file: "x/a")]
        let citations = ClaudeSynthesizer.extractCitations(from: "see [5]", hits: hits)
        XCTAssertTrue(citations.isEmpty)
    }

    func testBuildsPromptWithEnumeratedHits() {
        let hits = [
            hit("#1", file: "x/a", title: "A", snippet: "alpha snippet"),
            hit("#2", file: "x/b", title: "B", snippet: "beta snippet"),
        ]
        let prompt = ClaudeSynthesizer.buildPrompt(query: "what?", hits: hits)
        XCTAssertTrue(prompt.contains("[1] A"))
        XCTAssertTrue(prompt.contains("[2] B"))
        XCTAssertTrue(prompt.contains("alpha snippet"))
    }

    func testSynthesisCallSucceeds() async throws {
        let transport = MockHTTPTransport()
        transport.stub(path: "/v1/messages", json: [
            "content": [["type": "text", "text": "Per [1], you should do X."]]
        ])
        let key = KeychainStore(service: "dump.tests.\(UUID())")
        try key.set("k", for: .anthropicAPIKey)
        let synth = ClaudeSynthesizer(keychain: key, transport: transport)
        let result = try await synth.synthesize(
            query: "Q",
            hits: [hit("#1", file: "x/p", title: "First", snippet: "...")]
        )
        XCTAssertTrue(result.text.contains("Per [1]"))
        XCTAssertEqual(result.citations.first?.path, "x/p")
    }
}

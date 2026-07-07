import XCTest
@testable import Dump

final class QueryEngineTests: XCTestCase {
    func testSearchSendsLexAndVecSubqueriesAndReturnsHits() async throws {
        let client = MockQMDClient()
        client.stubHits([
            QMDHit(docid: "#abc", file: "inbox/note.md", title: "alpha", score: 0.91, context: nil, snippet: "..."),
            QMDHit(docid: "#def", file: "inbox/beta.md", title: nil, score: 0.42, context: nil, snippet: "..."),
        ])
        let engine = QueryEngine(client: client)
        let hits = try await engine.search("laundry")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.docid, "#abc")
        XCTAssertEqual(hits.first?.collection, "inbox")

        let sent = client.queries
        XCTAssertEqual(sent.count, 1)
        let kinds = sent[0].searches.map(\.type)
        XCTAssertEqual(kinds, [.lex, .vec])
        XCTAssertEqual(sent[0].searches.first?.query, "laundry")
    }

    func testSearchPropagatesClientErrors() async {
        let client = MockQMDClient()
        client.setQueryError(QMDClientError.daemonUnavailable)
        let engine = QueryEngine(client: client)
        do {
            _ = try await engine.search("x")
            XCTFail("expected error")
        } catch let e as QMDClientError {
            XCTAssertEqual(e, .daemonUnavailable)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAddCollectionShellsOutToCLI() async throws {
        let client = MockQMDClient()
        let engine = QueryEngine(client: client)
        try await engine.addCollection(name: "code-x", root: URL(fileURLWithPath: "/tmp/repo"), glob: "**/*.swift")
        XCTAssertEqual(client.cliCalls, [["collection", "add", "/tmp/repo", "--name", "code-x", "--mask", "**/*.swift"]])
    }

    func testEmbedAndUpdateMapToCLI() async throws {
        let client = MockQMDClient()
        let engine = QueryEngine(client: client)
        try await engine.updateIndex()
        try await engine.embed()
        XCTAssertEqual(client.cliCalls, [["update"], ["embed"]])
    }

    func testCollectionNamesParsesListOutput() async throws {
        let client = MockQMDClient()
        client.stubCLIStdout(forFirstArg: "collection", stdout: """
        Collections (2):

        notes (qmd://notes/)
          Pattern:  **/*.md
          Files:    0
          Updated:  0s ago

        inbox (qmd://inbox/)
          Pattern:  **/*.md
          Files:    7
          Updated:  1m ago
        """)
        let engine = QueryEngine(client: client)
        let names = try await engine.collectionNames()
        XCTAssertEqual(names, ["notes", "inbox"])
    }
}

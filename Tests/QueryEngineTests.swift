import XCTest
@testable import Dump

final class QueryEngineTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-query-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "dump.query.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        tempRoot = nil
        storage = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

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

    func testTaggedTodoSummaryIncludesAllMatchingTodoStatuses() async throws {
        let writer = MarkdownWriter(clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        try FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)

        _ = try writer.write(body: "Ship tag summary", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "active-task"
            fm.type = .task
            fm.title = "Ship tag summary"
            fm.tags = ["work"]
            fm.status = .active
            fm.deadlineAt = Date(timeIntervalSince1970: 1_800_086_400)
            fm.effortMinutes = 45
            fm.importance = 3
        }
        _ = try writer.write(body: "Follow up after launch", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "done-task"
            fm.type = .reminder
            fm.title = "Follow up after launch"
            fm.tags = ["work", "client"]
            fm.status = .done
            fm.completedAt = Date(timeIntervalSince1970: 1_800_010_000)
        }
        _ = try writer.write(body: "Old idea", into: storage.subdirectory(.inbox)) { fm in
            fm.type = .idea
            fm.title = "Old idea"
            fm.tags = ["work"]
            fm.status = .active
        }

        let client = MockQMDClient()
        let engine = QueryEngine(client: client, storage: storage)
        let summary = try await engine.taggedTodoSummary(
            matching: "#work",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(summary?.tag, "work")
        XCTAssertEqual(summary?.hits.map(\.title), ["Ship tag summary", "Follow up after launch"])
        XCTAssertEqual(summary?.result.label, "Tag summary")
        XCTAssertTrue(summary?.result.text.contains("#work has 2 tagged todos: 1 active, 1 done, 0 dismissed.") == true)
        XCTAssertTrue(summary?.result.text.contains("[1] Ship tag summary (status active, due") == true)
        XCTAssertTrue(summary?.result.text.contains("45m, importance 3") == true)
        XCTAssertTrue(summary?.result.text.contains("[2] Follow up after launch (status done, completed") == true)
        XCTAssertEqual(summary?.result.citations.count, 2)
        XCTAssertTrue(client.queries.isEmpty)
    }

    func testTaggedTodoSummaryMatchesBareTagAndTagPrefixCaseInsensitively() async throws {
        let writer = MarkdownWriter(clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        try FileManager.default.createDirectory(at: storage.subdirectory(.inbox), withIntermediateDirectories: true)
        _ = try writer.write(body: "Call Ada", into: storage.subdirectory(.inbox)) { fm in
            fm.id = "ada"
            fm.type = .task
            fm.tags = ["Client"]
        }

        let engine = QueryEngine(client: MockQMDClient(), storage: storage)
        let bare = try await engine.taggedTodoSummary(matching: "client")
        let prefixed = try await engine.taggedTodoSummary(matching: "tag:CLIENT")
        let phrase = try await engine.taggedTodoSummary(matching: "client followup")
        XCTAssertEqual(bare?.hits.count, 1)
        XCTAssertEqual(prefixed?.hits.count, 1)
        XCTAssertNil(phrase)
    }
}

@MainActor
final class QueryViewModelShutdownTests: XCTestCase {
    func testReplacementResetAndStopJoinEverySynthesisRun() async {
        let client = MockQMDClient()
        client.stubHits([
            QMDHit(
                docid: "#shutdown",
                file: "inbox/shutdown.md",
                title: "Shutdown",
                score: 1,
                context: nil,
                snippet: "provider lifecycle"
            ),
        ])
        let synthesizer = CancellationRecordingSynthesizer()
        let viewModel = QueryViewModel(
            engine: QueryEngine(client: client),
            synthesizer: synthesizer
        )
        viewModel.mode = .ask

        viewModel.query = "first"
        viewModel.submitRun()
        await waitForStartedCount(1, synthesizer: synthesizer)

        viewModel.query = "second"
        viewModel.submitRun()
        await waitForStartedCount(2, synthesizer: synthesizer)

        viewModel.reset()
        viewModel.query = "third"
        viewModel.submitRun()
        await waitForStartedCount(3, synthesizer: synthesizer)

        await viewModel.stop()

        let started = await synthesizer.startedCount()
        let cancelled = await synthesizer.cancelledCount()
        XCTAssertEqual(started, 3)
        XCTAssertEqual(cancelled, 3)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isSynthesizing)
    }

    private func waitForStartedCount(
        _ expected: Int,
        synthesizer: CancellationRecordingSynthesizer
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while (await synthesizer.startedCount()) < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let actual = await synthesizer.startedCount()
        XCTAssertEqual(actual, expected)
    }
}

private actor CancellationRecordingSynthesizer: Synthesizing {
    private var started = 0
    private var cancelled = 0

    func synthesize(query: String, hits: [QueryEngine.Hit]) async throws -> SynthesisResult {
        started += 1
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled += 1
            throw CancellationError()
        }
        return SynthesisResult(text: "unexpected", citations: [])
    }

    func startedCount() -> Int { started }
    func cancelledCount() -> Int { cancelled }
}

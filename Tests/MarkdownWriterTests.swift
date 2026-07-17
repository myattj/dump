import XCTest
@testable import Dump

final class MarkdownWriterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testWritesFileWithFrontmatter() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = MarkdownWriter(clock: { now })
        let result = try writer.write(body: "remind me later", into: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        let raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix("---\n"))
        XCTAssertTrue(raw.contains("source: capture"))
        XCTAssertTrue(raw.contains("remind me later"))
    }

    func testFilenameUsesSlugFromBody() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = MarkdownWriter(clock: { now })
        let result = try writer.write(body: "Pick up dry cleaning later today", into: tempDir)
        XCTAssertNotNil(
            result.url.lastPathComponent.range(
                of: #"^\d{4}-\d{2}-\d{2}-\d{4}-pick-up-dry-cleaning-later-today-"#,
                options: .regularExpression
            )
        )
        XCTAssertTrue(result.url.lastPathComponent.hasSuffix("-\(result.frontmatter.id).md"))
    }

    func testIdenticalWritesInSameMinuteCreateDistinctFilesWithoutLosingContent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = MarkdownWriter(clock: { now })
        let body = "Pick up dry cleaning later today"

        let first = try writer.write(body: body, into: tempDir)
        let second = try writer.write(body: body, into: tempDir)

        XCTAssertNotEqual(first.frontmatter.id, second.frontmatter.id)
        XCTAssertNotEqual(first.url, second.url)

        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            Set(files.map(\.lastPathComponent)),
            Set([first.url.lastPathComponent, second.url.lastPathComponent])
        )

        for result in [first, second] {
            let raw = try String(contentsOf: result.url, encoding: .utf8)
            let (frontmatter, storedBody) = try FrontmatterCodec.decode(raw)
            XCTAssertEqual(frontmatter.id, result.frontmatter.id)
            XCTAssertEqual(storedBody, body)
            XCTAssertTrue(result.url.lastPathComponent.contains(result.frontmatter.id))
        }
    }

    func testSlugFallsBackToIDWhenBodyIsBlank() throws {
        let writer = MarkdownWriter()
        let result = try writer.write(body: "    ", into: tempDir)
        XCTAssertTrue(result.url.lastPathComponent.hasSuffix(".md"))
    }

    func testRewriteFrontmatterPreservesBody() throws {
        let writer = MarkdownWriter()
        let result = try writer.write(body: "first line\nsecond line", into: tempDir)
        var fm = result.frontmatter
        fm.title = "Updated"
        fm.tags = ["x"]
        try writer.rewriteFrontmatter(at: result.url, with: fm)
        let raw = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(raw.contains("title: Updated"))
        XCTAssertTrue(raw.contains("first line\nsecond line"))
    }

    func testSeedFrontmatterAllowsCustomFields() throws {
        let writer = MarkdownWriter()
        let result = try writer.write(body: "agenda", into: tempDir, source: .meeting) { fm in
            fm.type = .meeting
        }
        XCTAssertEqual(result.frontmatter.type, .meeting)
        XCTAssertEqual(result.frontmatter.source, .meeting)
    }
}

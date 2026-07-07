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
        let writer = MarkdownWriter()
        let result = try writer.write(body: "Pick up dry cleaning later today", into: tempDir)
        XCTAssertTrue(result.url.lastPathComponent.contains("pick-up-dry-cleaning"))
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

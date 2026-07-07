import XCTest
@testable import Dump

final class HitDisplayTests: XCTestCase {
    // MARK: - Title

    func testTitleParsesSlugFromTimestampedFilename() {
        let hit = makeHit(file: "inbox/2026-05-18-1819-i-need-to-take-the-laundry.md", title: nil)
        XCTAssertEqual(HitDisplay.title(for: hit), "I need to take the laundry")
    }

    func testTitlePrefersFrontmatterTitleWhenItIsNotTheFilename() {
        let hit = makeHit(file: "inbox/2026-05-18-1819-foo.md", title: "Buy more dish soap")
        XCTAssertEqual(HitDisplay.title(for: hit), "Buy more dish soap")
    }

    func testTitleIgnoresFrontmatterTitleThatLooksLikeRawFilename() {
        // qmd sometimes echoes the basename back as title; we should prefer the cleaned slug.
        let hit = makeHit(
            file: "inbox/2026-05-18-1819-laundry-day.md",
            title: "2026-05-18-1819-laundry-day"
        )
        XCTAssertEqual(HitDisplay.title(for: hit), "Laundry day")
    }

    func testTitleFallsBackToBasenameWithoutTimestampPrefix() {
        let hit = makeHit(file: "code/README.md", title: nil)
        XCTAssertEqual(HitDisplay.title(for: hit), "README")
    }

    // MARK: - Date

    func testDateParsesTimestampPrefix() {
        let hit = makeHit(file: "inbox/2026-05-18-1819-foo.md", title: nil)
        let date = HitDisplay.date(for: hit)
        XCTAssertNotNil(date)
        if let date {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            XCTAssertEqual(parts.year, 2026)
            XCTAssertEqual(parts.month, 5)
            XCTAssertEqual(parts.day, 18)
            XCTAssertEqual(parts.hour, 18)
            XCTAssertEqual(parts.minute, 19)
        }
    }

    func testDateReturnsNilForFilenamesWithoutTimestamp() {
        let hit = makeHit(file: "code/README.md", title: nil)
        XCTAssertNil(HitDisplay.date(for: hit))
    }

    // MARK: - Cleaned content

    func testCleanedContentStripsLinePrefixesAndFrontmatter() {
        // Exactly the shape qmd returned in the bug screenshot.
        let raw = """
        2: @@ -1,4 @@ (0 before, 6 after)
        3: ---
        4: id: 01KRYX1PAPFMXW4A242AHQ9YWG
        5: type: unknown
        6: created_at: 2026-05-19T01:19:17Z
        """
        let cleaned = HitDisplay.cleanedContent(raw)
        XCTAssertTrue(cleaned.isEmpty, "expected empty body, got: \(cleaned)")
    }

    func testCleanedContentKeepsBodyAfterFrontmatter() {
        let raw = """
        1: ---
        2: id: 01ABC
        3: type: task
        4: ---
        5:
        6: Pick up the laundry at 10pm tonight.
        7: Don't forget the receipt.
        """
        let cleaned = HitDisplay.cleanedContent(raw)
        XCTAssertEqual(
            cleaned,
            "Pick up the laundry at 10pm tonight.\nDon't forget the receipt."
        )
    }

    func testCleanedContentStripsHunkHeadersOnly() {
        let raw = """
        12: @@ -10,3 @@ (1 before, 2 after)
        13: This is the real content
        14: across two lines.
        """
        XCTAssertEqual(
            HitDisplay.cleanedContent(raw),
            "This is the real content\nacross two lines."
        )
    }

    func testCleanedContentLeavesPlainTextAlone() {
        // No line-number prefix, no frontmatter — pass-through.
        let raw = "Just a plain note about coffee."
        XCTAssertEqual(HitDisplay.cleanedContent(raw), "Just a plain note about coffee.")
    }

    func testCleanedContentPreservesHorizontalRulesAfterContent() {
        // A `---` after body content is markdown HR, not frontmatter — keep it.
        let raw = """
        1: First paragraph.
        2:
        3: ---
        4:
        5: Second paragraph.
        """
        let cleaned = HitDisplay.cleanedContent(raw)
        XCTAssertTrue(cleaned.contains("---"), "expected HR preserved, got: \(cleaned)")
    }

    // MARK: - Body

    func testBodyIsEmptyWhenSnippetJustRepeatsTitle() {
        // Quick-capture: body and filename slug are the same one-liner.
        let raw = """
        2: ---
        3: id: 01ABC
        4: type: unknown
        5: ---
        6:
        7: I need to take the laundry
        """
        let hit = makeHit(
            file: "inbox/2026-05-18-1819-i-need-to-take-the-laundry.md",
            title: nil,
            snippet: raw
        )
        XCTAssertEqual(HitDisplay.body(for: hit), "")
    }

    func testBodyKeepsLinesThatDifferFromTitle() {
        let raw = """
        2: ---
        3: type: task
        4: ---
        5:
        6: I need to take the laundry
        7: Don't forget the fabric softener.
        """
        let hit = makeHit(
            file: "inbox/2026-05-18-1819-i-need-to-take-the-laundry.md",
            title: nil,
            snippet: raw
        )
        XCTAssertEqual(HitDisplay.body(for: hit), "Don't forget the fabric softener.")
    }

    func testBodyReturnsFullContentWhenTitleIsMissing() {
        let raw = "Plain content here.\nAnother line."
        let hit = makeHit(file: "code/README.md", title: nil, snippet: raw)
        // Title fallback for README.md is "README", which doesn't appear in
        // the body, so nothing should be filtered.
        XCTAssertEqual(HitDisplay.body(for: hit), "Plain content here.\nAnother line.")
    }

    // MARK: - Type badge

    func testTypeBadgeExtractedFromSnippetYAML() {
        let raw = """
        3: ---
        4: type: task
        5: ---
        """
        let hit = makeHit(file: "x.md", title: nil, snippet: raw)
        XCTAssertEqual(HitDisplay.type(for: hit)?.label, "Task")
    }

    func testTypeBadgeAbsentForUnknownType() {
        let raw = "3: ---\n4: type: unknown\n5: ---"
        let hit = makeHit(file: "x.md", title: nil, snippet: raw)
        XCTAssertNil(HitDisplay.type(for: hit))
    }

    // MARK: - Helpers

    private func makeHit(
        file: String,
        title: String?,
        snippet: String = "",
        context: String? = nil
    ) -> QMDHit {
        QMDHit(docid: "test", file: file, title: title, score: 0.8, context: context, snippet: snippet)
    }
}

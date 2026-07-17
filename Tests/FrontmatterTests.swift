import XCTest
@testable import Dump

final class FrontmatterTests: XCTestCase {
    func testRoundTrip() throws {
        let fm = Frontmatter(
            id: "01HXYTEST",
            type: .reminder,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            scheduledAt: Date(timeIntervalSince1970: 1_700_003_600),
            status: .active,
            tags: ["home", "chores"],
            notificationId: "A1",
            source: .capture,
            classifier: "claude-haiku-4-5",
            title: "Do laundry",
            deadlineAt: Date(timeIntervalSince1970: 1_700_010_800),
            effortMinutes: 25,
            queueRank: 2,
            queueScore: 12.5,
            completedAt: Date(timeIntervalSince1970: 1_700_011_000),
            metadataConfidence: 0.75
        )
        let encoded = FrontmatterCodec.encode(fm, body: "remind me to do laundry later")
        let (decoded, body) = try FrontmatterCodec.decode(encoded)
        XCTAssertEqual(decoded, fm)
        XCTAssertEqual(body, "remind me to do laundry later")
    }

    func testQuotesValueContainingColon() throws {
        let fm = Frontmatter(
            id: "01HXY",
            createdAt: Date(timeIntervalSince1970: 0),
            title: "9:00 standup: review backlog"
        )
        let encoded = FrontmatterCodec.encode(fm, body: "x")
        let (decoded, _) = try FrontmatterCodec.decode(encoded)
        XCTAssertEqual(decoded.title, "9:00 standup: review backlog")
    }

    func testMissingDelimiterThrows() {
        let raw = "not a frontmatter\nbody"
        XCTAssertThrowsError(try FrontmatterCodec.decode(raw))
    }

    func testTagsRoundTrip() throws {
        let fm = Frontmatter(
            id: "01HXY",
            createdAt: Date(timeIntervalSince1970: 0),
            tags: ["a", "b", "c"]
        )
        let encoded = FrontmatterCodec.encode(fm, body: "")
        let (decoded, _) = try FrontmatterCodec.decode(encoded)
        XCTAssertEqual(decoded.tags, ["a", "b", "c"])
    }

    func testTagsWithPunctuationAndEscapesRoundTrip() throws {
        let tags = [
            "research, later",
            "say \"hello\"",
            #"path\segment"#,
            "line one\nline two",
            "topic:swift",
        ]
        let fm = Frontmatter(
            id: "01HXY",
            createdAt: Date(timeIntervalSince1970: 0),
            tags: tags
        )

        let encoded = FrontmatterCodec.encode(fm, body: "")
        let (decoded, _) = try FrontmatterCodec.decode(encoded)

        XCTAssertEqual(decoded.tags, tags)
    }

    func testLegacyUnquotedTagsStillDecode() throws {
        let raw = """
        ---
        id: 01HXY
        created_at: 1970-01-01T00:00:00Z
        tags: [home, chores]
        ---
        """

        let (decoded, _) = try FrontmatterCodec.decode(raw)

        XCTAssertEqual(decoded.tags, ["home", "chores"])
    }

    func testBackcompatLeavesQueueFieldsNil() throws {
        let raw = """
        ---
        id: 01HXY
        type: task
        created_at: 2026-05-16T09:00:00Z
        status: active
        tags: []
        source: capture
        ---
        follow up
        """
        let (decoded, body) = try FrontmatterCodec.decode(raw)
        XCTAssertEqual(decoded.type, .task)
        XCTAssertNil(decoded.deadlineAt)
        XCTAssertNil(decoded.effortMinutes)
        XCTAssertNil(decoded.queueRank)
        XCTAssertNil(decoded.queueScore)
        XCTAssertNil(decoded.completedAt)
        XCTAssertNil(decoded.metadataConfidence)
        XCTAssertEqual(body, "follow up")
    }
}

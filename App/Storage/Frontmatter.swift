import Foundation

/// Schema for entry frontmatter. Values are deliberately permissive — the
/// classifier may rewrite `type`, `title`, `tags`, `scheduled_at`, and queue
/// metadata after the file is first written.
public struct Frontmatter: Codable, Equatable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case task, reminder, note, idea, reference, meeting, unknown
    }

    public enum Status: String, Codable, Sendable {
        case active, done, dismissed
    }

    public enum Source: String, Codable, Sendable {
        case capture, pdf, meeting, code
    }

    public var id: String
    public var type: EntryType
    public var createdAt: Date
    public var scheduledAt: Date?
    public var status: Status
    public var tags: [String]
    public var notificationId: String?
    public var source: Source
    public var classifier: String?
    public var title: String?
    public var pdfPath: String?
    public var pageNumber: Int?
    public var meetingDate: Date?
    public var deadlineAt: Date?
    public var effortMinutes: Int?
    public var queueRank: Int?
    public var queueScore: Double?
    public var completedAt: Date?
    public var metadataConfidence: Double?

    public init(
        id: String,
        type: EntryType = .unknown,
        createdAt: Date,
        scheduledAt: Date? = nil,
        status: Status = .active,
        tags: [String] = [],
        notificationId: String? = nil,
        source: Source = .capture,
        classifier: String? = nil,
        title: String? = nil,
        pdfPath: String? = nil,
        pageNumber: Int? = nil,
        meetingDate: Date? = nil,
        deadlineAt: Date? = nil,
        effortMinutes: Int? = nil,
        queueRank: Int? = nil,
        queueScore: Double? = nil,
        completedAt: Date? = nil,
        metadataConfidence: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt
        self.status = status
        self.tags = tags
        self.notificationId = notificationId
        self.source = source
        self.classifier = classifier
        self.title = title
        self.pdfPath = pdfPath
        self.pageNumber = pageNumber
        self.meetingDate = meetingDate
        self.deadlineAt = deadlineAt
        self.effortMinutes = effortMinutes
        self.queueRank = queueRank
        self.queueScore = queueScore
        self.completedAt = completedAt
        self.metadataConfidence = metadataConfidence
    }
}

/// Minimal YAML codec for the subset of YAML the frontmatter uses: flat
/// dictionary with string/number/bool/null/ISO-8601 dates and one-line
/// arrays. Avoids a YAML dep — we own the schema.
public enum FrontmatterCodec {
    public static let delimiter = "---"

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func encode(_ fm: Frontmatter, body: String) -> String {
        var lines: [String] = [delimiter]
        lines.append("id: \(fm.id)")
        lines.append("type: \(fm.type.rawValue)")
        lines.append("created_at: \(iso.string(from: fm.createdAt))")
        if let s = fm.scheduledAt { lines.append("scheduled_at: \(iso.string(from: s))") }
        lines.append("status: \(fm.status.rawValue)")
        lines.append("tags: [\(fm.tags.map { escape($0) }.joined(separator: ", "))]")
        if let n = fm.notificationId { lines.append("notification_id: \(n)") }
        lines.append("source: \(fm.source.rawValue)")
        if let c = fm.classifier { lines.append("classifier: \(c)") }
        if let t = fm.title { lines.append("title: \(escape(t))") }
        if let p = fm.pdfPath { lines.append("pdf_path: \(escape(p))") }
        if let pn = fm.pageNumber { lines.append("page_number: \(pn)") }
        if let md = fm.meetingDate { lines.append("meeting_date: \(iso.string(from: md))") }
        if let d = fm.deadlineAt { lines.append("deadline_at: \(iso.string(from: d))") }
        if let e = fm.effortMinutes { lines.append("effort_minutes: \(e)") }
        if let r = fm.queueRank { lines.append("queue_rank: \(r)") }
        if let s = fm.queueScore { lines.append("queue_score: \(formatDouble(s))") }
        if let c = fm.completedAt { lines.append("completed_at: \(iso.string(from: c))") }
        if let c = fm.metadataConfidence { lines.append("metadata_confidence: \(formatDouble(c))") }
        lines.append(delimiter)
        return lines.joined(separator: "\n") + "\n" + body
    }

    public static func decode(_ contents: String) throws -> (Frontmatter, String) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == delimiter else {
            throw DecodeError.missingDelimiter
        }
        var idx = 1
        var pairs: [String: String] = [:]
        while idx < lines.count, lines[idx] != delimiter {
            let line = lines[idx]
            if let sep = line.firstIndex(of: ":") {
                let key = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                pairs[key] = value
            }
            idx += 1
        }
        guard idx < lines.count else { throw DecodeError.missingDelimiter }
        let body = lines[(idx + 1)...].joined(separator: "\n")

        guard let id = pairs["id"] else { throw DecodeError.missingField("id") }
        guard let createdRaw = pairs["created_at"], let created = iso.date(from: createdRaw) else {
            throw DecodeError.missingField("created_at")
        }
        let type = Frontmatter.EntryType(rawValue: pairs["type"] ?? "unknown") ?? .unknown
        let status = Frontmatter.Status(rawValue: pairs["status"] ?? "active") ?? .active
        let source = Frontmatter.Source(rawValue: pairs["source"] ?? "capture") ?? .capture
        let scheduled = pairs["scheduled_at"].flatMap { iso.date(from: $0) }
        let meeting = pairs["meeting_date"].flatMap { iso.date(from: $0) }
        let deadline = pairs["deadline_at"].flatMap { iso.date(from: $0) }
        let completed = pairs["completed_at"].flatMap { iso.date(from: $0) }

        let fm = Frontmatter(
            id: id,
            type: type,
            createdAt: created,
            scheduledAt: scheduled,
            status: status,
            tags: parseInlineArray(pairs["tags"] ?? "[]"),
            notificationId: pairs["notification_id"],
            source: source,
            classifier: pairs["classifier"],
            title: pairs["title"].map(unescape),
            pdfPath: pairs["pdf_path"].map(unescape),
            pageNumber: pairs["page_number"].flatMap(Int.init),
            meetingDate: meeting,
            deadlineAt: deadline,
            effortMinutes: pairs["effort_minutes"].flatMap(Int.init),
            queueRank: pairs["queue_rank"].flatMap(Int.init),
            queueScore: pairs["queue_score"].flatMap(Double.init),
            completedAt: completed,
            metadataConfidence: pairs["metadata_confidence"].flatMap(Double.init)
        )
        return (fm, body)
    }

    public enum DecodeError: Error, Equatable {
        case missingDelimiter
        case missingField(String)
    }

    private static func escape(_ s: String) -> String {
        if s.contains(":") || s.contains("#") || s.contains("\"") || s.contains("'") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func formatDouble(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func unescape(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        let inner = String(s.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func parseInlineArray(_ s: String) -> [String] {
        var trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return [] }
        trimmed.removeFirst()
        trimmed.removeLast()
        return trimmed
            .split(separator: ",")
            .map { unescape($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}

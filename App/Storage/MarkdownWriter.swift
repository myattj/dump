import Foundation

/// Writes captured entries to disk as `<timestamp>-<slug>.md` with YAML
/// frontmatter. Pure I/O — classification happens after the write returns.
public struct MarkdownWriter: Sendable {
    public struct WriteResult: Sendable, Equatable {
        public let url: URL
        public let frontmatter: Frontmatter
    }

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public func write(
        body: String,
        into directory: URL,
        source: Frontmatter.Source = .capture,
        slugHint: String? = nil,
        seedFrontmatter: ((inout Frontmatter) -> Void)? = nil
    ) throws -> WriteResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = clock()
        var fm = Frontmatter(
            id: ULID().value,
            createdAt: now,
            source: source
        )
        seedFrontmatter?(&fm)

        let slug = (slugHint ?? Self.slug(from: body, fallback: fm.id)).isEmpty
            ? fm.id
            : (slugHint ?? Self.slug(from: body, fallback: fm.id))

        let filename = "\(Self.timestampFormatter.string(from: now))-\(slug).md"
        let url = directory.appendingPathComponent(filename)

        let contents = FrontmatterCodec.encode(fm, body: body)
        try contents.write(to: url, atomically: true, encoding: .utf8)

        return WriteResult(url: url, frontmatter: fm)
    }

    /// Replace the frontmatter of an existing file in-place. Used by the
    /// classifier after async classification, and by the scheduler when it
    /// registers a notification id.
    public func rewriteFrontmatter(
        at url: URL,
        with frontmatter: Frontmatter
    ) throws {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let (_, body) = try FrontmatterCodec.decode(raw)
        let contents = FrontmatterCodec.encode(frontmatter, body: body)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func slug(from body: String, fallback: String) -> String {
        let firstLine = body
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? fallback
        let lowered = firstLine.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 40 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

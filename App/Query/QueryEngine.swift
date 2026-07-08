import Foundation
import OSLog

/// Public surface the rest of the app calls into for search. Delegates to a
/// `QMDClienting` (MCP for reads, CLI shell-out for writes). Tests inject a
/// fake client; production wires `MCPClient(daemon:)`.
public actor QueryEngine {
    public typealias Hit = QMDHit

    private let client: QMDClienting
    private let storage: StoragePreference?
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "query")

    public init(client: QMDClienting, storage: StoragePreference? = nil) {
        self.client = client
        self.storage = storage
    }

    public init(daemon: QMDDaemonController, transport: HTTPTransporting = HTTPTransport(), storage: StoragePreference = .shared) {
        self.client = MCPClient(daemon: daemon, transport: transport)
        self.storage = storage
    }

    /// Run a natural-language search. We send both a lex (BM25) and a vec
    /// (semantic) sub-query so we get strong recall whether the user typed
    /// keywords or a question. Adjust `rerank` to `false` to skip the LLM
    /// reranker on CPU-only machines.
    public func search(_ query: String, collections: [String]? = nil, limit: Int = 20, rerank: Bool = true) async throws -> [Hit] {
        let q = QMDQuery(
            searches: [
                QMDSearchTerm(type: .lex, query: query),
                QMDSearchTerm(type: .vec, query: query),
            ],
            collections: collections,
            limit: limit,
            rerank: rerank
        )
        return try await client.query(q)
    }

    /// Re-index every collection. qmd's CLI doesn't expose a per-collection
    /// update, so we walk them all — fast incremental either way.
    public func updateIndex() async throws {
        _ = try await client.runCLI(arguments: ["update"])
    }

    /// Generate embeddings for any documents that don't have them yet.
    /// Cheap (no-op) when everything is already embedded.
    public func embed() async throws {
        _ = try await client.runCLI(arguments: ["embed"])
    }

    /// Registers a filesystem folder as a qmd collection. qmd's CLI expects
    /// `collection add <path> --name <name> --mask <glob>` — passing them in
    /// the wrong order silently uses the wrong path (qmd resolves the first
    /// positional arg relative to CWD).
    public func addCollection(name: String, root: URL, glob: String) async throws {
        _ = try await client.runCLI(arguments: [
            "collection", "add", root.path,
            "--name", name,
            "--mask", glob,
        ])
    }

    public func removeCollection(name: String) async throws {
        _ = try await client.runCLI(arguments: ["collection", "remove", name])
    }

    /// Returns the names of every registered collection. Used at app start
    /// to skip `addCollection` for storage subdirs already wired up.
    public func collectionNames() async throws -> [String] {
        let out = try await client.runCLI(arguments: ["collection", "list"])
        var names: [String] = []
        for line in out.stdout.split(separator: "\n") {
            // Format: "<name> (qmd://<name>/)"  — the leading non-indented lines.
            guard let openParen = line.firstIndex(of: "("),
                  line.distance(from: line.startIndex, to: openParen) > 1,
                  !line.hasPrefix(" "),
                  !line.hasPrefix("Collections") else { continue }
            let name = line[..<openParen].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    public func status() async throws -> QMDStatus {
        try await client.status()
    }

    /// If the query is a tag lookup (`#foo`, `tag:foo`, or a single bare tag),
    /// returns a deterministic summary of every task/reminder in inbox tagged
    /// with that value. This bypasses qmd's top-N search limit so tag views do
    /// not accidentally hide older or completed todos.
    public func taggedTodoSummary(matching query: String, now: Date = Date()) throws -> TaggedTodoSummary? {
        guard let storage, let requestedTag = Self.requestedTag(from: query) else { return nil }
        let root = storage.root.standardizedFileURL
        let inbox = storage.subdirectory(.inbox)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let entries = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> TaggedTodoEntry? in
                guard let raw = try? String(contentsOf: url, encoding: .utf8),
                      let (frontmatter, body) = try? FrontmatterCodec.decode(raw),
                      frontmatter.type == .task || frontmatter.type == .reminder,
                      frontmatter.tags.contains(where: { Self.normalizedTag($0) == requestedTag }) else {
                    return nil
                }
                return TaggedTodoEntry(
                    url: url,
                    relativePath: Self.relativePath(for: url, root: root),
                    frontmatter: frontmatter,
                    body: body
                )
            }
            .sorted(by: Self.sortTaggedTodos)

        guard !entries.isEmpty else { return nil }

        let hits = entries.enumerated().map { index, entry in
            QMDHit(
                docid: entry.frontmatter.id.isEmpty ? entry.relativePath : entry.frontmatter.id,
                file: entry.relativePath,
                title: Self.displayTitle(for: entry),
                score: Double(entries.count - index),
                context: nil,
                snippet: Self.hitSnippet(for: entry)
            )
        }

        let text = Self.summaryText(for: requestedTag, entries: entries, now: now)
        let citations = entries.enumerated().map { index, entry in
            SynthesisResult.Citation(
                index: index + 1,
                path: entry.relativePath,
                title: Self.displayTitle(for: entry)
            )
        }

        return TaggedTodoSummary(
            tag: requestedTag,
            result: SynthesisResult(text: text, citations: citations, label: "Tag summary"),
            hits: hits
        )
    }

    public typealias QueryEngineError = QMDClientError
}

public struct TaggedTodoSummary: Equatable, Sendable {
    public let tag: String
    public let result: SynthesisResult
    public let hits: [QMDHit]
}

private struct TaggedTodoEntry: Sendable {
    let url: URL
    let relativePath: String
    let frontmatter: Frontmatter
    let body: String
}

private extension QueryEngine {
    static func requestedTag(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("tags:") {
            return optionalNormalizedTag(String(trimmed.dropFirst(5)))
        }
        if lower.hasPrefix("tag:") {
            return optionalNormalizedTag(String(trimmed.dropFirst(4)))
        }
        if trimmed.hasPrefix("#") {
            return optionalNormalizedTag(String(trimmed.dropFirst()))
        }
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count == 1 else { return nil }
        return optionalNormalizedTag(trimmed)
    }

    static func optionalNormalizedTag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") {
            tag.removeFirst()
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
        let normalized = tag.lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedTag(_ raw: String) -> String {
        optionalNormalizedTag(raw) ?? ""
    }

    static func sortTaggedTodos(_ lhs: TaggedTodoEntry, _ rhs: TaggedTodoEntry) -> Bool {
        let lhsGroup = statusSortGroup(lhs.frontmatter.status)
        let rhsGroup = statusSortGroup(rhs.frontmatter.status)
        if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }

        let lhsDate = priorityDate(for: lhs.frontmatter)
        let rhsDate = priorityDate(for: rhs.frontmatter)
        if lhsDate != rhsDate {
            return (lhsDate ?? .distantFuture) < (rhsDate ?? .distantFuture)
        }

        if lhs.frontmatter.createdAt != rhs.frontmatter.createdAt {
            return lhs.frontmatter.createdAt < rhs.frontmatter.createdAt
        }
        return lhs.relativePath < rhs.relativePath
    }

    static func statusSortGroup(_ status: Frontmatter.Status) -> Int {
        switch status {
        case .active: return 0
        case .done: return 1
        case .dismissed: return 2
        }
    }

    static func priorityDate(for frontmatter: Frontmatter) -> Date? {
        frontmatter.deadlineAt ?? frontmatter.scheduledAt ?? frontmatter.completedAt
    }

    static func displayTitle(for entry: TaggedTodoEntry) -> String {
        if let title = entry.frontmatter.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let firstLine = entry.body
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstLine.isEmpty {
            return firstLine
        }
        return "Untitled todo"
    }

    static func summaryText(for tag: String, entries: [TaggedTodoEntry], now: Date) -> String {
        let counts = Dictionary(grouping: entries, by: { $0.frontmatter.status }).mapValues(\.count)
        let citationByPath = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.relativePath, $0.offset + 1) })
        var lines: [String] = [
            "#\(tag) has \(entries.count) tagged \(entries.count == 1 ? "todo" : "todos"): \(countText(counts[.active] ?? 0, "active")), \(countText(counts[.done] ?? 0, "done")), \(countText(counts[.dismissed] ?? 0, "dismissed"))."
        ]

        for status in [Frontmatter.Status.active, .done, .dismissed] {
            let group = entries.filter { $0.frontmatter.status == status }
            guard !group.isEmpty else { continue }
            lines.append("")
            lines.append("\(sectionTitle(for: status)):")
            for entry in group {
                let citationIndex = citationByPath[entry.relativePath] ?? 0
                lines.append("- \(lineText(for: entry, citationIndex: citationIndex, now: now))")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func countText(_ count: Int, _ label: String) -> String {
        "\(count) \(label)"
    }

    static func sectionTitle(for status: Frontmatter.Status) -> String {
        switch status {
        case .active: return "Active"
        case .done: return "Done"
        case .dismissed: return "Dismissed"
        }
    }

    static func lineText(for entry: TaggedTodoEntry, citationIndex: Int, now: Date) -> String {
        var fields: [String] = ["status \(entry.frontmatter.status.rawValue)"]
        if let deadline = entry.frontmatter.deadlineAt {
            fields.append("due \(formatDate(deadline, now: now))")
        }
        if let scheduled = entry.frontmatter.scheduledAt {
            fields.append("scheduled \(formatDate(scheduled, now: now))")
        }
        if let completed = entry.frontmatter.completedAt {
            fields.append("completed \(formatDate(completed, now: now))")
        }
        if let effort = entry.frontmatter.effortMinutes {
            fields.append("\(effort)m")
        }
        if let importance = entry.frontmatter.importance {
            fields.append("importance \(importance)")
        }
        if let snoozed = entry.frontmatter.snoozedUntil {
            fields.append("snoozed until \(formatDate(snoozed, now: now))")
        }
        return "[\(citationIndex)] \(displayTitle(for: entry)) (\(fields.joined(separator: ", ")))"
    }

    static func formatDate(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy h:mm a"
        }
        return formatter.string(from: date)
    }

    static func hitSnippet(for entry: TaggedTodoEntry) -> String {
        FrontmatterCodec.encode(entry.frontmatter, body: entry.body)
    }

    static func relativePath(for url: URL, root: URL) -> String {
        let filePath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }
}

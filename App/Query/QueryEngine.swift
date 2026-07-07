import Foundation
import OSLog

/// Public surface the rest of the app calls into for search. Delegates to a
/// `QMDClienting` (MCP for reads, CLI shell-out for writes). Tests inject a
/// fake client; production wires `MCPClient(daemon:)`.
public actor QueryEngine {
    public typealias Hit = QMDHit

    private let client: QMDClienting
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "query")

    public init(client: QMDClienting) {
        self.client = client
    }

    public init(daemon: QMDDaemonController, transport: HTTPTransporting = HTTPTransport()) {
        self.client = MCPClient(daemon: daemon, transport: transport)
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

    public typealias QueryEngineError = QMDClientError
}

import Foundation

/// Talks to a running qmd daemon. Read operations go through the JSON-RPC
/// MCP server qmd exposes on `POST /mcp`; write operations (collection
/// management, re-index, embed) are CLI-only, so we shell out to the
/// bundled qmd binary for those.
public protocol QMDClienting: Sendable {
    func query(_ q: QMDQuery) async throws -> [QMDHit]
    func get(file: String, fromLine: Int?, maxLines: Int?) async throws -> String
    func status() async throws -> QMDStatus
    func runCLI(arguments: [String]) async throws -> QMDCLIOutput
}

public enum QMDSearchType: String, Codable, Sendable {
    case lex, vec, hyde
}

public struct QMDSearchTerm: Codable, Sendable, Equatable {
    public let type: QMDSearchType
    public let query: String
    public init(type: QMDSearchType, query: String) {
        self.type = type
        self.query = query
    }
}

public struct QMDQuery: Sendable {
    public var searches: [QMDSearchTerm]
    public var collections: [String]?
    public var limit: Int
    public var rerank: Bool
    public var intent: String?
    public var minScore: Double?

    public init(
        searches: [QMDSearchTerm],
        collections: [String]? = nil,
        limit: Int = 10,
        rerank: Bool = true,
        intent: String? = nil,
        minScore: Double? = nil
    ) {
        self.searches = searches
        self.collections = collections
        self.limit = limit
        self.rerank = rerank
        self.intent = intent
        self.minScore = minScore
    }
}

public struct QMDHit: Codable, Sendable, Equatable, Identifiable {
    public let docid: String
    public let file: String
    public let title: String?
    public let score: Double
    public let context: String?
    public let snippet: String

    public init(docid: String, file: String, title: String?, score: Double, context: String?, snippet: String) {
        self.docid = docid
        self.file = file
        self.title = title
        self.score = score
        self.context = context
        self.snippet = snippet
    }

    public var id: String { docid }

    /// First path component, treated as the collection name (qmd's MCP
    /// returns `<collection>/<rest>` as `file`). Empty if the file path has
    /// no segments.
    public var collection: String {
        file.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    }
}

public struct QMDStatus: Codable, Sendable, Equatable {
    public let totalDocuments: Int
    public let needsEmbedding: Int
    public let hasVectorIndex: Bool
    public let collections: [Collection]

    public struct Collection: Codable, Sendable, Equatable {
        public let name: String
        public let path: String?
        public let documents: Int?
    }
}

public struct QMDCLIOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum QMDClientError: Error, Equatable {
    case daemonUnavailable
    case mcpError(code: Int, message: String)
    case malformedResponse(String)
    case cliFailed(exitCode: Int32, stderr: String)
}

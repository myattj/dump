import Foundation

/// Persists the list of user-added code collections in UserDefaults and
/// keeps the qmd daemon in sync.
public actor CodeCollectionStore {
    public struct Collection: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public var name: String
        public var rootPath: String
        public var glob: String

        public init(id: String = ULID().value, name: String, rootPath: String, glob: String = "**/*.{ts,tsx,js,jsx,py,go,rs,swift,java,kt,rb,c,h,cpp,hpp,md}") {
            self.id = id
            self.name = name
            self.rootPath = rootPath
            self.glob = glob
        }
    }

    public static let defaultsKey = "dump.codeCollections"

    private let defaults: UserDefaults
    private let engine: QueryEngine

    public init(defaults: UserDefaults = .standard, engine: QueryEngine) {
        self.defaults = defaults
        self.engine = engine
    }

    public func list() -> [Collection] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Collection].self, from: data)) ?? []
    }

    @discardableResult
    public func add(name: String, root: URL, glob: String? = nil) async throws -> Collection {
        var list = list()
        let entry = Collection(name: name, rootPath: root.path, glob: glob ?? Collection(name: "", rootPath: "").glob)
        list.append(entry)
        try persist(list)
        try await engine.addCollection(name: "code-\(entry.id)", root: root, glob: entry.glob)
        try await engine.embed()
        return entry
    }

    public func remove(id: String) async throws {
        var list = list()
        guard let removed = list.first(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        try persist(list)
        try? await engine.removeCollection(name: "code-\(removed.id)")
    }

    public func reindexAll() async {
        try? await engine.updateIndex()
        try? await engine.embed()
    }

    private func persist(_ list: [Collection]) throws {
        let data = try JSONEncoder().encode(list)
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

import XCTest
@testable import Dump

final class CodeCollectionStoreTests: XCTestCase {
    func testAddPersistsAndShellsOutToCLI() async throws {
        let defaults = UserDefaults(suiteName: "cc.\(UUID())")!
        let client = MockQMDClient()
        let store = CodeCollectionStore(defaults: defaults, engine: QueryEngine(client: client))
        let collection = try await store.add(
            name: "monorepo",
            root: URL(fileURLWithPath: "/tmp/r"),
            glob: "**/*.swift"
        )
        XCTAssertEqual(collection.name, "monorepo")
        let list = await store.list()
        XCTAssertEqual(list.count, 1)

        let calls = client.cliCalls
        XCTAssertTrue(calls.contains { $0.first == "collection" && $0.contains("add") })
        XCTAssertTrue(calls.contains { $0 == ["embed"] })
    }

    func testRemoveDropsFromDefaultsAndCallsCollectionRemove() async throws {
        let defaults = UserDefaults(suiteName: "cc.\(UUID())")!
        let client = MockQMDClient()
        let store = CodeCollectionStore(defaults: defaults, engine: QueryEngine(client: client))
        let added = try await store.add(name: "x", root: URL(fileURLWithPath: "/tmp"))
        try await store.remove(id: added.id)
        let list = await store.list()
        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(client.cliCalls.contains { $0 == ["collection", "remove", "code-\(added.id)"] })
    }
}

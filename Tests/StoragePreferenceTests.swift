import XCTest
@testable import Dump

final class StoragePreferenceTests: XCTestCase {
    var defaults: UserDefaults!
    let suiteName = "dump.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultFallback() {
        let fallback = URL(fileURLWithPath: "/tmp/dump-default")
        let pref = StoragePreference(defaults: defaults, fallback: fallback)
        XCTAssertEqual(pref.root, fallback)
    }

    func testCustomPathPersists() {
        let pref = StoragePreference(defaults: defaults, fallback: URL(fileURLWithPath: "/tmp/x"))
        let target = URL(fileURLWithPath: "/tmp/dump-test")
        pref.setRoot(target)
        XCTAssertEqual(pref.root.path, target.path)
    }

    func testResetReturnsToFallback() {
        let fallback = URL(fileURLWithPath: "/tmp/dump-default")
        let pref = StoragePreference(defaults: defaults, fallback: fallback)
        pref.setRoot(URL(fileURLWithPath: "/tmp/elsewhere"))
        pref.reset()
        XCTAssertEqual(pref.root, fallback)
    }

    func testSubdirectoryComposesPath() {
        let pref = StoragePreference(defaults: defaults, fallback: URL(fileURLWithPath: "/tmp/dump"))
        XCTAssertEqual(pref.subdirectory(.inbox).path, "/tmp/dump/inbox")
        XCTAssertEqual(pref.subdirectory(.pdfs).path, "/tmp/dump/pdfs")
    }
}

import Carbon.HIToolbox
import XCTest
@testable import Dump

final class HotkeyPreferenceStoreTests: XCTestCase {
    func testDefaultsReadBuiltInBindings() {
        let defaults = makeDefaults()
        let store = HotkeyPreferenceStore(defaults: defaults)

        XCTAssertEqual(store.binding(for: .capture), .defaultCapture)
        XCTAssertEqual(store.binding(for: .query), .defaultQuery)
        XCTAssertEqual(store.binding(for: .queue), .defaultQueue)
        XCTAssertNil(store.binding(for: .meeting))
    }

    func testCustomBindingPersists() throws {
        let defaults = makeDefaults()
        let custom = try XCTUnwrap(HotkeyManager.Binding(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | optionKey)
        ))

        HotkeyPreferenceStore(defaults: defaults).set(custom, for: .capture)
        let reloaded = HotkeyPreferenceStore(defaults: defaults)

        XCTAssertEqual(reloaded.binding(for: .capture), custom)
    }

    func testDisablePersists() {
        let defaults = makeDefaults()

        HotkeyPreferenceStore(defaults: defaults).disable(.query)
        let reloaded = HotkeyPreferenceStore(defaults: defaults)

        XCTAssertNil(reloaded.binding(for: .query))
    }

    func testResetFallsBackToDefault() throws {
        let defaults = makeDefaults()
        let store = HotkeyPreferenceStore(defaults: defaults)
        let custom = try XCTUnwrap(HotkeyManager.Binding(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | optionKey)
        ))

        store.set(custom, for: .capture)
        store.reset(.capture)

        XCTAssertEqual(store.binding(for: .capture), .defaultCapture)
        XCTAssertFalse(store.hasCustomValue(for: .capture))
    }

    func testConflictChecksEffectiveBindings() throws {
        let defaults = makeDefaults()
        let store = HotkeyPreferenceStore(defaults: defaults)
        let queryDefault = try XCTUnwrap(store.binding(for: .query))

        XCTAssertEqual(store.conflictingAction(for: queryDefault, excluding: .capture), .query)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

import AppKit
@preconcurrency import HotKey
import Carbon.HIToolbox

/// Registers global hotkeys for the capture and query windows. Wraps the
/// `HotKey` package so the rest of the app sees a plain action callback —
/// makes the manager swappable for a test double.
@MainActor
public final class HotkeyManager {
    public struct Binding: Equatable, Sendable {
        public let key: Key
        public let modifiers: NSEvent.ModifierFlags

        public init(key: Key, modifiers: NSEvent.ModifierFlags) {
            self.key = key
            self.modifiers = modifiers
        }

        public static let defaultCapture = Binding(key: .d, modifiers: [.command, .shift])
        public static let defaultQuery = Binding(key: .f, modifiers: [.command, .shift])
        public static let defaultQueue = Binding(key: .t, modifiers: [.command, .shift])
    }

    public enum Action: Hashable, Sendable {
        case capture, query, queue, meeting
    }

    private var registrations: [Action: HotKey] = [:]
    private var handlers: [Action: @MainActor () -> Void] = [:]

    public init() {}

    public func register(_ action: Action, binding: Binding, handler: @escaping @MainActor () -> Void) {
        registrations[action] = nil
        let hk = HotKey(key: binding.key, modifiers: binding.modifiers)
        hk.keyDownHandler = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handlers[action]?()
            }
        }
        registrations[action] = hk
        handlers[action] = handler
    }

    public func unregister(_ action: Action) {
        registrations[action] = nil
        handlers[action] = nil
    }

    public func unregisterAll() {
        registrations.removeAll()
        handlers.removeAll()
    }

    public var registeredActions: Set<Action> {
        Set(registrations.keys)
    }
}

import AppKit
@preconcurrency import HotKey
import Carbon.HIToolbox

/// Registers global hotkeys for the app's menu-bar actions. Wraps the
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

        public init?(keyCode: UInt32, carbonModifiers: UInt32) {
            guard let key = Key(carbonKeyCode: keyCode) else { return nil }
            self.init(key: key, modifiers: NSEvent.ModifierFlags(carbonFlags: carbonModifiers))
        }

        public init?(event: NSEvent) {
            guard let key = Key(carbonKeyCode: UInt32(event.keyCode)),
                  !key.isModifierOnly
            else {
                return nil
            }
            let modifiers = event.modifierFlags.supportedHotkeyModifiers
            guard !modifiers.isEmpty || key.allowsBareHotkey else { return nil }
            self.init(key: key, modifiers: modifiers)
        }

        public var keyCode: UInt32 { key.carbonKeyCode }
        public var carbonModifiers: UInt32 { modifiers.carbonFlags }
        public var displayString: String {
            KeyCombo(key: key, modifiers: modifiers).description
        }

        /// Combos macOS itself owns; registering them as a global hotkey
        /// would either shadow the system shortcut everywhere (Cmd+Q) or
        /// silently fail to register (Cmd+Space).
        public var isSystemReserved: Bool {
            let reserved: [(Key, NSEvent.ModifierFlags)] = [
                (.q, .command), (.w, .command), (.h, .command), (.m, .command),
                (.tab, .command), (.space, .command), (.escape, [.command, .option]),
                (.three, [.command, .shift]), (.four, [.command, .shift]), (.five, [.command, .shift]),
            ]
            return reserved.contains { key == $0.0 && modifiers == $0.1 }
        }

        public static let defaultCapture = Binding(key: .d, modifiers: [.command, .shift])
        public static let defaultQuery = Binding(key: .f, modifiers: [.command, .shift])
        public static let defaultQueue = Binding(key: .t, modifiers: [.command, .shift])
    }

    public enum Action: String, CaseIterable, Hashable, Identifiable, Sendable {
        case capture, query, queue, meeting

        public var id: Self { self }

        public static let configurableActions: [Action] = [.capture, .query, .queue, .meeting]

        public var title: String {
            switch self {
            case .capture: return "Capture"
            case .query: return "Query"
            case .queue: return "Queue"
            case .meeting: return "New meeting note"
            }
        }

        public var defaultBinding: Binding? {
            switch self {
            case .capture: return .defaultCapture
            case .query: return .defaultQuery
            case .queue: return .defaultQueue
            case .meeting: return nil
            }
        }
    }

    private var registrations: [Action: HotKey] = [:]
    private var handlers: [Action: @MainActor () -> Void] = [:]

    public init() {}

    @discardableResult
    public func register(_ action: Action, binding: Binding, handler: @escaping @MainActor () -> Void) -> Bool {
        registrations[action] = nil
        handlers[action] = nil
        // The HotKey package discards RegisterEventHotKey's OSStatus, so
        // probe first with the SAME non-exclusive options (0) it uses —
        // the probe fails exactly when the real registration would
        // (exclusive holder elsewhere, invalid combo). Do NOT probe with
        // kEventHotKeyExclusive: that also fails against non-exclusive
        // holders that coexist fine with Dump today.
        var probe: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.carbonModifiers,
            EventHotKeyID(signature: OSType(0x44554D50) /* 'DUMP' */, id: 0),
            GetEventDispatcherTarget(), 0, &probe
        )
        guard status == noErr, let acquired = probe else {
            DiagnosticLog.event(.error, category: "hotkeys", "hotkey registration failed", metadata: [
                "action": action.rawValue,
                "binding": binding.displayString,
                "status": String(status),
            ])
            return false
        }
        UnregisterEventHotKey(acquired)

        let hk = HotKey(key: binding.key, modifiers: binding.modifiers)
        hk.keyDownHandler = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handlers[action]?()
            }
        }
        registrations[action] = hk
        handlers[action] = handler
        return true
    }

    public func unregister(_ action: Action) {
        registrations[action] = nil
        handlers[action] = nil
    }

    public func unregisterAll() {
        registrations.removeAll()
        handlers.removeAll()
    }

    /// Pauses (or resumes) every live-registered hotkey without unregistering
    /// them, so recording a new combo in Settings can't be shadowed by a
    /// combo that's already bound to another action.
    public func setPaused(_ paused: Bool) {
        for hotKey in registrations.values { hotKey.isPaused = paused }
    }

    public var registeredActions: Set<Action> {
        Set(registrations.keys)
    }
}

private extension NSEvent.ModifierFlags {
    var supportedHotkeyModifiers: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}

private extension Key {
    var isModifierOnly: Bool {
        switch self {
        case .command, .rightCommand, .option, .rightOption, .control, .rightControl,
             .shift, .rightShift, .function, .capsLock:
            return true
        default:
            return false
        }
    }

    var allowsBareHotkey: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return true
        default:
            return false
        }
    }
}

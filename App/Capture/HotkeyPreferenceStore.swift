import AppKit
import Combine
import Foundation

public final class HotkeyPreferenceStore: ObservableObject {
    public enum DefaultsKey {
        public static func keyCode(for action: HotkeyManager.Action) -> String {
            "dump.hotkey.\(action.rawValue).keyCode"
        }

        public static func modifiers(for action: HotkeyManager.Action) -> String {
            "dump.hotkey.\(action.rawValue).modifiers"
        }

        public static func disabled(for action: HotkeyManager.Action) -> String {
            "dump.hotkey.\(action.rawValue).disabled"
        }
    }

    @Published public private(set) var revision = 0

    private let defaults: UserDefaults
    private var customBindings: [HotkeyManager.Action: HotkeyManager.Binding] = [:]
    private var disabledActions: Set<HotkeyManager.Action> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func binding(for action: HotkeyManager.Action) -> HotkeyManager.Binding? {
        if disabledActions.contains(action) { return nil }
        return customBindings[action] ?? action.defaultBinding
    }

    public func set(_ binding: HotkeyManager.Binding, for action: HotkeyManager.Action) {
        if binding == action.defaultBinding {
            reset(action)
            return
        }

        customBindings[action] = binding
        disabledActions.remove(action)
        defaults.set(Int(binding.keyCode), forKey: DefaultsKey.keyCode(for: action))
        defaults.set(Int(binding.carbonModifiers), forKey: DefaultsKey.modifiers(for: action))
        defaults.removeObject(forKey: DefaultsKey.disabled(for: action))
        revision += 1
    }

    public func disable(_ action: HotkeyManager.Action) {
        customBindings.removeValue(forKey: action)
        disabledActions.insert(action)
        defaults.removeObject(forKey: DefaultsKey.keyCode(for: action))
        defaults.removeObject(forKey: DefaultsKey.modifiers(for: action))
        defaults.set(true, forKey: DefaultsKey.disabled(for: action))
        revision += 1
    }

    public func reset(_ action: HotkeyManager.Action) {
        customBindings.removeValue(forKey: action)
        disabledActions.remove(action)
        defaults.removeObject(forKey: DefaultsKey.keyCode(for: action))
        defaults.removeObject(forKey: DefaultsKey.modifiers(for: action))
        defaults.removeObject(forKey: DefaultsKey.disabled(for: action))
        revision += 1
    }

    public func resetAll() {
        for action in HotkeyManager.Action.configurableActions {
            customBindings.removeValue(forKey: action)
            disabledActions.remove(action)
            defaults.removeObject(forKey: DefaultsKey.keyCode(for: action))
            defaults.removeObject(forKey: DefaultsKey.modifiers(for: action))
            defaults.removeObject(forKey: DefaultsKey.disabled(for: action))
        }
        revision += 1
    }

    public func hasCustomValue(for action: HotkeyManager.Action) -> Bool {
        disabledActions.contains(action) || customBindings[action] != nil
    }

    public func conflictingAction(
        for binding: HotkeyManager.Binding,
        excluding action: HotkeyManager.Action
    ) -> HotkeyManager.Action? {
        HotkeyManager.Action.configurableActions.first { candidate in
            candidate != action && self.binding(for: candidate) == binding
        }
    }

    private func load() {
        for action in HotkeyManager.Action.configurableActions {
            if defaults.bool(forKey: DefaultsKey.disabled(for: action)) {
                disabledActions.insert(action)
                continue
            }

            guard let keyCode = defaults.object(forKey: DefaultsKey.keyCode(for: action)) as? NSNumber else {
                continue
            }
            let modifiers = defaults.object(forKey: DefaultsKey.modifiers(for: action)) as? NSNumber
            if let binding = HotkeyManager.Binding(
                keyCode: keyCode.uint32Value,
                carbonModifiers: modifiers?.uint32Value ?? 0
            ) {
                customBindings[action] = binding
            }
        }
    }
}

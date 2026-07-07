import Foundation

/// User-configurable root directory for all Dump output. Sources of truth:
/// `UserDefaults` -> fallback to `~/Dump/`.
public final class StoragePreference: @unchecked Sendable {
    public static let defaultsKey = "dump.storagePath"

    public static let shared = StoragePreference()

    private let defaults: UserDefaults
    private let fallback: URL

    public init(defaults: UserDefaults = .standard,
                fallback: URL? = nil) {
        self.defaults = defaults
        self.fallback = fallback ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Dump", isDirectory: true)
    }

    public var root: URL {
        if let path = defaults.string(forKey: Self.defaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fallback
    }

    public func setRoot(_ url: URL) {
        defaults.set(url.path, forKey: Self.defaultsKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public func subdirectory(_ name: Subdir) -> URL {
        root.appendingPathComponent(name.rawValue, isDirectory: true)
    }

    public enum Subdir: String, CaseIterable, Sendable {
        case inbox, pdfs, meetings, code
    }
}

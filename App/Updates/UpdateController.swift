import Foundation
import OSLog
import Sparkle

/// Thin wrapper around Sparkle. Built so a fresh checkout boots cleanly even
/// when `SUFeedURL` / `SUPublicEDKey` still hold the placeholder values from
/// `project.yml`. Sparkle's auto-startup is deferred until those Info.plist
/// keys point at a real appcast + Ed25519 public key; otherwise we keep the
/// updater constructed-but-stopped so the menu item stays callable without
/// throwing a "The updater failed to start" alert at launch.
@MainActor
public final class UpdateController: NSObject {
    private let controller: SPUStandardUpdaterController
    private let log = Logger(subsystem: "com.joshmyatt.dump", category: "updater")
    public let isConfigured: Bool

    public override init() {
        let configured = Self.hasUsableSparkleConfig()
        self.isConfigured = configured
        controller = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        if !configured {
            log.info("sparkle: skipping auto-start; SUFeedURL/SUPublicEDKey not set")
        }
    }

    public func checkForUpdates() {
        guard isConfigured else {
            log.info("sparkle: ignoring check; updater not configured")
            return
        }
        controller.checkForUpdates(nil)
    }

    public var automaticChecksEnabled: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set {
            guard isConfigured else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private static func hasUsableSparkleConfig() -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = (info["SUFeedURL"] as? String) ?? ""
        let publicKey = (info["SUPublicEDKey"] as? String) ?? ""
        let isPlaceholderKey = publicKey.isEmpty || publicKey.hasPrefix("REPLACE_")
        let isPlaceholderURL = feedURL.isEmpty || feedURL.contains("dump.example")
        return !isPlaceholderKey && !isPlaceholderURL
    }
}

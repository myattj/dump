import Foundation
import OSLog
import Sparkle

/// Thin wrapper around Sparkle. Auto-startup is deferred until the Info.plist
/// contains a usable appcast URL and Ed25519 public key; otherwise the updater
/// remains constructed but stopped, avoiding a launch-time configuration
/// alert while keeping the menu action safe to call.
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

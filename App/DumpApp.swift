import SwiftUI
import AppKit

@main
struct DumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Dump", systemImage: "tray.and.arrow.down.fill") {
            DumpMenu(coordinator: delegate.coordinator,
                     settings: delegate.settingsController,
                     onboarding: delegate.onboardingController)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: AppCoordinator
    let settingsController: SettingsWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let c = AppCoordinator()
        self.coordinator = c
        self.settingsController = SettingsWindowController(coordinator: c)
        self.onboardingController = OnboardingWindowController(coordinator: c)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        onboardingController.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}

struct DumpMenu: View {
    let coordinator: AppCoordinator
    let settings: SettingsWindowController
    let onboarding: OnboardingWindowController

    var body: some View {
        Button("Capture (⇧⌘D)") { coordinator.capture.showQuick() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("Query (⇧⌘F)") { coordinator.query.show() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Queue (⇧⌘T)") { coordinator.queue.show() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        Button("New meeting note") { coordinator.capture.showMeeting() }
        Divider()
        Button("Import PDF…") { pickPDF() }
        Divider()
        Button("Settings…") { settings.show() }
        if coordinator.updates.isConfigured {
            Button("Check for Updates…") { coordinator.updates.checkForUpdates() }
        }
        Button("View Logs") { revealLogs() }
        Divider()
        Text("Dump v\(Bundle.main.shortVersion)")
        Button("Quit Dump") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func pickPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await coordinator.capture.importPDF(at: url) }
        }
    }

    private func revealLogs() {
        let url = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Dump", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

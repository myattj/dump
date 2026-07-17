import SwiftUI
import AppKit
import Combine

@main
struct DumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            DumpMenu(coordinator: delegate.coordinator,
                     settings: delegate.settingsController,
                     onboarding: delegate.onboardingController,
                     queueVM: delegate.coordinator.queue.viewModel,
                     hotkeys: delegate.coordinator.hotkeyPreferences)
        } label: {
            MenuBarIcon(capture: delegate.coordinator.capture,
                        queueVM: delegate.coordinator.queue.viewModel)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The status-bar glyph, doubling as the capture confirmation: when a
/// capture is written the tray briefly becomes a checkmark (and bounces
/// where the status bar allows symbol effects), then reverts. The cue fires
/// after the panel is already gone, so it costs the submit path nothing.
/// An overdue count rides alongside the glyph so the queue's urgency is
/// visible without opening anything.
struct MenuBarIcon: View {
    @ObservedObject var capture: CaptureCoordinator
    let queueVM: QueueViewModel
    @State private var overdueCount = 0
    @State private var showConfirmation = false
    @State private var revertTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The glyph swap is the informative (reduce-motion-safe) cue; the
        // bounce is decoration on top where the status bar allows it.
        let icon = Image(systemName: showConfirmation ? "checkmark" : "tray.and.arrow.down.fill")

        HStack(spacing: 3) {
            Group {
                if reduceMotion {
                    icon
                } else {
                    icon.symbolEffect(.bounce.up, value: capture.captureTick)
                }
            }
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .animation(Motion.snappy, value: showConfirmation)
            if overdueCount > 0 {
                Text("\(overdueCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: capture.captureTick) { _, _ in
            showConfirmation = true
            revertTask?.cancel()
            revertTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                showConfirmation = false
            }
        }
        .onReceive(queueVM.$summary.map(\.overdueCount).removeDuplicates()) { overdueCount = $0 }
    }

    private var accessibilityLabel: String {
        overdueCount > 0 ? "Dump, \(overdueCount) overdue" : "Dump"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: AppCoordinator
    let settingsController: SettingsWindowController
    let onboardingController: OnboardingWindowController
    let notificationRouter: NotificationRouter

    override init() {
        let c = AppCoordinator()
        self.coordinator = c
        self.settingsController = SettingsWindowController(coordinator: c)
        self.onboardingController = OnboardingWindowController(coordinator: c)
        self.notificationRouter = NotificationRouter(coordinator: c)
        super.init()
        // Installed here rather than in didFinishLaunching: the delegate
        // must be in place before launch completes to receive the response
        // that launched the app.
        notificationRouter.install()
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
    @ObservedObject var queueVM: QueueViewModel
    @ObservedObject var hotkeys: HotkeyPreferenceStore

    var body: some View {
        Button(menuTitle("Capture", action: .capture)) { coordinator.capture.showQuick() }
        Button(menuTitle("Query", action: .query)) { coordinator.query.show() }
        Button(menuTitle("Queue", action: .queue)) { coordinator.queue.show() }
        Button(menuTitle("New meeting note", action: .meeting)) { coordinator.capture.showMeeting() }
        if !queueVM.summary.topItems.isEmpty {
            Divider()
            Section("Up next") {
                ForEach(queueVM.summary.topItems) { item in
                    Menu {
                        Button("Complete") {
                            Task { await queueVM.complete(item) }
                        }
                        Button("Show in Queue") { coordinator.queue.reveal(id: item.id) }
                    } label: {
                        Text(menuLabel(for: item))
                    } primaryAction: {
                        coordinator.queue.reveal(id: item.id)
                    }
                }
            }
        }
        Divider()
        Button("Import PDF…") { pickPDF() }
        Divider()
        Button("Settings…") { settings.show() }
        if coordinator.updates.isConfigured {
            Button("Check for Updates…") { coordinator.updates.checkForUpdates() }
        }
        Menu("Diagnostics") {
            Button("Open App Log") { DiagnosticLog.openAppLog() }
            Button("Open Network Log") { DiagnosticLog.openNetworkLog() }
            Button("Open Logs Folder") { revealLogs() }
            Divider()
            Button("Copy Tail Command") { DiagnosticLog.copyTailCommandToPasteboard() }
        }
        Divider()
        Text("Dump v\(Bundle.main.shortVersion)")
        Button("Quit Dump") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuLabel(for item: QueueItem) -> String {
        var label = item.title
        if label.count > 44 {
            label = String(label.prefix(43)) + "…"
        }
        guard let due = item.priorityAt else { return label }
        if due <= Date() {
            return label + " · overdue"
        }
        return label + " · due \(due.formatted(.relative(presentation: .named)))"
    }

    private func menuTitle(_ title: String, action: HotkeyManager.Action) -> String {
        guard let binding = hotkeys.binding(for: action) else { return title }
        return "\(title) (\(binding.displayString))"
    }

    private func pickPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        // LSUIElement app: menu clicks don't activate us, so the modal panel would lack
        // key status. Same idiom as SettingsWindowController.show().
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await coordinator.capture.importPDF(at: url) }
        }
    }

    private func revealLogs() {
        DiagnosticLog.openLogsDirectory()
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

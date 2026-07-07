import SwiftUI
import AppKit

@MainActor
public final class OnboardingWindowController {
    public static let didCompleteDefaultsKey = "dump.onboarding.completed"

    private var window: NSWindow?
    private let coordinator: AppCoordinator
    private let defaults: UserDefaults

    public init(coordinator: AppCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
    }

    public var shouldShow: Bool {
        !defaults.bool(forKey: Self.didCompleteDefaultsKey)
    }

    public func showIfNeeded() {
        guard shouldShow else { return }
        show()
    }

    public func show() {
        if window == nil {
            let view = OnboardingView(coordinator: coordinator) { [weak self] in
                self?.complete()
            }
            let host = NSHostingController(rootView: view)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Welcome to Dump"
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func complete() {
        defaults.set(true, forKey: Self.didCompleteDefaultsKey)
        window?.close()
        window = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onFinish: @MainActor () -> Void
    @State private var step: Int = 0
    @State private var direction: Int = 1
    @State private var mode: ClassifierMode = .cloud
    @State private var apiKey: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topLeading) {
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: classifierStep
                    case 2: credentialsStep
                    default: doneStep
                    }
                }
                .id(step)
                .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer()
            HStack {
                if step > 0 {
                    Button("Back") { goBack() }
                        .transition(.opacity)
                }
                Spacer()
                Button(step >= 3 ? "Start" : "Next") {
                    if step >= 3 { onFinish() } else { goNext() }
                }
                .keyboardShortcut(.return)
            }
            .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: step > 0)
        }
        .padding(24)
        .frame(width: 540, height: 480)
    }

    private func goNext() {
        direction = 1
        withAnimation(resolved(Motion.bouncy, reduceMotion: reduceMotion)) { step += 1 }
    }

    private func goBack() {
        direction = -1
        withAnimation(resolved(Motion.bouncy, reduceMotion: reduceMotion)) { step -= 1 }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let shift: CGFloat = 32
        let forward = AnyTransition.asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: shift))
                .combined(with: .scale(scale: 0.98, anchor: .leading)),
            removal: .opacity
                .combined(with: .offset(x: -shift))
                .combined(with: .scale(scale: 0.98, anchor: .trailing))
        )
        let backward = AnyTransition.asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: -shift))
                .combined(with: .scale(scale: 0.98, anchor: .trailing)),
            removal: .opacity
                .combined(with: .offset(x: shift))
                .combined(with: .scale(scale: 0.98, anchor: .leading))
        )
        return direction >= 0 ? forward : backward
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dump").font(.largeTitle).bold()
            Text("Hit ⇧⌘D anywhere to capture a thought. Hit ⇧⌘F to ask questions across everything you've captured. Files live in plain markdown so you keep them forever.")
        }
    }

    private var classifierStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how to classify").font(.title2).bold()
            Picker("Mode", selection: $mode) {
                Text("Cloud (Claude Haiku — fastest)").tag(ClassifierMode.cloud)
                Text("Local (Ollama — private)").tag(ClassifierMode.local)
            }
            .pickerStyle(.radioGroup)
            Text(mode == .cloud
                 ? "Your entries are sent to Anthropic only for classification. You can switch modes any time."
                 : "Everything stays on your Mac. Requires Ollama installed — we'll check next.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .cloud {
                Text("Paste your Anthropic API key").font(.title2).bold()
                LabeledContent("API key") {
                    SecureField("Anthropic API key", text: $apiKey)
                        .labelsHidden()
                }
                Text("Stored in your macOS Keychain, only on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Ollama check").font(.title2).bold()
                Text("Install Ollama separately and pull the model you want to use. You can change the Ollama host and model in Settings.")
            }
        }
        .onDisappear {
            if mode == .cloud { try? KeychainStore.shared.set(apiKey, for: .anthropicAPIKey) }
            Task { await coordinator.classifierHub.setMode(mode) }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're ready").font(.title).bold()
            Text("Try ⇧⌘D right now and type 'remind me to drink water in 30 minutes'.")
        }
    }
}

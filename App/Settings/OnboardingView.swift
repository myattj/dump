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
        let isFirstShow = window == nil
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
        guard let window else { return }
        if isFirstShow {
            // Same entrance grammar as the floating panels: a quick
            // ease-out fade (reduce motion just shortens it).
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduced ? 0.12 : DumpUI.Motion.Window.showFadeDuration
                ctx.timingFunction = DumpUI.Motion.Window.easeOutExpo
                window.animator().alphaValue = 1
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func complete() {
        defaults.set(true, forKey: Self.didCompleteDefaultsKey)
        guard let window else { return }
        // Exit on the shared dismissal curve instead of slamming shut.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DumpUI.Motion.Window.hideFadeDuration
            ctx.timingFunction = DumpUI.Motion.Window.easeInExit
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.close()
                self.window = nil
            }
        })
    }
}

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    let onFinish: @MainActor () -> Void
    @State private var step: Int = 0
    @State private var direction: Int = 1
    @State private var mode: ClassifierMode = .cloud
    @State private var apiKey: String = ""
    @State private var customBaseURL: String = ""
    @State private var customClassifierModel: String = ""
    @State private var customSynthesizerModel: String = ""
    @State private var customAPIKey: String = ""
    @State private var ollamaBaseURL: String = ""
    @State private var ollamaModel: String = ""
    @State private var bedrockRegion: String = ""
    @State private var bedrockClassifierModelID: String = ""
    @State private var bedrockSynthesizerModelID: String = ""
    @State private var bedrockAccessKeyID: String = ""
    @State private var bedrockSecretAccessKey: String = ""
    @State private var bedrockSessionToken: String = ""
    @State private var finaleBounce = 0
    @Namespace private var stepDotNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let configStore = CustomLLMConfigStore.shared

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
                stepDots
                if step > 0 {
                    Button("Back") { goBack() }
                        .transition(.opacity)
                }
                Spacer()
                nextButton
            }
            .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: step)
        }
        .padding(24)
        .frame(width: 540, height: 480)
        .onAppear { loadProviderSettings() }
    }

    /// The persistent spatial anchor for the direction-aware slides: the
    /// active dot stretches and the accent highlight physically glides
    /// between positions.
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    // Under reduce motion the dots stay uniform and the
                    // highlight crossfades instead of stretching/gliding.
                    .frame(width: !reduceMotion && index == step ? 18 : 6, height: 6)
                    .overlay {
                        if index == step {
                            if reduceMotion {
                                Capsule().fill(Color.accentColor)
                            } else {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "activeStep", in: stepDotNamespace)
                            }
                        }
                    }
            }
        }
        .padding(.trailing, 10)
        .animation(resolved(Motion.interactive, reduceMotion: reduceMotion), value: step)
        .accessibilityLabel("Step \(step + 1) of 4")
    }

    @ViewBuilder
    private var nextButton: some View {
        if step >= 3 {
            Button("Start") { onFinish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .transition(.opacity)
        } else {
            Button("Next") { goNext() }
                .keyboardShortcut(.return)
                .transition(.opacity)
        }
    }

    private func goNext() {
        advance(by: 1)
    }

    private func goBack() {
        advance(by: -1)
    }

    /// Two-pass update: commit the new direction first, then change the
    /// step a runloop later — otherwise the outgoing view is removed with
    /// the previous direction's transition and Back exits the wrong way.
    private func advance(by delta: Int) {
        direction = delta
        Task { @MainActor in
            withAnimation(resolved(Motion.bouncy, reduceMotion: reduceMotion)) {
                step += delta
            }
        }
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
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .reveal(0, reduceMotion: reduceMotion)
            Text("Dump").font(.largeTitle).bold()
                .reveal(1, reduceMotion: reduceMotion)
            Text("Hit ⇧⌘D anywhere to capture a thought. Hit ⇧⌘F to ask questions across everything you've captured. Hit ⇧⌘T for your queue — anything with a date ranks itself by what's due. Files live in plain markdown so you keep them forever.")
                .reveal(2, reduceMotion: reduceMotion)
        }
    }

    private var classifierStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how to classify").font(.title2).bold()
                .reveal(0, reduceMotion: reduceMotion)
            Picker("Mode", selection: $mode) {
                Text("Claude (Anthropic API)").tag(ClassifierMode.cloud)
                Text("OpenAI-compatible provider").tag(ClassifierMode.custom)
                Text("Amazon Bedrock").tag(ClassifierMode.bedrock)
                Text("Local (Ollama)").tag(ClassifierMode.local)
            }
            .pickerStyle(.radioGroup)
            .reveal(1, reduceMotion: reduceMotion)
            Text(modeDescription)
                .font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: mode)
                // Reserve space so the caption swap never reflows the
                // radio group above it.
                .frame(minHeight: 44, alignment: .topLeading)
                .reveal(2, reduceMotion: reduceMotion)
        }
    }

    private var modeDescription: String {
        switch mode {
        case .cloud:
            return "Use Anthropic's Messages API with a Claude model managed by Dump."
        case .custom:
            return "Use OpenAI, Azure OpenAI, OpenRouter, LiteLLM, vLLM, or another HTTPS endpoint that speaks Chat Completions."
        case .bedrock:
            return "Use AWS Bedrock Runtime with a model ID, inference profile ID, or ARN."
        case .local:
            return "Everything stays on your Mac. Requires Ollama installed with the model already pulled."
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .cloud:
                Text("Paste your Anthropic API key").font(.title2).bold()
                    .reveal(0, reduceMotion: reduceMotion)
                LabeledContent("API key") {
                    SecureField("Anthropic API key", text: $apiKey)
                        .labelsHidden()
                }
                .reveal(1, reduceMotion: reduceMotion)
                Text("Stored in your macOS Keychain, only on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                    .reveal(2, reduceMotion: reduceMotion)

            case .custom:
                Text("Configure your API provider").font(.title2).bold()
                    .reveal(0, reduceMotion: reduceMotion)
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $customBaseURL)
                        .labelsHidden()
                }
                .reveal(1, reduceMotion: reduceMotion)
                LabeledContent("Classifier model") {
                    TextField("Classifier model", text: $customClassifierModel)
                        .labelsHidden()
                }
                .reveal(2, reduceMotion: reduceMotion)
                LabeledContent("Ask model") {
                    TextField("Ask model", text: $customSynthesizerModel)
                        .labelsHidden()
                }
                .reveal(3, reduceMotion: reduceMotion)
                LabeledContent("API key") {
                    SecureField("API key", text: $customAPIKey)
                        .labelsHidden()
                }
                .reveal(4, reduceMotion: reduceMotion)
                Text("Works with OpenAI-compatible Chat Completions providers.")
                    .font(.caption).foregroundStyle(.secondary)
                    .reveal(5, reduceMotion: reduceMotion)

            case .bedrock:
                Text("Configure Bedrock").font(.title2).bold()
                    .reveal(0, reduceMotion: reduceMotion)
                LabeledContent("Region") {
                    TextField("Region", text: $bedrockRegion)
                        .labelsHidden()
                }
                .reveal(1, reduceMotion: reduceMotion)
                LabeledContent("Classifier model ID") {
                    TextField("Classifier model ID", text: $bedrockClassifierModelID)
                        .labelsHidden()
                }
                .reveal(2, reduceMotion: reduceMotion)
                LabeledContent("Ask model ID") {
                    TextField("Ask model ID", text: $bedrockSynthesizerModelID)
                        .labelsHidden()
                }
                .reveal(3, reduceMotion: reduceMotion)
                LabeledContent("Access key ID") {
                    TextField("Access key ID", text: $bedrockAccessKeyID)
                        .labelsHidden()
                }
                .reveal(4, reduceMotion: reduceMotion)
                LabeledContent("Secret access key") {
                    SecureField("Secret access key", text: $bedrockSecretAccessKey)
                        .labelsHidden()
                }
                .reveal(5, reduceMotion: reduceMotion)
                LabeledContent("Session token") {
                    SecureField("Session token", text: $bedrockSessionToken)
                        .labelsHidden()
                }
                .reveal(6, reduceMotion: reduceMotion)

            case .local:
                Text("Ollama check").font(.title2).bold()
                    .reveal(0, reduceMotion: reduceMotion)
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $ollamaBaseURL)
                        .labelsHidden()
                }
                .reveal(1, reduceMotion: reduceMotion)
                LabeledContent("Model") {
                    TextField("Model", text: $ollamaModel)
                        .labelsHidden()
                }
                .reveal(2, reduceMotion: reduceMotion)
                Text("Install Ollama separately and pull this model before capturing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .reveal(3, reduceMotion: reduceMotion)
            }
        }
        .onDisappear {
            persistSelectedProvider()
        }
    }

    private func loadProviderSettings() {
        apiKey = KeychainStore.shared.string(for: .anthropicAPIKey) ?? ""
        customBaseURL = configStore.baseURL.isEmpty ? ProviderConnect.openAIBaseURL : configStore.baseURL
        customClassifierModel = configStore.classifierModel.isEmpty ? ProviderConnect.openAIClassifierModel : configStore.classifierModel
        customSynthesizerModel = configStore.synthesizerModel.isEmpty ? ProviderConnect.openAISynthesizerModel : configStore.synthesizerModel
        customAPIKey = KeychainStore.shared.string(for: .customLLMAPIKey) ?? ""
        ollamaBaseURL = configStore.ollamaBaseURL
        ollamaModel = configStore.ollamaModel
        bedrockRegion = configStore.bedrockRegion.isEmpty ? ProviderConnect.bedrockRegion : configStore.bedrockRegion
        if configStore.bedrockClassifierModelID.isEmpty {
            bedrockClassifierModelID = ProviderConnect.bedrockClassifierModelID
        } else {
            bedrockClassifierModelID = configStore.bedrockClassifierModelID
        }
        if configStore.bedrockSynthesizerModelID.isEmpty {
            bedrockSynthesizerModelID = ProviderConnect.bedrockSynthesizerModelID
        } else {
            bedrockSynthesizerModelID = configStore.bedrockSynthesizerModelID
        }
        bedrockAccessKeyID = KeychainStore.shared.string(for: .bedrockAccessKeyID) ?? ""
        bedrockSecretAccessKey = KeychainStore.shared.string(for: .bedrockSecretAccessKey) ?? ""
        bedrockSessionToken = KeychainStore.shared.string(for: .bedrockSessionToken) ?? ""
    }

    private func persistSelectedProvider() {
        switch mode {
        case .cloud:
            try? KeychainStore.shared.set(apiKey, for: .anthropicAPIKey)
        case .custom:
            let synthesizerModel: String
            if customSynthesizerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                synthesizerModel = customClassifierModel
            } else {
                synthesizerModel = customSynthesizerModel
            }
            configStore.baseURL = customBaseURL
            configStore.classifierModel = customClassifierModel
            configStore.synthesizerModel = synthesizerModel
            try? KeychainStore.shared.set(customAPIKey, for: .customLLMAPIKey)
        case .bedrock:
            let synthesizerModelID: String
            if bedrockSynthesizerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                synthesizerModelID = bedrockClassifierModelID
            } else {
                synthesizerModelID = bedrockSynthesizerModelID
            }
            configStore.bedrockRegion = bedrockRegion
            configStore.bedrockClassifierModelID = bedrockClassifierModelID
            configStore.bedrockSynthesizerModelID = synthesizerModelID
            try? KeychainStore.shared.set(bedrockAccessKeyID, for: .bedrockAccessKeyID)
            try? KeychainStore.shared.set(bedrockSecretAccessKey, for: .bedrockSecretAccessKey)
            try? KeychainStore.shared.set(bedrockSessionToken, for: .bedrockSessionToken)
        case .local:
            configStore.ollamaBaseURL = ollamaBaseURL
            configStore.ollamaModel = ollamaModel
        }
        Task { await coordinator.classifierHub.setMode(mode) }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            finaleSeal
                .reveal(0, reduceMotion: reduceMotion)
            Text("You're ready").font(.title).bold()
                .reveal(1, reduceMotion: reduceMotion)
            HStack(spacing: 6) {
                keyCap("⇧")
                keyCap("⌘")
                keyCap("D")
                Text("captures a thought from anywhere")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .reveal(2, reduceMotion: reduceMotion)
            HStack(spacing: 6) {
                keyCap("⇧")
                keyCap("⌘")
                keyCap("T")
                Text("opens your queue, ranked by what's due")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .reveal(3, reduceMotion: reduceMotion)
            Text("Try it right now — type 'remind me to drink water in 30 minutes'.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .reveal(4, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private var finaleSeal: some View {
        let seal = Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(.tint)
            .symbolRenderingMode(.hierarchical)

        if reduceMotion {
            seal
        } else {
            seal
                .symbolEffect(.bounce.up, value: finaleBounce)
                .onAppear { finaleBounce += 1 }
        }
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DumpUI.Radius.keyCap))
    }
}

/// Staggered entrance for onboarding step content: each indexed element
/// drifts up 10pt and fades in, 60ms after the previous one. Under reduce
/// motion the stagger collapses to a single quick fade with no offset.
private struct OnboardingReveal: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .onAppear {
                let animation = resolved(Motion.bouncy, reduceMotion: reduceMotion)
                withAnimation(reduceMotion ? animation : animation.delay(Double(index) * 0.06)) {
                    appeared = true
                }
            }
    }
}

private extension View {
    func reveal(_ index: Int, reduceMotion: Bool) -> some View {
        modifier(OnboardingReveal(index: index, reduceMotion: reduceMotion))
    }
}

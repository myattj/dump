import SwiftUI
import AppKit
import Carbon.HIToolbox

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public func show() {
        if window == nil {
            let view = SettingsView(coordinator: coordinator)
            let host = NSHostingController(rootView: view)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false // controller retains the window; AppKit must not release it on close
            w.title = "Dump Settings"
            w.contentViewController = host
            w.setFrameAutosaveName("dump.settings")
            // Non-resizable styleMask: the plain autosave restore skips such windows,
            // so force-apply the saved frame; center only on the very first open.
            if !w.setFrameUsingName("dump.settings", force: true) {
                w.center()
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Same entrance grammar as onboarding and the floating panels
            // (reduce motion just shortens the fade).
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduced ? 0.12 : DumpUI.Motion.Window.showFadeDuration
                ctx.timingFunction = DumpUI.Motion.Window.easeOutExpo
                window.animator().alphaValue = 1
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(storage: coordinator.storage,
                                 hotkeys: coordinator.hotkeyPreferences,
                                 hotkeyManager: coordinator.hotkeys)
                .tabItem { Label("General", systemImage: "gearshape") }
            ClassifierSettingsView(hub: coordinator.classifierHub)
                .tabItem { Label("Classifier", systemImage: "brain") }
            CodeCollectionsSettingsView(daemon: coordinator.daemon)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            UpdatesSettingsView(controller: coordinator.updates)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }
}

struct GeneralSettingsView: View {
    let storage: StoragePreference
    @ObservedObject var hotkeys: HotkeyPreferenceStore
    let hotkeyManager: HotkeyManager
    @State private var path: String = ""
    @State private var recordingAction: HotkeyManager.Action?
    @State private var hotkeyMessage: String?

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    LabeledContent("Storage directory") {
                        TextField("Storage directory", text: $path)
                            .labelsHidden()
                    }
                    Button("Choose…") { pickFolder() }
                    Button("Reset") {
                        storage.reset()
                        path = storage.root.path
                    }
                }
            }
            Section("Hotkeys") {
                ForEach(HotkeyManager.Action.configurableActions) { action in
                    hotkeyRow(for: action)
                }
                if let hotkeyMessage {
                    Text(hotkeyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { path = storage.root.path }
        .onChange(of: recordingAction) { _, newValue in
            hotkeyManager.setPaused(newValue != nil)
        }
    }

    private func hotkeyRow(for action: HotkeyManager.Action) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            Button {
                recordingAction = action
                hotkeyMessage = nil
            } label: {
                Text(hotkeyTitle(for: action))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 96)
            }
            .background(
                HotkeyCaptureView(
                    isActive: recordingAction == action,
                    onKeyDown: { event in record(event, for: action) },
                    onCancel: {
                        recordingAction = nil
                        hotkeyMessage = nil
                    }
                )
                .frame(width: 0, height: 0)
            )
            Button("Clear") {
                if hotkeys.binding(for: action) != nil {
                    hotkeys.disable(action)
                }
                if recordingAction == action { recordingAction = nil }
                hotkeyMessage = nil
            }
            Button("Reset") {
                hotkeys.reset(action)
                if recordingAction == action { recordingAction = nil }
                hotkeyMessage = nil
            }
            .disabled(!hotkeys.hasCustomValue(for: action))
        }
    }

    private func hotkeyTitle(for action: HotkeyManager.Action) -> String {
        if recordingAction == action { return "Press keys" }
        return hotkeys.binding(for: action)?.displayString ?? "Off"
    }

    private func record(_ event: NSEvent, for action: HotkeyManager.Action) {
        let supportedModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isBareDelete = supportedModifiers.isEmpty
            && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete))
        if isBareDelete {
            hotkeys.disable(action)
            recordingAction = nil
            hotkeyMessage = nil
            return
        }

        guard let binding = HotkeyManager.Binding(event: event) else {
            NSSound.beep()
            hotkeyMessage = "Use a modifier plus a key, or a function key."
            return
        }

        if binding.isSystemReserved {
            NSSound.beep()
            hotkeyMessage = "\(binding.displayString) is reserved by macOS."
            return
        }

        if let conflict = hotkeys.conflictingAction(for: binding, excluding: action) {
            NSSound.beep()
            hotkeyMessage = "\(binding.displayString) is already used for \(conflict.title)."
            return
        }

        hotkeys.set(binding, for: action)
        recordingAction = nil
        hotkeyMessage = nil
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            storage.setRoot(url)
            path = url.path
        }
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onCancel = onCancel
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if nsView.window?.firstResponder === nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nil)
            }
        }
    }

    final class KeyCaptureNSView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return
            }
            onKeyDown?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            keyDown(with: event)
            return true
        }

        // End recording whenever capture loses first responder (window
        // closed or clicked away mid-recording), so hotkeys can never stay
        // paused; the cached Settings window only orders out on close, so
        // onDisappear is not a reliable signal.
        override func resignFirstResponder() -> Bool {
            onCancel?()
            return super.resignFirstResponder()
        }
    }
}

struct ClassifierSettingsView: View {
    let hub: ClassifierHub
    @State private var mode: ClassifierMode = .cloud
    @State private var apiKey: String = ""
    @State private var anthropicEndpoint: String = ""
    @State private var planBackedProvider: PlanBackedProvider = .claudeCode
    @State private var claudeCodeExecutablePath: String = ""
    @State private var codexExecutablePath: String = ""
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
    @State private var savedFlash: FlashMessage?
    @State private var flashTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct FlashMessage: Equatable {
        let text: String
        let isSuccess: Bool
    }

    private let configStore = CustomLLMConfigStore.shared

    /// Mode sections drift up as they arrive; the outgoing one just fades.
    private var modeSectionTransition: AnyTransition {
        reducedTransition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity
            ),
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Form {
            Picker("Mode", selection: $mode) {
                Text("Cloud (Claude)").tag(ClassifierMode.cloud)
                Text("Plans (Codex/Claude)").tag(ClassifierMode.subscription)
                Text("Local (Ollama)").tag(ClassifierMode.local)
                Text("OpenAI-compatible").tag(ClassifierMode.custom)
                Text("Amazon Bedrock").tag(ClassifierMode.bedrock)
            }
            .onChange(of: mode) { _, newValue in
                Task { await hub.setMode(newValue) }
            }

            if mode == .cloud {
                Group {
                Section("Anthropic API key") {
                    LabeledContent("API key") {
                        SecureField("Anthropic API key", text: $apiKey)
                            .labelsHidden()
                    }
                    HStack {
                        Button("Open key page") {
                            open(ProviderConnect.anthropicAPIKeysURL)
                        }
                        Button("Use ANTHROPIC_API_KEY") {
                            importAnthropicEnvironmentKey()
                        }
                        Button("Save API key") {
                            do {
                                try KeychainStore.shared.set(apiKey, for: .anthropicAPIKey)
                                flash("Saved")
                            } catch {
                                flash("Couldn't save to Keychain", success: false)
                            }
                        }
                    }
                }
                Section("Anthropic endpoint (optional)") {
                    LabeledContent("Endpoint URL") {
                        TextField("Endpoint URL", text: $anthropicEndpoint)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Override to route Claude through a corporate HTTPS proxy that speaks the Anthropic protocol. Leave blank for the default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save endpoint") {
                        configStore.anthropicEndpoint = anthropicEndpoint
                        flash("Saved")
                    }
                }
                }
                .transition(modeSectionTransition)
            } else if mode == .subscription {
                Group {
                Section("Plan-backed local CLI") {
                    Picker("Provider", selection: $planBackedProvider) {
                        ForEach(PlanBackedProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Uses the official CLI login on this Mac. Dump auto-detects common Homebrew and shell PATH locations, then stores CLI paths only.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Detect CLIs") {
                            detectPlanBackedExecutables()
                        }
                        Button("Open Claude auth") {
                            open(ProviderConnect.claudeCodeAuthURL)
                        }
                        Button("Open Codex auth") {
                            open(ProviderConnect.codexAuthURL)
                        }
                    }
                }
                Section("CLI paths") {
                    LabeledContent("Claude CLI") {
                        TextField("Claude CLI", text: $claudeCodeExecutablePath)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Codex CLI") {
                        TextField("Codex CLI", text: $codexExecutablePath)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Save plan settings") {
                        persistPlanBackedSettings()
                        flash("Saved")
                    }
                }
                }
                .transition(modeSectionTransition)
            } else if mode == .local {
                Group {
                Section("Ollama") {
                    LabeledContent("Base URL") {
                        TextField("Base URL", text: $ollamaBaseURL)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Model") {
                        TextField("Model", text: $ollamaModel)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Used for both classification and Ask mode. The model must already be available in Ollama.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save Ollama settings") {
                        configStore.ollamaBaseURL = ollamaBaseURL
                        configStore.ollamaModel = ollamaModel
                        flash("Saved")
                    }
                }
                }
                .transition(modeSectionTransition)
            } else if mode == .custom {
                Group {
                Section("OpenAI-compatible HTTPS endpoint") {
                    HStack {
                        Button("Connect OpenAI") {
                            configureOpenAIDefaults()
                            open(ProviderConnect.openAIAPIKeysURL)
                        }
                        Button("Use OPENAI_API_KEY") {
                            importOpenAIEnvironmentKey()
                        }
                    }
                    LabeledContent("Base URL") {
                        TextField("Base URL", text: $customBaseURL)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("OpenAI-compatible Chat Completions. Works with Azure OpenAI, vLLM, LiteLLM, OpenRouter, and most corporate gateways.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Classifier model") {
                        TextField("Classifier model", text: $customClassifierModel)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Synthesizer model") {
                        TextField("Synthesizer model", text: $customSynthesizerModel)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API key") {
                        SecureField("API key", text: $customAPIKey)
                            .labelsHidden()
                    }
                    Button("Save OpenAI-compatible settings") {
                        configStore.baseURL = customBaseURL
                        configStore.classifierModel = customClassifierModel
                        configStore.synthesizerModel = customSynthesizerModel
                        do {
                            try KeychainStore.shared.set(customAPIKey, for: .customLLMAPIKey)
                            flash("Saved")
                        } catch {
                            flash("Couldn't save to Keychain", success: false)
                        }
                    }
                }
                }
                .transition(modeSectionTransition)
            } else if mode == .bedrock {
                Group {
                Section("Amazon Bedrock Runtime") {
                    HStack {
                        Button("Open model access") {
                            open(ProviderConnect.bedrockModelAccessURL)
                        }
                        Button("Use Bedrock defaults") {
                            configureBedrockDefaults()
                        }
                    }
                    LabeledContent("Region") {
                        TextField("Region", text: $bedrockRegion)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Classifier model ID") {
                        TextField("Classifier model ID", text: $bedrockClassifierModelID)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Synthesizer model ID") {
                        TextField("Synthesizer model ID", text: $bedrockSynthesizerModelID)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Uses Bedrock Converse, so model IDs, inference profile IDs, and ARNs are supported when the model supports messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("AWS credentials") {
                    LabeledContent("Access key ID") {
                        TextField("Access key ID", text: $bedrockAccessKeyID)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Secret access key") {
                        SecureField("Secret access key", text: $bedrockSecretAccessKey)
                            .labelsHidden()
                    }
                    LabeledContent("Session token") {
                        SecureField("Session token", text: $bedrockSessionToken)
                            .labelsHidden()
                    }
                    Text("Credentials are stored in Keychain and used only to sign Bedrock Runtime requests.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Use AWS env vars") {
                            importBedrockEnvironmentCredentials()
                        }
                        Button("Save AWS credentials") {
                            if persistBedrockSettings() {
                                flash("Saved")
                            } else {
                                flash("Couldn't save to Keychain", success: false)
                            }
                        }
                    }
                }
                }
                .transition(modeSectionTransition)
            }

            if let savedFlash {
                Label(savedFlash.text, systemImage: savedFlash.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(savedFlash.isSuccess ? Color.green : Color.orange)
                    .transition(reducedTransition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                            removal: .opacity
                        ),
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .formStyle(.grouped)  // grouped Forms are List-backed and scroll; the default .columns style clips inside the fixed 640x560 window
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: mode)
        .task {
            self.mode = await hub.mode
            self.apiKey = KeychainStore.shared.string(for: .anthropicAPIKey) ?? ""
            self.anthropicEndpoint = configStore.anthropicEndpoint
            self.planBackedProvider = configStore.planBackedProvider
            self.claudeCodeExecutablePath = configStore.claudeCodeExecutablePath
            self.codexExecutablePath = configStore.codexExecutablePath
            if applyDetectedPlanBackedExecutables(overwriteExistingPaths: false) {
                persistPlanBackedSettings()
            }
            self.customBaseURL = configStore.baseURL
            self.customClassifierModel = configStore.classifierModel
            self.customSynthesizerModel = configStore.synthesizerModel
            self.customAPIKey = KeychainStore.shared.string(for: .customLLMAPIKey) ?? ""
            self.ollamaBaseURL = configStore.ollamaBaseURL
            self.ollamaModel = configStore.ollamaModel
            self.bedrockRegion = configStore.bedrockRegion.isEmpty ? ProviderConnect.bedrockRegion : configStore.bedrockRegion
            self.bedrockClassifierModelID = configStore.bedrockClassifierModelID.isEmpty ? ProviderConnect.bedrockClassifierModelID : configStore.bedrockClassifierModelID
            self.bedrockSynthesizerModelID = configStore.bedrockSynthesizerModelID.isEmpty ? ProviderConnect.bedrockSynthesizerModelID : configStore.bedrockSynthesizerModelID
            self.bedrockAccessKeyID = KeychainStore.shared.string(for: .bedrockAccessKeyID) ?? ""
            self.bedrockSecretAccessKey = KeychainStore.shared.string(for: .bedrockSecretAccessKey) ?? ""
            self.bedrockSessionToken = KeychainStore.shared.string(for: .bedrockSessionToken) ?? ""
        }
    }

    /// Confirmation flash with a proper lifecycle: springs in, cancels any
    /// previous countdown (repeated saves retarget instead of racing), and
    /// fades out after 1.5s.
    private func flash(_ msg: String, success: Bool = true) {
        flashTask?.cancel()
        withAnimation(resolved(Motion.bouncy, reduceMotion: reduceMotion)) {
            savedFlash = FlashMessage(text: msg, isSuccess: success)
        }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(resolved(Motion.exit, reduceMotion: reduceMotion)) {
                savedFlash = nil
            }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func importAnthropicEnvironmentKey() {
        guard let key = ProviderConnect.environmentValue(for: .anthropic) else {
            flash("No ANTHROPIC_API_KEY found", success: false)
            return
        }
        apiKey = key
        do {
            try KeychainStore.shared.set(key, for: .anthropicAPIKey)
            flash("Imported ANTHROPIC_API_KEY")
        } catch {
            flash("Couldn't save to Keychain", success: false)
        }
    }

    private func configureOpenAIDefaults() {
        customBaseURL = ProviderConnect.openAIBaseURL
        if customClassifierModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customClassifierModel = ProviderConnect.openAIClassifierModel
        }
        if customSynthesizerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customSynthesizerModel = ProviderConnect.openAISynthesizerModel
        }
        persistOpenAICompatibleSettings()
        flash("OpenAI defaults set")
    }

    private func importOpenAIEnvironmentKey() {
        guard let key = ProviderConnect.environmentValue(for: .openAI) else {
            flash("No OPENAI_API_KEY found", success: false)
            return
        }
        customAPIKey = key
        configureOpenAIDefaults()
        do {
            try KeychainStore.shared.set(key, for: .customLLMAPIKey)
            flash("Imported OPENAI_API_KEY")
        } catch {
            flash("Couldn't save to Keychain", success: false)
        }
    }

    private func detectPlanBackedExecutables() {
        let detection = PlanBackedExecutableResolver.detect()
        guard !detection.isEmpty else {
            flash("No local CLIs found", success: false)
            return
        }
        applyDetectedPlanBackedExecutables(detection, overwriteExistingPaths: true)
        persistPlanBackedSettings()
        flash("Detected local CLIs")
    }

    @discardableResult
    private func applyDetectedPlanBackedExecutables(
        _ detection: PlanBackedExecutableDetection = PlanBackedExecutableResolver.detect(),
        overwriteExistingPaths: Bool
    ) -> Bool {
        var didChange = false
        if shouldApplyDetectedPath(
            detection.claudeCodePath,
            currentPath: claudeCodeExecutablePath,
            overwriteExistingPaths: overwriteExistingPaths
        ) {
            claudeCodeExecutablePath = detection.claudeCodePath
            didChange = true
        }
        if shouldApplyDetectedPath(
            detection.codexPath,
            currentPath: codexExecutablePath,
            overwriteExistingPaths: overwriteExistingPaths
        ) {
            codexExecutablePath = detection.codexPath
            didChange = true
        }

        let availableProviders = PlanBackedProvider.allCases.filter { provider in
            !pathField(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !availableProviders.contains(planBackedProvider), let fallbackProvider = availableProviders.first {
            planBackedProvider = fallbackProvider
            didChange = true
        }
        return didChange
    }

    private func shouldApplyDetectedPath(
        _ detectedPath: String,
        currentPath: String,
        overwriteExistingPaths: Bool
    ) -> Bool {
        guard !detectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard overwriteExistingPaths || currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return currentPath != detectedPath
    }

    private func pathField(for provider: PlanBackedProvider) -> String {
        switch provider {
        case .claudeCode: return claudeCodeExecutablePath
        case .codex: return codexExecutablePath
        }
    }

    private func persistPlanBackedSettings() {
        configStore.planBackedProvider = planBackedProvider
        configStore.claudeCodeExecutablePath = claudeCodeExecutablePath
        configStore.codexExecutablePath = codexExecutablePath
    }

    private func configureBedrockDefaults() {
        bedrockRegion = ProviderConnect.bedrockRegion
        bedrockClassifierModelID = ProviderConnect.bedrockClassifierModelID
        bedrockSynthesizerModelID = ProviderConnect.bedrockSynthesizerModelID
        persistBedrockSettings()
        flash("Bedrock defaults set")
    }

    private func importBedrockEnvironmentCredentials() {
        var didImport = false
        let region = ProviderConnect.environmentValue(for: .awsRegion)
            ?? ProviderConnect.environmentValue(for: .awsDefaultRegion)
        if let region {
            bedrockRegion = region
            didImport = true
        }
        if let accessKeyID = ProviderConnect.environmentValue(for: .awsAccessKeyID) {
            bedrockAccessKeyID = accessKeyID
            didImport = true
        }
        if let secretAccessKey = ProviderConnect.environmentValue(for: .awsSecretAccessKey) {
            bedrockSecretAccessKey = secretAccessKey
            didImport = true
        }
        if let sessionToken = ProviderConnect.environmentValue(for: .awsSessionToken) {
            bedrockSessionToken = sessionToken
            didImport = true
        }
        guard didImport else {
            flash("No AWS env vars found", success: false)
            return
        }
        persistBedrockSettings()
        flash("Imported AWS env vars")
    }

    @discardableResult
    private func persistBedrockSettings() -> Bool {
        let synthesizerModelID: String
        if bedrockSynthesizerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            synthesizerModelID = bedrockClassifierModelID
        } else {
            synthesizerModelID = bedrockSynthesizerModelID
        }
        configStore.bedrockRegion = bedrockRegion
        configStore.bedrockClassifierModelID = bedrockClassifierModelID
        configStore.bedrockSynthesizerModelID = synthesizerModelID
        do {
            try KeychainStore.shared.set(bedrockAccessKeyID, for: .bedrockAccessKeyID)
            try KeychainStore.shared.set(bedrockSecretAccessKey, for: .bedrockSecretAccessKey)
            try KeychainStore.shared.set(bedrockSessionToken, for: .bedrockSessionToken)
            return true
        } catch {
            return false
        }
    }

    private func persistOpenAICompatibleSettings() {
        configStore.baseURL = customBaseURL
        configStore.classifierModel = customClassifierModel
        configStore.synthesizerModel = customSynthesizerModel
    }
}

struct CodeCollectionsSettingsView: View {
    let daemon: QMDDaemonController
    @State private var collections: [CodeCollectionStore.Collection] = []
    @State private var newName: String = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading) {
            List(collections) { c in
                VStack(alignment: .leading) {
                    Text(c.name).bold()
                    Text(c.rootPath).font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No code collections",
                        systemImage: "folder.badge.plus",
                        description: Text("Name a collection and choose a folder to index.")
                    )
                }
            }
            HStack {
                LabeledContent("Collection name") {
                    TextField("Collection name", text: $newName)
                        .labelsHidden()
                }
                Button("Add folder…") { addFolder() }
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { await refresh() }
    }

    private func addFolder() {
        guard !newName.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let store = CodeCollectionStore(engine: QueryEngine(daemon: daemon))
                do {
                    _ = try await store.add(name: newName, root: url)
                    newName = ""
                    addError = nil
                } catch {
                    addError = "Couldn't add \u{201C}\(newName)\u{201D}: \(error.localizedDescription)"
                }
                await refresh()
            }
        }
    }

    private func refresh() async {
        let store = CodeCollectionStore(engine: QueryEngine(daemon: daemon))
        collections = await store.list()
    }
}

struct UpdatesSettingsView: View {
    let controller: UpdateController
    @State private var auto: Bool = true

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $auto)
                .onChange(of: auto) { _, newValue in
                    controller.automaticChecksEnabled = newValue
                }
            Button("Check now") { controller.checkForUpdates() }
        }
        .onAppear { auto = controller.automaticChecksEnabled }
    }
}

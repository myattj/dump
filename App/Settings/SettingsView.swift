import SwiftUI
import AppKit

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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Dump Settings"
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(storage: coordinator.storage)
                .tabItem { Label("General", systemImage: "gearshape") }
            ClassifierSettingsView(hub: coordinator.classifierHub)
                .tabItem { Label("Classifier", systemImage: "brain") }
            CodeCollectionsSettingsView(daemon: coordinator.daemon)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            UpdatesSettingsView(controller: coordinator.updates)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

struct GeneralSettingsView: View {
    let storage: StoragePreference
    @State private var path: String = ""

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
                Text("Capture: ⇧⌘D · Query: ⇧⌘F")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { path = storage.root.path }
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

struct ClassifierSettingsView: View {
    let hub: ClassifierHub
    @State private var mode: ClassifierMode = .cloud
    @State private var apiKey: String = ""
    @State private var anthropicEndpoint: String = ""
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
    @State private var savedFlash: String?

    private let configStore = CustomLLMConfigStore.shared

    var body: some View {
        Form {
            Picker("Mode", selection: $mode) {
                Text("Cloud (Claude)").tag(ClassifierMode.cloud)
                Text("Local (Ollama)").tag(ClassifierMode.local)
                Text("OpenAI-compatible").tag(ClassifierMode.custom)
                Text("Amazon Bedrock").tag(ClassifierMode.bedrock)
            }
            .onChange(of: mode) { _, newValue in
                Task { await hub.setMode(newValue) }
            }

            if mode == .cloud {
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
                            try? KeychainStore.shared.set(apiKey, for: .anthropicAPIKey)
                            flash("Saved")
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
            } else if mode == .local {
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
            } else if mode == .custom {
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
                        try? KeychainStore.shared.set(customAPIKey, for: .customLLMAPIKey)
                        flash("Saved")
                    }
                }
            } else if mode == .bedrock {
                Section("Amazon Bedrock Runtime") {
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
                    Button("Save AWS credentials") {
                        configStore.bedrockRegion = bedrockRegion
                        configStore.bedrockClassifierModelID = bedrockClassifierModelID
                        configStore.bedrockSynthesizerModelID = bedrockSynthesizerModelID
                        try? KeychainStore.shared.set(bedrockAccessKeyID, for: .bedrockAccessKeyID)
                        try? KeychainStore.shared.set(bedrockSecretAccessKey, for: .bedrockSecretAccessKey)
                        try? KeychainStore.shared.set(bedrockSessionToken, for: .bedrockSessionToken)
                        flash("Saved")
                    }
                }
            }

            if let savedFlash {
                Text(savedFlash).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            self.mode = await hub.mode
            self.apiKey = KeychainStore.shared.string(for: .anthropicAPIKey) ?? ""
            self.anthropicEndpoint = configStore.anthropicEndpoint
            self.customBaseURL = configStore.baseURL
            self.customClassifierModel = configStore.classifierModel
            self.customSynthesizerModel = configStore.synthesizerModel
            self.customAPIKey = KeychainStore.shared.string(for: .customLLMAPIKey) ?? ""
            self.ollamaBaseURL = configStore.ollamaBaseURL
            self.ollamaModel = configStore.ollamaModel
            self.bedrockRegion = configStore.bedrockRegion
            self.bedrockClassifierModelID = configStore.bedrockClassifierModelID
            self.bedrockSynthesizerModelID = configStore.bedrockSynthesizerModelID
            self.bedrockAccessKeyID = KeychainStore.shared.string(for: .bedrockAccessKeyID) ?? ""
            self.bedrockSecretAccessKey = KeychainStore.shared.string(for: .bedrockSecretAccessKey) ?? ""
            self.bedrockSessionToken = KeychainStore.shared.string(for: .bedrockSessionToken) ?? ""
        }
    }

    private func flash(_ msg: String) {
        savedFlash = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { savedFlash = nil }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func importAnthropicEnvironmentKey() {
        guard let key = ProviderConnect.environmentValue(for: .anthropic) else {
            flash("No ANTHROPIC_API_KEY found")
            return
        }
        apiKey = key
        try? KeychainStore.shared.set(key, for: .anthropicAPIKey)
        flash("Imported ANTHROPIC_API_KEY")
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
            flash("No OPENAI_API_KEY found")
            return
        }
        customAPIKey = key
        configureOpenAIDefaults()
        try? KeychainStore.shared.set(key, for: .customLLMAPIKey)
        flash("Imported OPENAI_API_KEY")
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

    var body: some View {
        VStack(alignment: .leading) {
            List(collections) { c in
                VStack(alignment: .leading) {
                    Text(c.name).bold()
                    Text(c.rootPath).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                LabeledContent("Collection name") {
                    TextField("Collection name", text: $newName)
                        .labelsHidden()
                }
                Button("Add folder…") { addFolder() }
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
                _ = try? await store.add(name: newName, root: url)
                await refresh()
                newName = ""
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

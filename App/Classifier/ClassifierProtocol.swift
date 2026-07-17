import Foundation

public struct ClassifierResult: Equatable, Sendable {
    public var type: Frontmatter.EntryType
    public var title: String?
    public var tags: [String]
    public var scheduledAt: Date?
    public var deadlineAt: Date?
    public var effortMinutes: Int?
    /// 1 = low … 4 = critical, matching `Frontmatter.importance`.
    public var importance: Int?
    public var metadataConfidence: Double?

    public init(
        type: Frontmatter.EntryType,
        title: String? = nil,
        tags: [String] = [],
        scheduledAt: Date? = nil,
        deadlineAt: Date? = nil,
        effortMinutes: Int? = nil,
        importance: Int? = nil,
        metadataConfidence: Double? = nil
    ) {
        self.type = type
        self.title = title
        self.tags = tags
        self.scheduledAt = scheduledAt
        self.deadlineAt = deadlineAt
        self.effortMinutes = effortMinutes
        self.importance = importance
        self.metadataConfidence = metadataConfidence
    }

    /// Clamps a model-emitted importance onto the 1…4 scale.
    public static func normalizedImportance(_ raw: Int?) -> Int? {
        raw.map { min(max($0, 1), 4) }
    }

    public static let unknown = ClassifierResult(type: .unknown)
}

public protocol Classifier: Sendable {
    var identifier: String { get }
    func classify(_ text: String, now: Date) async throws -> ClassifierResult
}

public extension Classifier {
    func classify(_ text: String) async throws -> ClassifierResult {
        try await classify(text, now: Date())
    }
}

public enum ClassifierMode: String, CaseIterable, Sendable {
    case cloud, subscription, local, custom, bedrock
}

/// Shared UserDefaults key for the classifier/synthesizer mode toggle.
/// `SynthesizerHub` reads it too so picking a backend in Settings applies
/// to both classification and answer synthesis.
public enum ClassifierModePreference {
    public static let defaultsKey = "dump.classifier.mode"

    public static func read(from defaults: UserDefaults) -> ClassifierMode {
        let raw = defaults.string(forKey: defaultsKey) ?? ClassifierMode.cloud.rawValue
        return ClassifierMode(rawValue: raw) ?? .cloud
    }
}

/// Routes classification to the user-selected backend and stores a
/// reference to whichever implementations are available. Falls back to
/// `.unknown` on errors so capture is never blocked.
public actor ClassifierHub {
    public private(set) var mode: ClassifierMode
    private let claude: Classifier
    private let planBacked: Classifier
    private let ollama: Classifier
    private let custom: Classifier
    private let bedrock: Classifier
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(
        keychain: KeychainStore = .shared,
        configStore: CustomLLMConfigStore = .shared,
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard,
        claude: Classifier? = nil,
        planBacked: Classifier? = nil,
        ollama: Classifier? = nil,
        custom: Classifier? = nil,
        bedrock: Classifier? = nil
    ) {
        self.mode = ClassifierModePreference.read(from: defaults)
        self.defaults = defaults
        let transport = HTTPTransport(session: urlSession)
        self.claude = claude ?? ClaudeClassifier(keychain: keychain, transport: transport, configStore: configStore)
        self.planBacked = planBacked ?? PlanBackedClassifier(configStore: configStore)
        self.ollama = ollama ?? OllamaClassifier(transport: transport, configStore: configStore)
        self.custom = custom ?? CustomLLMClassifier(keychain: keychain, configStore: configStore, transport: transport)
        self.bedrock = bedrock ?? BedrockClassifier(keychain: keychain, configStore: configStore, transport: transport)
    }

    public func setMode(_ mode: ClassifierMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: ClassifierModePreference.defaultsKey)
    }

    public func classify(_ text: String, now: Date = Date()) async -> ClassifierResult {
        let backend = backend(for: mode)
        do {
            return try await backend.classify(text, now: now)
        } catch {
            return .unknown
        }
    }

    public var activeIdentifier: String {
        backend(for: mode).identifier
    }

    private func backend(for mode: ClassifierMode) -> Classifier {
        switch mode {
        case .cloud: return claude
        case .subscription: return planBacked
        case .local: return ollama
        case .custom: return custom
        case .bedrock: return bedrock
        }
    }
}

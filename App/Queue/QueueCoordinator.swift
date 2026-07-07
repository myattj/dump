import Foundation

@MainActor
public final class QueueCoordinator {
    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService

    public private(set) lazy var store = QueueStore(
        storage: storage,
        writer: writer,
        scheduler: scheduler
    )

    public private(set) lazy var viewModel = QueueViewModel(
        storage: storage,
        writer: writer,
        classifier: classifier,
        scheduler: scheduler,
        store: store
    )

    public private(set) lazy var window = QueueWindowController(viewModel: viewModel)

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        classifier: ClassifierHub,
        scheduler: SchedulerService
    ) {
        self.storage = storage
        self.writer = writer
        self.classifier = classifier
        self.scheduler = scheduler
    }

    public func show() {
        window.toggle()
    }

    public func refresh() {
        Task { await viewModel.refresh() }
    }
}

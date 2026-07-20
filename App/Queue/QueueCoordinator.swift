import Foundation

@MainActor
public final class QueueCoordinator {
    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService
    private let queryEngine: QueryEngine?

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
        store: store,
        queryEngine: queryEngine
    )

    public private(set) lazy var window = QueueWindowController(viewModel: viewModel)

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        classifier: ClassifierHub,
        scheduler: SchedulerService,
        queryEngine: QueryEngine? = nil
    ) {
        self.storage = storage
        self.writer = writer
        self.classifier = classifier
        self.scheduler = scheduler
        self.queryEngine = queryEngine
    }

    public func show() {
        window.toggle()
    }

    /// Opens (never toggles) the queue and lands the selection on `id` —
    /// how a notification tap arrives at the item that fired.
    public func reveal(id: String?) {
        window.show()
        guard let id else { return }
        Task {
            await viewModel.refresh()
            viewModel.selectedID = id
        }
    }

    public func refresh() {
        Task { await viewModel.refresh() }
    }

    /// Reconciles queue UI after a mutation performed outside QueueViewModel
    /// (for example, a notification action) and pushes the changed markdown
    /// into qmd just like an in-window queue action.
    public func refreshAfterExternalMutation() {
        Task { await viewModel.refreshAfterExternalMutation() }
    }

    /// Cancels and joins queue-triggered classifier and qmd work before the
    /// app tears down their process owners.
    public func stop() async {
        await viewModel.stop()
    }
}

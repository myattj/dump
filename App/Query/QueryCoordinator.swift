import AppKit
import Foundation

@MainActor
public final class QueryCoordinator {
    public let viewModel: QueryViewModel
    public let window: QueryWindowController

    public init(storage: StoragePreference, daemon: QMDDaemonController, synthesizer: Synthesizing) {
        let engine = QueryEngine(daemon: daemon)
        let vm = QueryViewModel(engine: engine, synthesizer: synthesizer)
        self.viewModel = vm
        self.window = QueryWindowController(viewModel: vm)
    }

    public func show() { window.toggle() }
}

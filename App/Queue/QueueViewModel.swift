import Foundation
import SwiftUI

@MainActor
public final class QueueViewModel: ObservableObject {
    public struct UndoToast: Equatable, Sendable {
        public let title: String
        fileprivate let record: QueueStore.UndoRecord
    }

    @Published public var input = ""
    @Published public var items: [QueueItem] = []
    @Published public var selectedID: String?
    @Published public var isLoading = false
    @Published public var isSubmitting = false
    @Published public var error: String?
    @Published public var undoToast: UndoToast?
    @Published public var isPinned = false

    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService
    private let store: QueueStore

    public init(
        storage: StoragePreference,
        writer: MarkdownWriter,
        classifier: ClassifierHub,
        scheduler: SchedulerService,
        store: QueueStore
    ) {
        self.storage = storage
        self.writer = writer
        self.classifier = classifier
        self.scheduler = scheduler
        self.store = store
    }

    public func refresh(now: Date = Date()) async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        do {
            let refreshed = try await store.reconcile(now: now)
            items = refreshed
            reconcileSelection()
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    public func submit(now: Date = Date()) async {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        input = ""
        isSubmitting = true
        undoToast = nil
        defer { isSubmitting = false }

        do {
            let result = try writer.write(body: body, into: storage.subdirectory(.inbox), source: .capture) { fm in
                fm.type = .task
                fm.title = Self.title(from: body)
                fm.metadataConfidence = 0
            }
            await refresh(now: now)
            Task { [weak self] in
                await self?.classifyAndRefresh(url: result.url, body: body, now: now)
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    public func selectNext() {
        guard !items.isEmpty else { return }
        guard let selectedID, let idx = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = items.first?.id
            return
        }
        self.selectedID = items[min(idx + 1, items.count - 1)].id
    }

    public func selectPrevious() {
        guard !items.isEmpty else { return }
        guard let selectedID, let idx = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = items.first?.id
            return
        }
        self.selectedID = items[max(idx - 1, 0)].id
    }

    public func completeSelected() async {
        guard let selectedID,
              let item = items.first(where: { $0.id == selectedID }) else {
            return
        }
        await complete(item)
    }

    public func complete(_ item: QueueItem) async {
        do {
            let undo = try await store.markDone(item)
            undoToast = UndoToast(title: item.title, record: undo)
            await refresh()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func undoCompletion() async {
        guard let undoToast else { return }
        do {
            try await store.undo(undoToast.record)
            self.undoToast = nil
            await refresh()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func dismissUndo() {
        undoToast = nil
    }

    private func classifyAndRefresh(url: URL, body: String, now: Date) async {
        let result = await classifier.classify(body, now: now)
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            var (fm, _) = try FrontmatterCodec.decode(raw)
            if result.type == .task || result.type == .reminder {
                fm.type = result.type
            }
            fm.title = result.title ?? fm.title
            fm.tags = result.tags.isEmpty ? fm.tags : result.tags
            fm.scheduledAt = result.scheduledAt
            fm.deadlineAt = result.deadlineAt
            fm.effortMinutes = result.effortMinutes
            fm.metadataConfidence = result.metadataConfidence
            fm.classifier = await classifier.activeIdentifier
            try writer.rewriteFrontmatter(at: url, with: fm)
            _ = await scheduler.reconcile()
            await refresh()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func reconcileSelection() {
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = items.first?.id
    }

    private static func title(from body: String) -> String {
        body
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "New task"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

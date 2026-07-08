import AppKit
import Foundation
import SwiftUI

/// The queue distilled for ambient surfaces (menu-bar badge, dropdown):
/// how many items have crossed their date, how many are still due today,
/// and the top of the ranked list. Derived, never persisted.
public struct QueueSummary: Equatable, Sendable {
    public let overdueCount: Int
    public let dueTodayCount: Int
    public let topItems: [QueueItem]

    public static let empty = QueueSummary(overdueCount: 0, dueTodayCount: 0, topItems: [])

    public init(overdueCount: Int, dueTodayCount: Int, topItems: [QueueItem]) {
        self.overdueCount = overdueCount
        self.dueTodayCount = dueTodayCount
        self.topItems = topItems
    }

    public static func compute(
        from items: [QueueItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QueueSummary {
        let visible = items.filter { !$0.isLater }
        var overdue = 0
        var dueToday = 0
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        for item in visible {
            guard let due = item.priorityAt else { continue }
            if due <= now {
                overdue += 1
            } else if let dayEnd, due < dayEnd {
                dueToday += 1
            }
        }
        return QueueSummary(
            overdueCount: overdue,
            dueTodayCount: dueToday,
            topItems: Array(visible.prefix(3))
        )
    }
}

@MainActor
public final class QueueViewModel: ObservableObject {
    public struct UndoToast: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case completed
            case snoozed(until: Date)
        }

        public let title: String
        public let kind: Kind
        fileprivate let record: QueueStore.UndoRecord
    }

    public enum DateKind: Equatable, Sendable {
        case deadline, reminder
    }

    public enum ParsedField: Hashable, Sendable {
        case date, effort, importance
    }

    /// What the composer input parses to right now, after the user's chip
    /// overrides. Drives the live chip strip and is exactly what submit()
    /// writes.
    public struct ParsePreview: Equatable, Sendable {
        public let date: Date?
        public let dateKind: DateKind
        public let effortMinutes: Int?
        public let importance: Int?

        public var isEmpty: Bool {
            date == nil && effortMinutes == nil && importance == nil
        }
    }

    public enum SnoozeOption: CaseIterable, Sendable {
        case laterToday, tomorrow, nextWeek

        public var label: String {
            switch self {
            case .laterToday: return "Later today"
            case .tomorrow: return "Tomorrow 9am"
            case .nextWeek: return "Next week"
            }
        }

        public func wakeDate(from now: Date = Date(), calendar: Calendar = .current) -> Date {
            switch self {
            case .laterToday:
                return now.addingTimeInterval(3 * 3_600)
            case .tomorrow:
                let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            case .nextWeek:
                let current = calendar.component(.weekday, from: now)
                var days = (2 - current + 7) % 7 // next Monday
                if days == 0 { days = 7 }
                let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            }
        }
    }

    @Published public var input = ""
    // Filtered once per items mutation instead of on every body read —
    // QueueView's body re-runs on every composer keystroke.
    @Published public var items: [QueueItem] = [] {
        didSet {
            nowItems = items.filter { !$0.isLater }
            laterItems = items.filter(\.isLater)
        }
    }
    @Published public private(set) var summary: QueueSummary = .empty
    @Published public var selectedID: String?
    @Published public var isLoading = false
    @Published public var isSubmitting = false
    @Published public var error: String?
    @Published public var undoToast: UndoToast?
    @Published public var isPinned = false
    @Published public var dateKindOverride: DateKind?
    @Published public var suppressedFields: Set<ParsedField> = []
    /// Row currently playing its completion beat (checkmark bounce + green
    /// tint) before it leaves the list. Also tells the row's removal
    /// transition to exit rightward — continuous with the swipe direction.
    @Published public private(set) var completingID: String?
    /// Row currently playing its snooze beat; its removal exits leftward,
    /// toward the Later section it's headed for.
    @Published public private(set) var snoozingID: String?

    @Published public private(set) var nowItems: [QueueItem] = []
    @Published public private(set) var laterItems: [QueueItem] = []

    private let storage: StoragePreference
    private let writer: MarkdownWriter
    private let classifier: ClassifierHub
    private let scheduler: SchedulerService
    private let store: QueueStore
    private var toastDismissTask: Task<Void, Never>?
    private var isToastHeld = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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
            summary = QueueSummary.compute(from: refreshed, now: now)
            reconcileSelection()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// What submit() will write for the current input, chip overrides applied.
    public func preview(now: Date = Date()) -> ParsePreview? {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return resolvedPreview(for: body, now: now)
    }

    public func toggleDateKind() {
        guard let preview = preview() else { return }
        dateKindOverride = preview.dateKind == .deadline ? .reminder : .deadline
    }

    public func suppress(_ field: ParsedField) {
        suppressedFields.insert(field)
    }

    public func clearComposer() {
        input = ""
        dateKindOverride = nil
        suppressedFields = []
    }

    public func submit(now: Date = Date()) async {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let preview = resolvedPreview(for: body, now: now)
        let overridden = dateKindOverride != nil || !suppressedFields.isEmpty
        input = ""
        dateKindOverride = nil
        suppressedFields = []
        isSubmitting = true
        clearUndoToast()
        defer { isSubmitting = false }

        do {
            let result = try await store.add(body: body) { fm in
                fm.type = preview.dateKind == .reminder ? .reminder : .task
                fm.title = QueueMetadataExtractor.displayTitle(from: body) ?? "New task"
                fm.scheduledAt = preview.dateKind == .reminder ? preview.date : nil
                fm.deadlineAt = preview.dateKind == .deadline ? preview.date : nil
                fm.effortMinutes = preview.effortMinutes
                fm.importance = preview.importance
                fm.metadataConfidence = 0
                if overridden {
                    fm.metadataEdited = true
                }
            }
            await refresh(now: now)
            Task { [weak self] in
                await self?.classifyAndRefresh(url: result.url, body: body, now: now)
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func resolvedPreview(for body: String, now: Date) -> ParsePreview {
        let metadata = QueueMetadataExtractor.extract(from: body, now: now)
        let parsedKind: DateKind = metadata.inferredType == .reminder ? .reminder : .deadline
        let kind = dateKindOverride ?? parsedKind
        let date = metadata.deadlineAt ?? metadata.scheduledAt
        return ParsePreview(
            date: suppressedFields.contains(.date) ? nil : date,
            dateKind: kind,
            effortMinutes: suppressedFields.contains(.effort) ? nil : metadata.effortMinutes,
            importance: suppressedFields.contains(.importance) ? nil : metadata.importance
        )
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
        // Re-entrancy guard: a double-click or second Cmd+Return during the
        // beat window must not mark the same item done twice (the second
        // markDone would clobber the undo record).
        guard completingID != item.id, snoozingID != item.id else { return }
        completingID = item.id
        // Conditional so a concurrently started beat on another row isn't
        // clobbered when this one finishes.
        defer { if completingID == item.id { completingID = nil } }
        do {
            // The checkmark beat runs concurrently with the store IO, so
            // the acknowledged state is on screen while the work happens.
            async let beat: Void = beatPause()
            let undo = try await store.markDone(item)
            await beat
            presentUndoToast(UndoToast(title: item.title, kind: .completed, record: undo))
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func snooze(_ item: QueueItem, _ option: SnoozeOption, now: Date = Date()) async {
        guard completingID != item.id, snoozingID != item.id else { return }
        let until = option.wakeDate(from: now)
        snoozingID = item.id
        defer { if snoozingID == item.id { snoozingID = nil } }
        do {
            async let beat: Void = beatPause()
            let undo = try await store.snooze(item, until: until)
            await beat
            presentUndoToast(UndoToast(title: item.title, kind: .snoozed(until: until), record: undo))
            await refresh(now: now)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// ~140ms acknowledgment window between "the user acted" and "the row
    /// leaves" so the beat is visible. Skipped under reduce motion.
    private func beatPause() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(nanoseconds: 140_000_000)
    }

    public func snoozeSelected(_ option: SnoozeOption) async {
        guard let item = items.first(where: { $0.id == selectedID }) else { return }
        await snooze(item, option)
    }

    public func wake(_ item: QueueItem) async {
        do {
            try await store.wake(item)
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func setImportance(_ item: QueueItem, to importance: Int?) async {
        await edit(item) { fm in
            fm.importance = importance
        }
    }

    public func adjustSelectedImportance(by delta: Int) async {
        guard let item = items.first(where: { $0.id == selectedID }) else { return }
        let next = min(max((item.importance ?? 2) + delta, 1), 4)
        guard next != (item.importance ?? 2) else { return }
        await setImportance(item, to: next)
    }

    public func setEffort(_ item: QueueItem, minutes: Int?) async {
        await edit(item) { fm in
            fm.effortMinutes = minutes
        }
    }

    public func setDate(_ item: QueueItem, to date: Date?, kind: DateKind) async {
        await edit(item) { fm in
            switch kind {
            case .deadline:
                fm.deadlineAt = date
                if fm.type == .reminder { fm.type = .task }
                fm.scheduledAt = nil
            case .reminder:
                fm.scheduledAt = date
                fm.deadlineAt = nil
                if date != nil { fm.type = .reminder }
            }
        }
    }

    private func edit(_ item: QueueItem, mutate: @Sendable @escaping (inout Frontmatter) -> Void) async {
        do {
            try await store.editMetadata(item, mutate: mutate)
            _ = await scheduler.reconcile()
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func undoCompletion() async {
        guard let undoToast else { return }
        do {
            try await store.undo(undoToast.record)
            clearUndoToast()
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func dismissUndo() {
        clearUndoToast()
    }

    /// Pause the toast's auto-dismiss countdown while the pointer hovers it
    /// (Sonner behavior) so Undo stays reachable; resume with a short fuse
    /// when the pointer leaves.
    public func holdUndoToast(_ holding: Bool) {
        guard undoToast != nil else { return }
        isToastHeld = holding
        if holding {
            toastDismissTask?.cancel()
        } else {
            scheduleToastDismissal(after: 2.5)
        }
    }

    // MARK: - Toast lifecycle

    /// Springs in via Motion.panel, auto-dismisses after 5s, exits on the
    /// shared exit curve. Replacing an existing toast retargets the
    /// animation and restarts the countdown — unless the pointer is holding
    /// the toast (content replacement fires no new hover event, so the hold
    /// must survive the replacement).
    private func presentUndoToast(_ toast: UndoToast) {
        withAnimation(resolved(Motion.panel, reduceMotion: reduceMotion)) {
            undoToast = toast
        }
        if !isToastHeld {
            scheduleToastDismissal(after: 5)
        }
    }

    private func scheduleToastDismissal(after seconds: TimeInterval) {
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearUndoToast()
        }
    }

    private func clearUndoToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        isToastHeld = false
        withAnimation(resolved(Motion.exit, reduceMotion: reduceMotion)) {
            undoToast = nil
        }
    }

    private func classifyAndRefresh(url: URL, body: String, now: Date) async {
        let result = await classifier.classify(body, now: now)
        let metadata = QueueMetadataExtractor.extract(from: body, now: now)
        let activeIdentifier = await classifier.activeIdentifier
        do {
            try await store.applyClassification(at: url) { fm in
                let userEdited = fm.metadataEdited == true
                if !userEdited {
                    if result.type == .task || result.type == .reminder {
                        fm.type = result.type
                    } else if fm.type == .unknown, let inferred = metadata.inferredType {
                        fm.type = inferred
                    }
                }
                fm.title = result.title ?? fm.title
                fm.tags = result.tags.isEmpty ? fm.tags : result.tags
                // The user set or cleared queue metadata deliberately — a nil
                // can mean "cleared", so the classifier must not touch these
                // at all.
                if !userEdited {
                    fm.scheduledAt = result.scheduledAt ?? fm.scheduledAt ?? metadata.scheduledAt
                    fm.deadlineAt = result.deadlineAt ?? fm.deadlineAt ?? metadata.deadlineAt
                    fm.effortMinutes = result.effortMinutes ?? fm.effortMinutes ?? metadata.effortMinutes
                    // Explicit syntax ("!!", "urgent") outranks the model's guess.
                    fm.importance = metadata.importance ?? result.importance ?? fm.importance
                }
                fm.metadataConfidence = result.metadataConfidence ?? fm.metadataConfidence
                fm.classifier = activeIdentifier
            }
            _ = await scheduler.reconcile()
            await refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reconcileSelection() {
        guard let selectedID else { return }
        if !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}

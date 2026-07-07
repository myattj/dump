import AppKit
import SwiftUI

@MainActor
public final class QueueWindowController: NSObject, NSWindowDelegate {
    private enum DefaultsKey {
        static let pinned = "dump.queue.pinned"
        static let frame = "dump.queue.frame"
    }

    private var panel: NSPanel?
    private var isShowing = false
    private var hideInFlight = false
    private var deactivateObserver: NSObjectProtocol?
    private let focusRequest = PanelFocusRequest()
    private let viewModel: QueueViewModel
    private let defaults: UserDefaults
    private var isPinned: Bool {
        didSet {
            defaults.set(isPinned, forKey: DefaultsKey.pinned)
            viewModel.isPinned = isPinned
            updatePanelBehavior()
            if isPinned { saveFrame() }
        }
    }

    public init(viewModel: QueueViewModel, defaults: UserDefaults = .standard) {
        self.viewModel = viewModel
        self.defaults = defaults
        self.isPinned = defaults.bool(forKey: DefaultsKey.pinned)
        super.init()
        viewModel.isPinned = isPinned
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing, !self.isPinned else { return }
                self.close()
            }
        }
    }

    public func toggle() {
        if isShowing { close() } else { show() }
    }

    public func show() {
        isShowing = true
        hideInFlight = false
        presentPanel()
        Task { await viewModel.refresh() }
    }

    public func close() {
        isShowing = false
        guard let panel, !hideInFlight else { return }
        hideInFlight = true
        saveFrame()
        PanelAnimator.hide(panel) { [weak self] in
            guard let self else { return }
            self.hideInFlight = false
            if self.isShowing {
                self.presentPanel()
            } else {
                self.panel = nil
            }
        }
    }

    public func togglePinned() {
        isPinned.toggle()
    }

    private func presentPanel() {
        if panel == nil {
            let view = QueueView(
                viewModel: viewModel,
                focusRequest: focusRequest,
                onCancel: { [weak self] in self?.close() },
                onTogglePinned: { [weak self] in self?.togglePinned() }
            )
            let host = NSHostingController(rootView: view)
            DumpWindowChrome.prepareHost(host, style: .queue)

            let p = DumpWindowChrome.makeFloatingPanel(style: .queue, resizable: true)
            p.delegate = self
            p.contentViewController = host
            panel = p
            updatePanelBehavior()
        }
        guard let panel else { return }
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        PanelAnimator.show(panel)
        focusRequest.request()
    }

    private func position(_ panel: NSPanel) {
        if isPinned, let frame = savedFrame(), isFrameVisible(frame) {
            panel.setFrame(frame, display: false)
            return
        }
        if isPinned, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: visible.maxX - size.width - 28,
                y: visible.maxY - size.height - 30
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            saveFrame()
            return
        }
        panel.center()
    }

    private func updatePanelBehavior() {
        guard let panel else { return }
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.transient, .fullScreenAuxiliary]
    }

    private func saveFrame() {
        guard isPinned, let panel else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: DefaultsKey.frame)
    }

    private func savedFrame() -> NSRect? {
        guard let raw = defaults.string(forKey: DefaultsKey.frame) else { return nil }
        let frame = NSRectFromString(raw)
        return frame.isEmpty ? nil : frame
    }

    private func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    public func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    public func windowDidResize(_ notification: Notification) {
        saveFrame()
    }
}

struct QueueView: View {
    @ObservedObject var viewModel: QueueViewModel
    @ObservedObject var focusRequest: PanelFocusRequest
    let onCancel: @MainActor () -> Void
    let onTogglePinned: @MainActor () -> Void

    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DumpPanelShell(style: .queue, alignment: .bottom) {
            VStack(spacing: 0) {
                titleStrip
                composer
                content
            }

            keyboardDoneButton

            if let toast = viewModel.undoToast {
                undoToast(toast)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { requestInputFocus() }
        .onChange(of: focusRequest.token) { _, _ in
            requestInputFocus()
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .task { await viewModel.refresh() }
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.items)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.selectedID)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.undoToast)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.isPinned)
    }

    private func requestInputFocus() {
        inputFocused = false
        Task { @MainActor in
            inputFocused = true
        }
    }

    private var titleStrip: some View {
        DumpPanelTitleStrip(
            iconName: "checklist",
            title: "Queue",
            badge: viewModel.items.isEmpty ? nil : "\(viewModel.items.count)"
        ) {
            Button(viewModel.isPinned ? "Unpin queue" : "Keep queue open", systemImage: viewModel.isPinned ? "pin.fill" : "pin", action: onTogglePinned)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: DumpUI.Controls.iconButton.width, height: DumpUI.Controls.iconButton.height)
                .labelStyle(.iconOnly)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
                .help(viewModel.isPinned ? "Unpin" : "Keep open")
            Button("Close queue", systemImage: "xmark", action: onCancel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: DumpUI.Controls.iconButton.width, height: DumpUI.Controls.iconButton.height)
                .labelStyle(.iconOnly)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
                .help("Close")
            }
    }

    private var composer: some View {
        LiquidGlassGroup {
            HStack(spacing: 10) {
                Image(systemName: viewModel.isSubmitting ? "sparkles" : "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(viewModel.isSubmitting ? Color.accentColor : Color.primary.opacity(0.7))
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: viewModel.isSubmitting)
                    .frame(width: 18)

                TextField(
                    "Queue item",
                    text: $viewModel.input,
                    prompt: Text("send invoice tomorrow 15m")
                        .foregroundColor(Color.primary.opacity(0.42))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .focused($inputFocused)
                .onSubmit {
                    Task {
                        await viewModel.submit()
                        inputFocused = true
                    }
                }

                if !viewModel.input.isEmpty {
                    Button("Clear queue item", systemImage: "xmark.circle.fill") {
                        viewModel.input = ""
                        inputFocused = true
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.52))
                    .labelStyle(.iconOnly)
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.86))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                Button("Add to queue", systemImage: "arrow.up.circle.fill") {
                    Task {
                        await viewModel.submit()
                        inputFocused = true
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.secondary.opacity(0.45)
                        : Color.accentColor
                )
                .labelStyle(.iconOnly)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
                .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(inputFocused ? 0.42 : 0.14), lineWidth: 1)
            )
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            loadingState
        } else if let error = viewModel.error, viewModel.items.isEmpty {
            errorState(error)
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.items) { item in
                        QueueRow(
                            item: item,
                            isSelected: viewModel.selectedID == item.id,
                            onSelect: { viewModel.selectedID = item.id },
                            onComplete: { await viewModel.complete(item) }
                        )
                        .id(item.id)
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.selectedID) { _, id in
                guard let id else { return }
                withAnimation(resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading queue")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 44)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("Your queue is clear")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 48)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
                Text("Queue unavailable")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Text("Check that the Dump daemon is running, then try again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .queueQuietSurface(cornerRadius: 8)
        .padding(.horizontal, 18)
    }

    private var keyboardDoneButton: some View {
        Button {
            Task { await viewModel.completeSelected() }
        } label: {
            EmptyView()
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func undoToast(_ toast: QueueViewModel.UndoToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
            Text(toast.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Undo completion", systemImage: "arrow.uturn.backward") {
                Task { await viewModel.undoCompletion() }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .labelStyle(.iconOnly)
            .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
            .help("Undo")
            Button("Dismiss undo message", systemImage: "xmark") {
                viewModel.dismissUndo()
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .labelStyle(.iconOnly)
            .buttonStyle(PressableButtonStyle(pressedScale: 0.88))
            .help("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, 18)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    let onComplete: @MainActor () async -> Void

    @State private var dragX: CGFloat = 0
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            doneRail
            rowContent
                .offset(x: dragX)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragX = max(0, min(value.translation.width, 104))
                }
                .onEnded { value in
                    let shouldComplete = value.translation.width > 76
                    withAnimation(resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                        dragX = 0
                    }
                    if shouldComplete {
                        Task { await onComplete() }
                    }
                }
        )
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: isHovering)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: isSelected)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Button("Mark done", systemImage: isSelected || isHovering ? "checkmark.circle.fill" : "circle") {
                Task { await onComplete() }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isSelected ? Color.green : Color.secondary.opacity(0.72))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            .labelStyle(.iconOnly)
            .buttonStyle(PressableButtonStyle(pressedScale: 0.84))
            .help("Mark done")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("#\(item.queueRank)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                metadata
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(rowStroke)
    }

    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8)

        return shape
            .fill(QueueSurface.rowFill)
            .overlay(shape.fill(QueueSurface.rowStateFill(isSelected: isSelected, isHovering: isHovering)))
    }

    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : QueueSurface.contentStroke, lineWidth: 1)
    }

    private var doneRail: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.green.opacity(0.18))
            .overlay(alignment: .leading) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.leading, 18)
            }
            .opacity(dragX > 8 ? 1 : 0)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let date = item.priorityAt {
                chip(icon: item.deadlineAt == nil ? "bell" : "calendar", text: formatted(date), color: dueColor(date))
            }
            if let effort = item.effortMinutes {
                chip(icon: "hourglass", text: formattedEffort(effort), color: .indigo)
            }
            if item.type == .reminder {
                chip(icon: "bell.badge", text: "reminder", color: .orange)
            }
            if let confidence = item.metadataConfidence, confidence > 0, confidence < 0.55 {
                chip(icon: "questionmark.diamond", text: "low confidence", color: .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func formatted(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = timeString(date)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if calendar.isDateInYesterday(date) { return "overdue" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? "EEE MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date).lowercased()
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date).lowercased()
    }

    private func formattedEffort(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func dueColor(_ date: Date) -> Color {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return .red }
        if interval < 24 * 60 * 60 { return .orange }
        return .teal
    }
}

// MARK: - Queue content surfaces

private enum QueueSurface {
    static var contentFill: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.9)
    }

    static var contentStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.65)
    }

    static var rowFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.74)
    }

    static func rowStateFill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.12)
        }
        if isHovering {
            return DumpUI.SemanticStyle.hoverFill
        }
        return .clear
    }
}

private struct QueueQuietSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)

        content
            .background(shape.fill(QueueSurface.contentFill))
            .overlay(shape.strokeBorder(QueueSurface.contentStroke, lineWidth: 0.5))
    }
}

private extension View {
    func queueQuietSurface(cornerRadius: CGFloat) -> some View {
        modifier(QueueQuietSurface(cornerRadius: cornerRadius))
    }
}

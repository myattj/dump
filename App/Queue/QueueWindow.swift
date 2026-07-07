import AppKit
import SwiftUI
import Wave

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
        // Physical acknowledgment: pinning dips the panel a couple of points
        // and springs back — it visibly "anchors" itself.
        if isPinned, let panel {
            PanelAnimator.nudge(panel)
        }
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
        // Only reposition when the panel is actually off-screen — a re-show
        // that interrupts the hide animation retargets in place instead of
        // teleporting the still-visible window.
        if !panel.isVisible {
            position(panel)
        }
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
        panel.level = isPinned ? .normal : .floating
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
    @State private var laterExpanded = false
    @State private var emptyStateBounce = 0
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
                    // Sonner grammar: springs up from the bottom edge with a
                    // slight settle (driven by Motion.panel at the mutation
                    // site), accelerates away on the exit curve when done.
                    .transition(reducedTransition(
                        .asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                                .combined(with: .opacity),
                            removal: .offset(y: 12).combined(with: .opacity)
                        ),
                        reduceMotion: reduceMotion
                    ))
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
            // Key-repeat path: selection moves on the 100ms micro curve only.
            withAnimation(resolved(Motion.micro, reduceMotion: reduceMotion)) {
                viewModel.selectNext()
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            withAnimation(resolved(Motion.micro, reduceMotion: reduceMotion)) {
                viewModel.selectPrevious()
            }
            return .handled
        }
        .task { await viewModel.refresh() }
        .onChange(of: viewModel.items.isEmpty) { wasEmpty, isEmpty in
            // One earned bounce when the user clears the last item — never
            // on first load, never looping. Lives on the body (always
            // mounted) so it observes the flip that mounts the empty state.
            if isEmpty && !wasEmpty {
                emptyStateBounce += 1
            }
        }
        .onChange(of: viewModel.selectedID) { _, id in
            // Keyboard selection can walk into the Later bucket; reveal the
            // section so the selection never lands on an invisible row.
            guard let id, !laterExpanded,
                  viewModel.laterItems.contains(where: { $0.id == id }) else { return }
            withAnimation(resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                laterExpanded = true
            }
        }
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
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
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
            // Count-keyed (not items-keyed) so the badge's numericText rolls
            // on add/complete but reorders don't touch the strip.
            .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.items.count)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            composerField
            if let preview = viewModel.preview(), !preview.isEmpty {
                ParsePreviewStrip(
                    preview: preview,
                    onToggleDateKind: { viewModel.toggleDateKind() },
                    onClear: { viewModel.suppress($0) }
                )
                .padding(.horizontal, 4)
                .transition(reducedTransition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ),
                    reduceMotion: reduceMotion
                ))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        // Keyed on the minute-stable projection, not the raw preview — its
        // Date carries sub-second precision from "in 30 minutes"-style
        // parses, which would re-key this animation on every keystroke.
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.preview()?.animationKey)
    }

    private var composerField: some View {
        LiquidGlassGroup {
            HStack(spacing: 10) {
                Image(systemName: viewModel.isSubmitting ? "sparkles" : "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(viewModel.isSubmitting ? Color.accentColor : Color.primary.opacity(0.7))
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: viewModel.isSubmitting && !reduceMotion)
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
                        viewModel.clearComposer()
                        inputFocused = true
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.52))
                    .labelStyle(.iconOnly)
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.86))
                    .transition(clearButtonTransition(reduceMotion: reduceMotion))
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
            .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: inputFocused)
            // Keyed on .isEmpty, not the text — fires exactly twice per
            // compose cycle (first character, clear/submit), never per
            // keystroke.
            .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: viewModel.input.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                loadingState
            } else if let error = viewModel.error, viewModel.items.isEmpty {
                errorState(error)
            } else if viewModel.items.isEmpty {
                emptyState
                    .transition(reducedTransition(
                        .scale(scale: 0.94).combined(with: .opacity),
                        reduceMotion: reduceMotion
                    ))
            } else {
                list
            }
        }
        // Fires at most once per submit/complete — drives the list ↔
        // empty-state swap with a hint of overshoot (the reward moment).
        .animation(resolved(Motion.bouncy, reduceMotion: reduceMotion), value: viewModel.items.isEmpty)
    }

    /// Removal direction mirrors what happened: completed rows exit right
    /// (continuous with the swipe), snoozed rows exit left toward Later.
    private func rowTransition(for item: QueueItem) -> AnyTransition {
        if reduceMotion { return .opacity }
        let removal: AnyTransition
        if viewModel.snoozingID == item.id {
            removal = .offset(x: -24).combined(with: .opacity)
        } else if viewModel.completingID == item.id {
            removal = .offset(x: 24).combined(with: .opacity)
        } else {
            removal = .opacity
        }
        return .asymmetric(
            insertion: .scale(scale: 0.97, anchor: .leading).combined(with: .opacity),
            removal: removal
        )
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.nowItems) { item in
                        QueueRow(
                            viewModel: viewModel,
                            item: item,
                            isSelected: viewModel.selectedID == item.id
                        )
                        .id(item.id)
                        .padding(.horizontal, 18)
                        .transition(rowTransition(for: item))
                    }
                    if !viewModel.laterItems.isEmpty {
                        laterSection
                    }
                }
                .padding(.bottom, 20)
                // Scoped to the list so insert/remove/reorder is the only
                // thing this drives — never the whole panel subtree.
                .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.items)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.selectedID) { _, id in
                guard let id else { return }
                // Anchor-less: scrolls the minimum distance to reveal the
                // row and does nothing when it's already visible.
                withAnimation(resolved(Motion.micro, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder
    private var laterSection: some View {
        Button {
            withAnimation(resolved(Motion.snappy, reduceMotion: reduceMotion)) {
                laterExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(laterExpanded ? 90 : 0))
                Image(systemName: "moon.zzz")
                    .font(.system(size: 11, weight: .semibold))
                Text("Later")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(viewModel.laterItems.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(viewModel.laterItems.count)))
                Spacer()
                if !laterExpanded, let next = viewModel.laterItems.first?.wakeAt {
                    Text("next \(QueueFormat.date(next))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 6)

        if laterExpanded {
            ForEach(viewModel.laterItems) { item in
                QueueRow(
                    viewModel: viewModel,
                    item: item,
                    isSelected: viewModel.selectedID == item.id
                )
                .id(item.id)
                .padding(.horizontal, 18)
                .opacity(0.75)
                .transition(reducedTransition(
                    .opacity.combined(with: .offset(y: -4)),
                    reduceMotion: reduceMotion
                ))
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
            emptyTrayIcon
            Text("Your queue is clear")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 48)
    }

    @ViewBuilder
    private var emptyTrayIcon: some View {
        let icon = Image(systemName: "tray")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.tertiary)
            .symbolRenderingMode(.hierarchical)

        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.bounce.up, value: emptyStateBounce)
        }
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
        Group {
            Button {
                Task { await viewModel.completeSelected() }
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            Button {
                Task { await viewModel.adjustSelectedImportance(by: 1) }
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            Button {
                Task { await viewModel.adjustSelectedImportance(by: -1) }
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            Button {
                Task { await viewModel.snoozeSelected(.tomorrow) }
            } label: {
                EmptyView()
            }
            .keyboardShortcut("s", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func undoToast(_ toast: QueueViewModel.UndoToast) -> some View {
        HStack(spacing: 10) {
            switch toast.kind {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
            case .snoozed(let until):
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.indigo)
                    .symbolRenderingMode(.hierarchical)
                Text("Snoozed until \(QueueFormat.date(until))")
                    .font(.system(size: 12, weight: .semibold))
            }
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
        // Rasterize once before the 16pt shadow so the blur isn't recomputed
        // per animation frame.
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, 18)
        // Hovering pauses the auto-dismiss countdown so Undo stays
        // reachable; leaving resumes it on a short fuse.
        .onHover { viewModel.holdUndoToast($0) }
    }
}

/// Wave-driven physics for a queue row's horizontal swipe. The animator is
/// stopped while the finger is down (1:1 tracking) and released with the
/// gesture's own velocity, so settles and fly-offs continue the user's
/// motion instead of restarting on a canned curve — and a re-grab mid-flight
/// retargets from the row's live position instead of teleporting.
@MainActor
private final class RowSwipeEngine: ObservableObject {
    private let animator: SpringAnimator<CGFloat>
    var onValue: (@MainActor (CGFloat) -> Void)?
    private(set) var dragBase: CGFloat = 0
    private(set) var isDragging = false

    init() {
        animator = SpringAnimator<CGFloat>(spring: DumpUI.Motion.Swipe.settleSpring)
        animator.valueChanged = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !self.isDragging else {
                    // A display-link tick enqueued before stop() can land
                    // after a re-grab — the finger owns the value now, so
                    // stale spring frames are dropped instead of fighting it.
                    return
                }
                self.onValue?(value)
            }
        }
    }

    func beginDrag(from current: CGFloat) {
        animator.stop()
        dragBase = current
        isDragging = true
    }

    func release(from current: CGFloat, to target: CGFloat, velocity: CGFloat) {
        isDragging = false
        animator.value = current
        animator.target = target
        animator.velocity = velocity
        animator.start()
    }

    func cancel() {
        animator.stop()
        isDragging = false
    }
}

private struct QueueRow: View {
    private enum SwipeSide {
        case done, snooze
    }

    @ObservedObject var viewModel: QueueViewModel
    let item: QueueItem
    let isSelected: Bool

    // StateObject so the engine (and its Wave animator) is built once per
    // row identity, not on every body evaluation of the parent view.
    @StateObject private var engine = RowSwipeEngine()
    @State private var dragX: CGFloat = 0
    @State private var rowWidth: CGFloat = 400
    @State private var thresholdSide: SwipeSide?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompleting: Bool { viewModel.completingID == item.id }
    private var isSnoozing: Bool { viewModel.snoozingID == item.id }

    var body: some View {
        ZStack(alignment: .leading) {
            doneRail
            snoozeRail
            rowContent
                .offset(x: dragX)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        rowWidth = width
                    }
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { viewModel.selectedID = item.id }
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            engine.onValue = { dragX = $0 }
        }
        .gesture(swipeGesture)
        .contextMenu { contextMenuItems }
        // Once committed, the leftover rail must not accept another grab or
        // tap while the row waits to be removed.
        .allowsHitTesting(!(isCompleting || isSnoozing))
        .onChange(of: isCompleting) { _, active in
            if !active { recoverIfStranded() }
        }
        .onChange(of: isSnoozing) { _, active in
            if !active { recoverIfStranded() }
        }
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: isHovering)
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: isSelected)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: isCompleting)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: isSnoozing)
    }

    /// Failure/still-here path for the fly-off: if the beat ended but the
    /// row is still mounted (store op failed, or a snoozed Later row stays
    /// in the Later list), spring it home instead of leaving it stranded
    /// offscreen behind a fully lit rail.
    private func recoverIfStranded() {
        guard !engine.isDragging, dragX != 0 else { return }
        if reduceMotion {
            engine.cancel()
            dragX = 0
        } else {
            engine.release(from: dragX, to: 0, velocity: 0)
        }
        withAnimation(resolved(Motion.press, reduceMotion: reduceMotion)) {
            thresholdSide = nil
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !engine.isDragging {
                    // Horizontal-intent gate: sloppy clicks and vertical
                    // pointer travel never turn into aborted swipes — the
                    // drag only arms once it's clearly sideways.
                    guard abs(value.translation.width) >= 8,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    // Re-grab mid-flight: stop the spring where it is and
                    // track the finger relative to the row's live position.
                    engine.beginDrag(from: dragX)
                }
                dragX = rubberBanded(engine.dragBase + value.translation.width)
                updateThresholdSide()
            }
            .onEnded { value in
                guard engine.isDragging else { return }
                // Decide by the engaged threshold state, not raw position —
                // the haptic and lit rail already told the user "this will
                // commit", and hysteresis means that state can outlast ±76pt.
                let commit = thresholdSide == .done
                let snooze = thresholdSide == .snooze
                let velocity = value.velocity.width

                if reduceMotion {
                    engine.cancel()
                    dragX = 0
                    thresholdSide = nil
                    if commit {
                        Task { await viewModel.complete(item) }
                    } else if snooze {
                        Task { await viewModel.snooze(item, .tomorrow) }
                    }
                    return
                }

                if commit {
                    // Fly off trailing-ward on the user's own momentum; the
                    // row stays offscreen until the items diff removes it
                    // (or recoverIfStranded brings it back on failure).
                    engine.release(from: dragX, to: rowWidth + 56, velocity: velocity)
                    Task { await viewModel.complete(item) }
                } else if snooze {
                    engine.release(from: dragX, to: -(rowWidth + 56), velocity: velocity)
                    Task { await viewModel.snooze(item, .tomorrow) }
                } else {
                    engine.release(from: dragX, to: 0, velocity: velocity)
                    thresholdSide = nil
                }
            }
    }

    /// Overdrag resistance past the swipe limit, matching scroll-edge feel.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let limit = DumpUI.Motion.Swipe.maxDrag
        let magnitude = abs(x)
        guard magnitude > limit else { return x }
        let over = magnitude - limit
        return (limit + over * DumpUI.Motion.Swipe.rubberBand) * (x < 0 ? -1 : 1)
    }

    /// Haptic tick + checkmark/moon pop the moment the drag crosses the
    /// commit threshold — the commitment is felt before release. Engages at
    /// `commitThreshold` but only disengages below `releaseThreshold`, so
    /// jitter at the boundary can't machine-gun the haptic.
    private func updateThresholdSide() {
        let engage = DumpUI.Motion.Swipe.commitThreshold
        let release = DumpUI.Motion.Swipe.releaseThreshold
        let side: SwipeSide?
        switch thresholdSide {
        case .done:
            side = dragX >= release ? .done : (dragX <= -engage ? .snooze : nil)
        case .snooze:
            side = dragX <= -release ? .snooze : (dragX >= engage ? .done : nil)
        case nil:
            side = dragX >= engage ? .done : (dragX <= -engage ? .snooze : nil)
        }
        guard side != thresholdSide else { return }
        if side != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(resolved(Motion.press, reduceMotion: reduceMotion)) {
            thresholdSide = side
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Mark done", systemImage: "checkmark.circle") {
            Task { await viewModel.complete(item) }
        }
        if item.isLater {
            Button("Wake now", systemImage: "sun.max") {
                Task { await viewModel.wake(item) }
            }
        }
        Menu("Snooze") {
            ForEach(QueueViewModel.SnoozeOption.allCases, id: \.self) { option in
                Button(option.label) {
                    Task { await viewModel.snooze(item, option) }
                }
            }
        }
        Divider()
        Menu("Importance") { importanceMenuItems }
        Menu("Effort") { effortMenuItems }
        Menu(item.type == .reminder ? "Remind" : "Due") { dateMenuItems }
    }

    @ViewBuilder
    private var importanceMenuItems: some View {
        ForEach([4, 3, 2, 1], id: \.self) { level in
            Button {
                Task { await viewModel.setImportance(item, to: level) }
            } label: {
                if item.importance == level {
                    Label(QueueFormat.importanceLabel(level).capitalized, systemImage: "checkmark")
                } else {
                    Text(QueueFormat.importanceLabel(level).capitalized)
                }
            }
        }
        if item.importance != nil {
            Divider()
            Button("Clear priority") {
                Task { await viewModel.setImportance(item, to: nil) }
            }
        }
    }

    @ViewBuilder
    private var effortMenuItems: some View {
        ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
            Button {
                Task { await viewModel.setEffort(item, minutes: minutes) }
            } label: {
                if item.effortMinutes == minutes {
                    Label(QueueFormat.effort(minutes), systemImage: "checkmark")
                } else {
                    Text(QueueFormat.effort(minutes))
                }
            }
        }
        if item.effortMinutes != nil {
            Divider()
            Button("Clear effort") {
                Task { await viewModel.setEffort(item, minutes: nil) }
            }
        }
    }

    @ViewBuilder
    private var dateMenuItems: some View {
        Button("Today 5pm") {
            Task { await viewModel.setDate(item, to: Self.todayAt(17), kind: dateKind) }
        }
        Button("Tomorrow 9am") {
            Task { await viewModel.setDate(item, to: QueueViewModel.SnoozeOption.tomorrow.wakeDate(), kind: dateKind) }
        }
        Button("Next Monday 9am") {
            Task { await viewModel.setDate(item, to: QueueViewModel.SnoozeOption.nextWeek.wakeDate(), kind: dateKind) }
        }
        if item.priorityAt != nil {
            Divider()
            Button(item.type == .reminder ? "Make it a deadline" : "Make it a reminder") {
                Task {
                    await viewModel.setDate(
                        item,
                        to: item.priorityAt,
                        kind: item.type == .reminder ? .deadline : .reminder
                    )
                }
            }
            Button("Clear date") {
                Task { await viewModel.setDate(item, to: nil, kind: dateKind) }
            }
        }
    }

    private var dateKind: QueueViewModel.DateKind {
        item.type == .reminder ? .reminder : .deadline
    }

    private static func todayAt(_ hour: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return candidate > now
            ? candidate
            : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            completeButton

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
                        .help(QueueFormat.rankExplanation(for: item))
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

    /// The ~150ms acknowledgment beat: the circle fills into a bouncing
    /// green checkmark (or indigo moon for snooze) the instant the action
    /// fires, while the store IO runs — then the row departs.
    @ViewBuilder
    private var completeButton: some View {
        let filled = isCompleting || isSelected || isHovering
        let name = isSnoozing ? "moon.zzz.fill" : (filled ? "checkmark.circle.fill" : "circle")
        let tint: Color = isCompleting ? .green : (isSnoozing ? .indigo : (isSelected ? .green : Color.secondary.opacity(0.72)))

        Button("Mark done", systemImage: name) {
            Task { await viewModel.complete(item) }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(tint)
        .symbolRenderingMode(.hierarchical)
        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        .modifier(CompletionBounce(trigger: isCompleting, enabled: !reduceMotion))
        .frame(width: 22, height: 22)
        .padding(.top, 1)
        .labelStyle(.iconOnly)
        .buttonStyle(PressableButtonStyle(pressedScale: 0.84))
        .help("Mark done")
    }

    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8)

        return shape
            .fill(QueueSurface.rowFill)
            .overlay(shape.fill(QueueSurface.rowStateFill(
                isSelected: isSelected,
                isHovering: isHovering,
                isCompleting: isCompleting,
                isSnoozing: isSnoozing
            )))
    }

    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : QueueSurface.contentStroke, lineWidth: 1)
    }

    // The rails map directly to drag progress — no Animation, just the
    // finger. Opacity ramps in over the first ~40pt, the glyph grows toward
    // the threshold and pops (Motion.press, from updateThresholdSide) when
    // the commit locks in.

    private var doneRail: some View {
        let progress = max(dragX, 0)
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.green.opacity(thresholdSide == .done ? 0.30 : 0.18))
            .overlay(alignment: .leading) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                    .scaleEffect(railGlyphScale(progress: progress, popped: thresholdSide == .done))
                    .offset(x: min(progress * 0.12, 8))
                    .padding(.leading, 18)
            }
            .opacity(railOpacity(progress: progress))
    }

    private var snoozeRail: some View {
        let progress = max(-dragX, 0)
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.indigo.opacity(thresholdSide == .snooze ? 0.30 : 0.18))
            .overlay(alignment: .trailing) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.indigo)
                    .scaleEffect(railGlyphScale(progress: progress, popped: thresholdSide == .snooze))
                    .offset(x: -min(progress * 0.12, 8))
                    .padding(.trailing, 18)
            }
            .opacity(railOpacity(progress: progress))
    }

    private func railOpacity(progress: CGFloat) -> CGFloat {
        min(max((progress - 8) / 32, 0), 1)
    }

    private func railGlyphScale(progress: CGFloat, popped: Bool) -> CGFloat {
        let grown = 0.7 + 0.3 * min(progress / DumpUI.Motion.Swipe.commitThreshold, 1)
        return popped ? grown * 1.15 : grown
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if item.isLater, let wake = item.wakeAt {
                chipMenu {
                    snoozeMenuChoices
                } label: {
                    ChipLabel(icon: "moon.zzz", text: "until \(QueueFormat.date(wake))", color: .indigo)
                }
                .help("Snoozed — right-click the row to wake it")
            }
            if let date = item.priorityAt {
                chipMenu {
                    dateMenuItems
                } label: {
                    ChipLabel(
                        icon: item.deadlineAt == nil ? "bell" : "calendar",
                        text: QueueFormat.date(date),
                        color: QueueFormat.dueColor(date)
                    )
                }
            } else if isHovering || isSelected {
                chipMenu {
                    dateMenuItems
                } label: {
                    ChipLabel(icon: "calendar.badge.plus", text: "add date", color: .secondary)
                }
            }
            if let effort = item.effortMinutes {
                chipMenu {
                    effortMenuItems
                } label: {
                    ChipLabel(icon: "hourglass", text: QueueFormat.effort(effort), color: .indigo)
                }
            } else if isHovering || isSelected {
                chipMenu {
                    effortMenuItems
                } label: {
                    ChipLabel(icon: "hourglass.badge.plus", text: "effort", color: .secondary)
                }
            }
            if let importance = item.importance {
                chipMenu {
                    importanceMenuItems
                } label: {
                    ChipLabel(
                        icon: "flag",
                        text: QueueFormat.importanceLabel(importance),
                        color: QueueFormat.importanceColor(importance)
                    )
                }
            } else if isHovering || isSelected {
                chipMenu {
                    importanceMenuItems
                } label: {
                    ChipLabel(icon: "flag", text: "add priority", color: .secondary)
                }
            }
            if item.type == .reminder {
                ChipLabel(icon: "bell.badge", text: "reminder", color: .orange)
            }
            if let confidence = item.metadataConfidence, confidence > 0, confidence < 0.55 {
                ChipLabel(icon: "questionmark.diamond", text: "low confidence", color: .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var snoozeMenuChoices: some View {
        Button("Wake now", systemImage: "sun.max") {
            Task { await viewModel.wake(item) }
        }
        Divider()
        ForEach(QueueViewModel.SnoozeOption.allCases, id: \.self) { option in
            Button(option.label) {
                Task { await viewModel.snooze(item, option) }
            }
        }
    }

    private func chipMenu(
        @ViewBuilder _ content: () -> some View,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Menu(content: content, label: label)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
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

    static func rowStateFill(
        isSelected: Bool,
        isHovering: Bool,
        isCompleting: Bool = false,
        isSnoozing: Bool = false
    ) -> Color {
        if isCompleting {
            return Color.green.opacity(0.14)
        }
        if isSnoozing {
            return Color.indigo.opacity(0.12)
        }
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.12)
        }
        if isHovering {
            return DumpUI.SemanticStyle.hoverFill
        }
        return .clear
    }
}

/// Bounces its content once each time `trigger` flips true. Wrapped in a
/// modifier so the symbol effect can be compiled out entirely under reduce
/// motion.
private struct CompletionBounce: ViewModifier {
    let trigger: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.symbolEffect(.bounce, value: trigger)
        } else {
            content
        }
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

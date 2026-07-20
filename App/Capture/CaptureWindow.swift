import AppKit
import SwiftUI

/// Spotlight-style floating panel for quick capture. Closes immediately on
/// Enter — classification and indexing happen after the window is gone.
@MainActor
public final class CaptureWindowController {
    public typealias Submit = @MainActor (String) -> Void

    private var panel: NSPanel?
    // `isShowing` tracks user *intent* and is updated synchronously. Don't
    // gate `toggle()` on `panel.isVisible` — the panel is still visible
    // during the ~130ms hide animation, so a hotkey press mid-animation
    // would re-close instead of re-opening.
    private var isShowing = false
    private var hideInFlight = false
    private var resignKeyObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Whoever was frontmost when the hotkey fired — dismissal returns
    /// activation to them.
    private var previousApp: NSRunningApplication?
    private let focusRequest = PanelFocusRequest()
    private let onSubmit: Submit

    /// Per-panel: the quick-capture and meeting-note panels must not
    /// overwrite each other's remembered position.
    private let positionKey: String

    public init(positionKey: String = "dump.capture.origin", onSubmit: @escaping Submit) {
        self.positionKey = positionKey
        self.onSubmit = onSubmit
        // Transient-panel convention: dismiss when the panel stops being key —
        // a click into another app or another Dump window. App-level
        // didResignActive can't drive this: the panel is .nonactivatingPanel,
        // so Dump usually was never the active app in the first place. Routing
        // through close() keeps the exit animation and isShowing in sync
        // (hidesOnDeactivate would orderOut behind PanelAnimator's back).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Notification isn't Sendable — reduce to an identity before
            // hopping onto the main actor.
            let windowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.isShowing,
                      let windowID,
                      let panel = self.panel,
                      windowID == ObjectIdentifier(panel) else { return }
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
    }

    public func close() {
        close(intent: .cancelled)
    }

    /// Submit passes `.committed` so the panel lifts up-and-away along its
    /// entrance axis — the note visibly leaves as "sent". Esc and click-away
    /// keep the neutral exit. Same speed either way: zero added latency.
    func close(intent: PanelDismissIntent) {
        isShowing = false
        guard let panel, !hideInFlight else { return }
        hideInFlight = true
        PanelAnimator.hide(panel, intent: intent) { [weak self] in
            guard let self else { return }
            self.hideInFlight = false
            if self.isShowing {
                // User re-triggered during hide — re-present the same panel.
                self.presentPanel()
            } else {
                // Hand activation back to the app the hotkey interrupted —
                // but only if we still hold it (a click-away means the user
                // already chose somewhere else to be).
                if NSApp.isActive, let previous = self.previousApp, !previous.isTerminated {
                    NSApp.yieldActivation(to: previous)
                    previous.activate()
                }
                self.previousApp = nil
            }
            // Panel retained: hide() already orderOut'd it and reset its
            // transform. Reopening skips the NSPanel + NSHostingController
            // rebuild (near-zero latency to first keystroke), and a cancelled
            // draft (@State text) survives Esc, click-away, and Cmd-Tab — the
            // contract clearOnNextPresent is built around.
        }
    }

    private func presentPanel() {
        if panel == nil {
            let p = Self.makePanel(
                focusRequest: focusRequest,
                onSubmit: onSubmit,
                onClose: { [weak self] in self?.close() },
                onCommitClose: { [weak self] in self?.close(intent: .committed) }
            )
            // The panel ships two drag affordances — remember where the user
            // puts it. Only visible-window moves are user drags; programmatic
            // placement below always happens while hidden.
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: p,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    UserDefaults.standard.set(
                        NSStringFromPoint(panel.frame.origin),
                        forKey: self.positionKey
                    )
                }
            }
            panel = p
        }
        guard let panel else { return }
        // A re-show that interrupts the hide retargets in place instead of
        // teleporting the still-visible panel.
        if !panel.isVisible {
            position(panel)
        }
        // Activation is required for reliable keyboard delivery to a
        // programmatically summoned panel — nonactivating key status is only
        // guaranteed for click activation, and typing right after the hotkey
        // must never leak into the previous app. Remember who was frontmost
        // so close() can hand activation straight back (Spotlight-style);
        // an LSUIElement app otherwise keeps it forever after orderOut.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        PanelAnimator.show(panel, chromeMotion: false)
        focusRequest.request()
    }

    /// Saved drag position when the user has one (and it's still on a
    /// connected screen); otherwise Spotlight placement — horizontally
    /// centered, upper third, on the screen the cursor is on.
    private func position(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: positionKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: vf.midX - size.width / 2,
            y: vf.minY + vf.height * 0.62
        ))
    }

    private static func makePanel(
        focusRequest: PanelFocusRequest,
        onSubmit: @escaping Submit,
        onClose: @escaping @MainActor () -> Void,
        onCommitClose: @escaping @MainActor () -> Void
    ) -> NSPanel {
        let view = CaptureView(
            focusRequest: focusRequest,
            onSubmit: onSubmit,
            onCancel: onClose,
            onCommitClose: onCommitClose
        )
        let host = NSHostingController(rootView: view)
        DumpWindowChrome.prepareHost(host, style: .capture)

        let panel = DumpWindowChrome.makeFloatingPanel(style: .capture)
        panel.contentViewController = host
        // Assigning contentViewController resizes the window to SwiftUI's
        // fitting size — pin the intended panel size back deterministically.
        panel.setContentSize(DumpPanelStyle.capture.size)
        return panel
    }
}

/// Borderless NSPanel that can still become key — required so the
/// SwiftUI `TextEditor`/`TextField` inside the capture/query panels
/// can receive keystrokes without the system chrome of a `.titled` panel.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CaptureView: View {
    @ObservedObject var focusRequest: PanelFocusRequest
    let onSubmit: CaptureWindowController.Submit
    let onCancel: @MainActor () -> Void
    let onCommitClose: @MainActor () -> Void

    @State private var text: String = ""
    /// Set on submit: the text stays visible through the "sent" exit (it's
    /// what sells the lift-away), then clears on the next presentation.
    @State private var clearOnNextPresent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DumpPanelShell(style: .capture) {
            VStack(alignment: .leading, spacing: 0) {
                header
                editor
                // Reserve the strip's slot so a completing token ("tomorrow", "30m")
                // never reflows the editor mid-keystroke — only opacity animates:
                ZStack(alignment: .leading) {
                    if let preview = parsePreview {
                        ParsePreviewStrip(preview: preview)
                            .transition(.opacity)
                    }
                }
                .frame(height: 22, alignment: .leading)
                .padding(.horizontal, DumpUI.Spacing.gutter)
                .padding(.bottom, 8)
                footer
            }
        }
        .onChange(of: focusRequest.token) { _, _ in
            // Cancelled drafts survive a quick reopen; submitted ones don't.
            if clearOnNextPresent {
                text = ""
                clearOnNextPresent = false
            }
        }
        // Keyed on the minute-stable projection, not the raw preview — its
        // Date carries sub-second precision from relative parses, which
        // would re-key this animation on every keystroke.
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: parsePreview?.animationKey)
    }

    /// What the queue's extractor sees in the current text — informational
    /// here; the same signals feed ranking once the entry is saved.
    private var parsePreview: QueueViewModel.ParsePreview? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let metadata = QueueMetadataExtractor.extract(from: body)
        let preview = QueueViewModel.ParsePreview(
            date: metadata.deadlineAt ?? metadata.scheduledAt,
            dateKind: metadata.inferredType == .reminder ? .reminder : .deadline,
            effortMinutes: metadata.effortMinutes,
            importance: metadata.importance
        )
        return preview.isEmpty ? nil : preview
    }

    private var header: some View {
        // No entrance bounce here: this panel opens dozens of times a day,
        // and the spring entrance is already the entrance motion. Symbol
        // bounces are reserved for rare events.
        DumpPanelTitleStrip(
            iconName: "square.and.pencil",
            title: "New entry",
            height: DumpUI.Controls.compactTitleStripHeight,
            horizontalPadding: DumpUI.Spacing.gutter
        )
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            CaptureTextEditor(
                text: $text,
                focusToken: focusRequest.token,
                onSubmit: { submit() },
                onCancel: { onCancel() }
            )

            // Asymmetric on purpose: vanishes instantly on the first
            // keystroke (typing never animates), fades back in over 100ms
            // when the last character is deleted.
            Text("What's on your mind?")
                .font(DumpUI.Typography.captureInput)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
                .opacity(text.isEmpty ? 1 : 0)
                .animation(
                    text.isEmpty ? resolved(Motion.micro, reduceMotion: reduceMotion) : nil,
                    value: text.isEmpty
                )
        }
        .padding(.horizontal, DumpUI.Spacing.gutter)
        .padding(.vertical, 10)
        .frame(minHeight: 80, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("return", "save")
            Divider().frame(height: 10)
            keyHint("shift", "return", joiner: "+", action: "new line")
            Divider().frame(height: 10)
            keyHint("esc", "cancel")
            Spacer()
            if !text.isEmpty {
                // The count itself must never animate — it changes per
                // keystroke. Only its appearance/disappearance (an
                // isEmpty boundary) gets a 100ms fade.
                Text("\(text.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DumpUI.Spacing.gutter)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4))
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: text.isEmpty)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            keyCap(key)
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func keyHint(_ k1: String, _ k2: String, joiner: String, action: String) -> some View {
        HStack(spacing: 5) {
            keyCap(k1)
            Text(joiner)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            keyCap(k2)
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func keyCap(_ k: String) -> some View {
        Text(k)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DumpUI.Radius.keyCap))
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            onCancel()
            return
        }
        // Keep the text on screen through the committed exit — the note
        // visibly lifts away as "sent". It clears on the next presentation.
        clearOnNextPresent = true
        onCommitClose()
        onSubmit(body)
    }
}

/// NSTextView-backed editor for the capture panel. Gives us a real
/// macOS text editor — cursor-position newline insertion on Shift+Return,
/// proper multi-line editing, undo, IME support — instead of fighting
/// SwiftUI's `TextField(axis: .vertical)`.
private struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CaptureNSTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: DumpUI.Typography.captureInputSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Entry text")

        context.coordinator.install(on: textView)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CaptureNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            textView.focus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTextEditor
        var lastFocusToken: Int?

        init(_ parent: CaptureTextEditor) {
            self.parent = parent
        }

        func install(on textView: CaptureNSTextView) {
            textView.onSubmit = { [weak self] in self?.parent.onSubmit() }
            textView.onCancel = { [weak self] in self?.parent.onCancel() }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class CaptureNSTextView: NSTextView {
    var onSubmit: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder once we're in a window. Done synchronously
        // so the panel's makeKeyAndOrderFront finds us in its responder chain
        // immediately rather than racing an async dispatch.
        focus()
    }

    func focus() {
        _ = window?.makeFirstResponder(self)
    }

    // Return → submit; Shift+Return → newline at cursor.
    // AppKit routes both to `insertNewline:` — the only way to tell them apart
    // is to inspect the current event's modifiers.
    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            insertText("\n", replacementRange: selectedRange())
            return
        }
        onSubmit?()
    }

    // Some key-binding setups also route to `insertLineBreak:` — handle it the
    // same way so Shift+Return is consistent regardless of system bindings.
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    // Escape → dismiss
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

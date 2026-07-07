import AppKit
import SwiftUI

/// Spotlight-style floating panel for quick capture. Closes immediately on
/// Enter — classification and indexing happen after the window is gone.
@MainActor
public final class CaptureWindowController {
    public typealias Submit = @MainActor (String) async -> Void

    private var panel: NSPanel?
    // `isShowing` tracks user *intent* and is updated synchronously. Don't
    // gate `toggle()` on `panel.isVisible` — the panel is still visible
    // during the ~130ms hide animation, so a hotkey press mid-animation
    // would re-close instead of re-opening.
    private var isShowing = false
    private var hideInFlight = false
    private var deactivateObserver: NSObjectProtocol?
    private let focusRequest = PanelFocusRequest()
    private let onSubmit: Submit

    public init(onSubmit: @escaping Submit) {
        self.onSubmit = onSubmit
        // Replace `panel.hidesOnDeactivate = true` — that path orderOut's the
        // panel without going through PanelAnimator, leaving our state out of
        // sync with what the user sees. Route auto-dismiss through close() so
        // the animation runs and `isShowing`/`panel` stay consistent.
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
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
        isShowing = false
        guard let panel, !hideInFlight else { return }
        hideInFlight = true
        PanelAnimator.hide(panel) { [weak self] in
            guard let self else { return }
            self.hideInFlight = false
            if self.isShowing {
                // User re-triggered during hide — re-present the same panel.
                self.presentPanel()
            } else {
                self.panel = nil
            }
        }
    }

    private func presentPanel() {
        if panel == nil {
            panel = Self.makePanel(
                focusRequest: focusRequest,
                onSubmit: onSubmit,
                onClose: { [weak self] in self?.close() }
            )
        }
        guard let panel else { return }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        PanelAnimator.show(panel)
        focusRequest.request()
    }

    private static func makePanel(
        focusRequest: PanelFocusRequest,
        onSubmit: @escaping Submit,
        onClose: @escaping @MainActor () -> Void
    ) -> NSPanel {
        let view = CaptureView(focusRequest: focusRequest, onSubmit: onSubmit, onCancel: onClose)
        let host = NSHostingController(rootView: view)
        DumpWindowChrome.prepareHost(host, style: .capture)

        let panel = DumpWindowChrome.makeFloatingPanel(style: .capture)
        panel.contentViewController = host
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

    @State private var text: String = ""
    @State private var headerBounce: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DumpPanelShell(style: .capture) {
            VStack(alignment: .leading, spacing: 0) {
                header
                editor
                footer
            }
        }
        .onAppear { headerBounce += 1 }
    }

    private var header: some View {
        DumpPanelTitleStrip(
            iconName: "square.and.pencil",
            title: "New entry",
            height: DumpUI.Controls.compactTitleStripHeight,
            horizontalPadding: DumpUI.Spacing.xxxl,
            iconBounceValue: headerBounce
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

            if text.isEmpty {
                Text("What's on your mind?")
                    .font(.system(size: 17))
                    .foregroundColor(Color.primary.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 20)
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
                Text("\(text.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(countsDown: false))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.7, anchor: .trailing)),
                        removal: .opacity
                    ))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4))
        .animation(resolved(Motion.bouncy, reduceMotion: reduceMotion), value: text.isEmpty)
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
        text = ""
        onCancel()
        Task { await onSubmit(body) }
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
        textView.font = .systemFont(ofSize: 17)
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

import AppKit
import SwiftUI
import Wave

/// App-wide design tokens and shared chrome primitives for Dump's floating
/// windows. The concrete values intentionally mirror the existing capture,
/// query, and queue panels so this file can become the foundation without
/// changing their behavior.
enum DumpUI {
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 14
        static let xxl: CGFloat = 16
        static let xxxl: CGFloat = 18
        static let panel: CGFloat = 20
        static let window: CGFloat = 24
        /// Named role for panel content gutters (empty states, list insets).
        static let gutter: CGFloat = 20
    }

    enum Radius {
        static let keyCap: CGFloat = 4
        static let control: CGFloat = 8
        static let surface: CGFloat = 10
        static let card: CGFloat = 14
        static let panel: CGFloat = 16
    }

    enum Typography {
        static let titleStrip: Font = .system(size: 12, weight: .semibold)
        static let caption: Font = .system(size: 11)
        static let captionStrong: Font = .system(size: 11, weight: .semibold, design: .rounded)
        static let control: Font = .system(size: 13, weight: .semibold)
        static let body: Font = .system(size: 14.5)
        static let bodyStrong: Font = .system(size: 14.5, weight: .semibold)
        static let input: Font = .system(size: 16)
        /// Shared with the AppKit-side NSTextView in the capture window, which
        /// can't consume a SwiftUI `Font` directly.
        static let captureInputSize: CGFloat = 17
        static let captureInput: Font = .system(size: captureInputSize)
        static let emptyStateIcon: Font = .system(size: 38, weight: .light)
        static let emptyStateTitle: Font = .system(size: 16, weight: .medium)
    }

    enum Controls {
        static let iconButton = CGSize(width: 24, height: 24)
        static let smallIconButton = CGSize(width: 22, height: 22)
        static let titleStripHeight: CGFloat = 34
        static let compactTitleStripHeight: CGFloat = 32
        static let dragStripHeight: CGFloat = 28
        static let fieldVerticalPadding: CGFloat = 10
        static let fieldHorizontalPadding: CGFloat = 14
    }

    enum PanelSize {
        /// Height budgets the always-reserved parse-preview slot (22 + 8pt) —
        /// it must not be paid out of the editor's typing room.
        static let capture = NSSize(width: 640, height: 210)
        static let captureMinimum = NSSize(width: 520, height: 190)
        static let query = NSSize(width: 720, height: 520)
        static let queryMinimum = NSSize(width: 560, height: 420)
        static let queue = NSSize(width: 560, height: 620)
        static let queueMinimum = NSSize(width: 440, height: 420)
    }

    enum SemanticStyle {
        static let panelMaterial: NSVisualEffectView.Material = .hudWindow
        static let panelFallback = Color(nsColor: .windowBackgroundColor)
        static let hairline = Color(nsColor: .separatorColor).opacity(0.6)
        static let subtleFill = Color.primary.opacity(0.025)
        static let hoverFill = Color.primary.opacity(0.045)
        static let selectedFill = Color.primary.opacity(0.075)
        static let focusStroke = Color.accentColor.opacity(0.45)
        static let unfocusedStroke = Color.accentColor.opacity(0.14)
        static let contentFill = Color(nsColor: .textBackgroundColor).opacity(0.92)
        static let contentStroke = Color(nsColor: .separatorColor).opacity(0.65)
    }

    enum Motion {
        /// 100ms ease-out-expo. Hover affordances, button feedback, keystroke-adjacent UI.
        static let micro: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.10)

        /// 160ms ease-out-expo. Default for state changes — clear button, mode picker,
        /// loading/results swap, footer chrome.
        static let snappy: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.16)

        /// 200ms Vaul curve. Slightly weightier — used for panel content appearing.
        static let sheet: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.20)

        /// Snappy interactive spring. Hit card hover scale, chip nudges — anything
        /// that should track the cursor and settle without bounce.
        static let interactive: Animation = .spring(response: 0.28, dampingFraction: 0.84)

        /// Drawer-feel spring with a touch of overshoot. Panel scale-in, hit-card lift.
        static let panel: Animation = .spring(response: 0.32, dampingFraction: 0.78)

        /// Tighter spring with a hint of overshoot. Results stagger, step transitions.
        static let bouncy: Animation = .spring(response: 0.36, dampingFraction: 0.74)

        /// Press feedback — extra-tight so the scale snaps back instantly.
        static let press: Animation = .spring(response: 0.18, dampingFraction: 0.72)

        /// 130ms ease-in. Removals and dismissals — things accelerate away.
        /// Mirrors the AppKit-side `Window.easeInExit` curve so SwiftUI and
        /// panel chrome can't drift apart.
        static let exit: Animation = .timingCurve(0.4, 0, 1, 1, duration: 0.13)

        /// Physics for the floating-panel chrome. One definition shared by
        /// PanelAnimator/PanelWaveTransform so all three panels — and any
        /// future chrome like the pin settle-dip — move identically.
        /// Main-actor because Wave's `Spring` and CAMediaTimingFunction are
        /// reference types.
        @MainActor
        enum Window {
            static let showSpring = Spring(dampingRatio: 0.82, response: 0.32)
            static let showDropSpring = Spring(dampingRatio: 0.88, response: 0.30)
            /// Critically damped and quick — exits should not bounce.
            static let exitSpring = Spring(dampingRatio: 1.0, response: 0.18)
            static let showFadeDuration: TimeInterval = 0.18
            static let hideFadeDuration: TimeInterval = 0.13
            static let entranceScale: CGFloat = 0.94
            /// The entrance lands from a +6pt offset. Exits reuse the same
            /// axis so dismissal retraces the arrival path.
            static let entranceDrop: CGFloat = 6
            static let cancelScale: CGFloat = 0.97
            static let cancelDrop: CGFloat = 6
            /// Committed exits (submit, open) lift further along the entrance
            /// axis — the panel visibly leaves as "sent".
            static let commitScale: CGFloat = 0.965
            static let commitDrop: CGFloat = 10
            static let easeOutExpo = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            static let easeInExit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        }

        /// Physics for the queue's swipe-to-complete. The threshold constant
        /// is shared by the haptic tick, the checkmark pop, and the commit
        /// decision, so it must exist exactly once.
        @MainActor
        enum Swipe {
            static let settleSpring = Spring(dampingRatio: 0.86, response: 0.30)
            static let commitThreshold: CGFloat = 76
            /// Hysteresis: once past `commitThreshold`, the commit only
            /// disengages below this — jitter at the boundary can't
            /// machine-gun haptics.
            static let releaseThreshold: CGFloat = 64
            static let maxDrag: CGFloat = 104
            /// Overdrag resistance past `maxDrag`, matching scroll-edge feel.
            static let rubberBand: CGFloat = 0.18
        }
    }
}

/// Motion tokens. A small, cohesive set of curves and springs used app-wide so
/// every panel, transition, and hover feels like the same product. Power-user
/// app: defaults skew short and snappy.
enum Motion {
    /// 100ms ease-out-expo. Hover affordances, button feedback, keystroke-adjacent UI.
    static let micro = DumpUI.Motion.micro

    /// 160ms ease-out-expo. Default for state changes — clear button, mode picker,
    /// loading/results swap, footer chrome.
    static let snappy = DumpUI.Motion.snappy

    /// 200ms Vaul curve. Slightly weightier — used for panel content
    /// appearing and onboarding step transitions.
    static let sheet = DumpUI.Motion.sheet

    /// Snappy interactive spring. Hit card hover scale, chip nudges — anything
    /// that should track the cursor and settle without bounce.
    static let interactive = DumpUI.Motion.interactive

    /// Drawer-feel spring with a touch of overshoot. Panel scale-in, hit-card lift.
    static let panel = DumpUI.Motion.panel

    /// Tighter spring with a hint of overshoot. Results stagger, step transitions.
    static let bouncy = DumpUI.Motion.bouncy

    /// Press feedback — extra-tight so the scale snaps back instantly.
    static let press = DumpUI.Motion.press

    /// 130ms ease-in. Removals and dismissals — things accelerate away.
    static let exit = DumpUI.Motion.exit
}

/// Tactile press feedback. Drop-in replacement for `.buttonStyle(.plain)` — same
/// visuals, plus a 0.985 scale-down with a quick spring back on release.
/// Press-in applies instantly (nil animation) so quick clicks never feel
/// mushy; only the release springs back. Reduce-motion keeps the opacity dip
/// and holds scale at 1.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.985
    var pressedOpacity: Double = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? pressedScale : 1), anchor: .center)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(
                configuration.isPressed
                    ? nil
                    : (reduceMotion ? .easeOut(duration: 0.12) : Motion.press),
                value: configuration.isPressed
            )
    }
}

/// Resolves a motion preference against the system's reduce-motion setting.
/// `reduced` falls back to a quick fade (never "no motion at all") and is what
/// the documented Apple guidance actually wants.
@MainActor
func resolved(_ animation: Animation, reduceMotion: Bool, reduced: Animation? = nil) -> Animation {
    reduceMotion ? (reduced ?? .easeOut(duration: 0.12)) : animation
}

/// Transition counterpart of `resolved(_:reduceMotion:)`: any transition that
/// moves or scales collapses to a plain crossfade under reduce motion —
/// fade-not-nothing, applied consistently at every call site.
@MainActor
func reducedTransition(_ full: AnyTransition, reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : full
}

/// Shared transition for the ✕ clear buttons in the query and queue input
/// fields, so the two fields can't drift apart.
@MainActor
func clearButtonTransition(reduceMotion: Bool) -> AnyTransition {
    reducedTransition(
        .asymmetric(
            insertion: .scale(scale: 0.5, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.7, anchor: .center).combined(with: .opacity)
        ),
        reduceMotion: reduceMotion
    )
}

/// Bridge NSVisualEffectView into SwiftUI so panels can sit on the
/// window-level material instead of a solid colour. Used as the base
/// background of both the query and capture panels.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

extension View {
    /// Apply Liquid Glass on macOS 26+, falling back to an ultra-thin
    /// material on earlier systems so the app still looks correct on
    /// macOS 14, 15, etc. Xcode 16 cannot parse the macOS 26 glass APIs,
    /// so it compiles the same fallback for every deployment target.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(DumpUI.SemanticStyle.hairline, lineWidth: 0.5))
        }
#else
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(DumpUI.SemanticStyle.hairline, lineWidth: 0.5))
#endif
    }
}

/// Wraps content in a `GlassEffectContainer` on macOS 26+ so multiple
/// nearby glass surfaces blend their refraction. No-op on older systems.
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
#else
        content()
#endif
    }
}

enum DumpPanelStyle {
    case capture
    case query
    case queue

    var size: NSSize {
        switch self {
        case .capture: DumpUI.PanelSize.capture
        case .query: DumpUI.PanelSize.query
        case .queue: DumpUI.PanelSize.queue
        }
    }

    var minimumSize: NSSize {
        switch self {
        case .capture: DumpUI.PanelSize.captureMinimum
        case .query: DumpUI.PanelSize.queryMinimum
        case .queue: DumpUI.PanelSize.queueMinimum
        }
    }

    var cornerRadius: CGFloat { DumpUI.Radius.panel }
    var material: NSVisualEffectView.Material { DumpUI.SemanticStyle.panelMaterial }
}

/// Shared background and clipped frame for Dump's floating utility panels.
/// Keeps the visual-effect substrate, reduced-transparency fallback, rounded
/// shape, and glass grouping consistent while letting each panel own its
/// interaction model.
struct DumpPanelShell<Content: View>: View {
    var style: DumpPanelStyle
    var alignment: Alignment = .center
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: alignment) {
            if reduceTransparency {
                DumpUI.SemanticStyle.panelFallback
                    .opacity(0.96)
                    .ignoresSafeArea()
            } else {
                VisualEffectBackground(material: style.material)
                    .ignoresSafeArea()
            }

            LiquidGlassGroup {
                content()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .strokeBorder(DumpUI.SemanticStyle.hairline, lineWidth: 0.5)
        )
        .frame(minWidth: style.minimumSize.width, minHeight: style.minimumSize.height)
    }
}

/// Shared "quiet surface" treatment for content panels: a subtle fill plus a
/// hairline stroke, matching the per-window queueQuietSurface/queryQuietSurface
/// modifiers this replaces so all three panels can't drift apart.
struct DumpQuietSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)

        content
            .background(shape.fill(DumpUI.SemanticStyle.contentFill))
            .overlay(shape.strokeBorder(DumpUI.SemanticStyle.contentStroke, lineWidth: 0.5))
    }
}

extension View {
    func dumpQuietSurface(cornerRadius: CGFloat) -> some View {
        modifier(DumpQuietSurface(cornerRadius: cornerRadius))
    }
}

/// Small monospaced key-cap chip, used for keyboard-shortcut hints.
struct KeyCap: View {
    let key: String
    var size: CGFloat = 11

    var body: some View {
        Text(key)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DumpUI.Radius.keyCap))
            .foregroundStyle(.secondary)
    }
}

/// Centralizes the ✕ clear-button treatment shared by the query and queue
/// input fields, so the two fields can't drift apart.
struct DumpClearButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .foregroundStyle(Color.primary.opacity(0.55))
            .labelStyle(.iconOnly)
    }
}

extension View {
    func dumpClearButtonStyle() -> some View {
        modifier(DumpClearButtonStyle())
    }
}

struct DumpPanelDragStrip: View {
    var height: CGFloat = DumpUI.Controls.dragStripHeight

    var body: some View {
        WindowDragHandle()
            .frame(height: height)
    }
}

struct DumpPanelTitleStrip<Actions: View>: View {
    var iconName: String
    var title: String
    var badge: String?
    var height: CGFloat = DumpUI.Controls.titleStripHeight
    var horizontalPadding: CGFloat = DumpUI.Spacing.xxl
    var iconBounceValue: Int?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        iconName: String,
        title: String,
        badge: String? = nil,
        height: CGFloat = DumpUI.Controls.titleStripHeight,
        horizontalPadding: CGFloat = DumpUI.Spacing.xxl,
        iconBounceValue: Int? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.iconName = iconName
        self.title = title
        self.badge = badge
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.iconBounceValue = iconBounceValue
        self.actions = actions
    }

    var body: some View {
        ZStack(alignment: .leading) {
            WindowDragHandle()

            HStack(spacing: DumpUI.Spacing.sm) {
                titleIcon
                Text(title)
                    .font(DumpUI.Typography.titleStrip)
                    .foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(DumpUI.Typography.captionStrong)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                }
                Spacer(minLength: 0)
                actions()
            }
            .padding(.horizontal, horizontalPadding)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var titleIcon: some View {
        let icon = Image(systemName: iconName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tint)
            .symbolRenderingMode(.hierarchical)

        if let iconBounceValue, !reduceMotion {
            icon.symbolEffect(.bounce.up, value: iconBounceValue)
        } else {
            icon
        }
    }
}

/// Centralized NSPanel setup for the app's borderless floating windows. This
/// keeps AppKit configuration in one place while the shell handles SwiftUI
/// visuals.
@MainActor
enum DumpWindowChrome {
    static func prepareHost<Content: View>(
        _ host: NSHostingController<Content>,
        style: DumpPanelStyle
    ) {
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = style.cornerRadius
        host.view.layer?.cornerCurve = .continuous
        host.view.layer?.masksToBounds = true
    }

    static func makeFloatingPanel(
        style: DumpPanelStyle,
        resizable: Bool = false
    ) -> KeyablePanel {
        var styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable {
            styleMask.insert(.resizable)
        }

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: style.size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        if resizable {
            panel.minSize = style.minimumSize
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        // NSPanel defaults hidesOnDeactivate to true — AppKit would orderOut()
        // the panel on app deactivation, skipping PanelAnimator.hide and
        // desyncing the controllers' isShowing/hideInFlight. The controllers
        // route auto-dismiss through close() instead.
        panel.hidesOnDeactivate = false
        // Appear over whatever Space or full-screen app the user is in, like
        // Spotlight — the default ([]) pins the panel to its creation Space
        // and forces a Space switch on every summon.
        // QueueWindowController may override this per pin state.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }
}

@MainActor
final class PanelFocusRequest: ObservableObject {
    @Published private(set) var token = 0

    func request() {
        token += 1
    }
}

/// AppKit-level input focus for the query/queue panels' text fields.
///
/// Focus on open is deliberately NOT driven through SwiftUI's `@FocusState`:
/// a programmatic write is dropped while the hosting window isn't key, and —
/// observed live on macOS 26 — can be silently swallowed even with the panel
/// key and the app active (the write never reaches the field's backing view).
/// `NSWindow.makeFirstResponder` on that backing view is deterministic, works
/// even before key status lands (the responder is simply already in place
/// when it does — the capture panel's NSTextView relies on the same
/// property), and SwiftUI syncs `FocusState` FROM the responder change, so
/// focus-dependent styling still engages.
@MainActor
enum PanelInputFocus {
    /// Make the panel's first editable text view the first responder.
    /// Retries across a few runloop turns: on a freshly created panel the
    /// SwiftUI hierarchy may not have materialized its AppKit backing views
    /// by the time the controller presents.
    static func focus(in panel: NSPanel, attempts: Int = 8) {
        guard let target = findEditableTextInput(panel.contentView) else {
            guard attempts > 1 else { return }
            Task { @MainActor [weak panel] in
                await Task.yield()
                guard let panel else { return }
                focus(in: panel, attempts: attempts - 1)
            }
            return
        }
        // Already editing this field (re-summon of an open panel): leave the
        // session alone. makeFirstResponder would end it and re-begin via
        // selectText, select-alling the draft so the next keystroke replaces
        // it. An NSTextField edit puts its field editor (whose delegate is
        // the field) first, so check both shapes.
        if panel.firstResponder === target { return }
        if let editor = panel.firstResponder as? NSText, editor.delegate === target { return }
        panel.makeFirstResponder(target)
    }

    private static func findEditableTextInput(_ view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        if let text = view as? NSTextView, text.isEditable { return text }
        for sub in view.subviews {
            if let found = findEditableTextInput(sub) { return found }
        }
        return nil
    }
}

/// Makes a SwiftUI view a window-drag region. Apply to the title strip
/// of borderless panels so the user can still move them around.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// How a panel is leaving. Committed exits (submit, open) lift further along
/// the entrance axis so the dismissal reads as "sent"; cancelled exits retrace
/// the arrival path neutrally. Both are Wave retargets, so a dismissal that
/// interrupts the entrance redirects the in-flight spring instead of snapping.
enum PanelDismissIntent {
    case cancelled
    case committed
}

/// Animated panel presentation. Mirrors Raycast/Spotlight: spring-driven scale
/// with a small Y drop so the panel lands from above. Reduce-motion users get
/// a flat fade.
@MainActor
enum PanelAnimator {
    private static var waveTransforms: [ObjectIdentifier: PanelWaveTransform] = [:]
    private static var generations: [ObjectIdentifier: Int] = [:]

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Show with a spring scale-up, small Y drop, and ease-out fade.
    /// `chromeMotion: false` skips the scale/drop spring entirely — a bare
    /// near-zero fade for surfaces under the frequency rule (the capture
    /// panel opens dozens of times a day; Raycast-class HUDs don't animate).
    static func show(_ panel: NSPanel, chromeMotion: Bool = true) {
        guard let layer = panel.contentView?.layer else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let reduced = reduceMotion
        let id = ObjectIdentifier(panel)
        let wasVisible = panel.isVisible
        generations[id, default: 0] += 1

        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)

        if reduced || !chromeMotion {
            // A show interrupting a hide must clear the in-flight exit
            // transform, or the panel sticks at cancelScale/cancelDrop —
            // hide() still animates the exit for this panel.
            if let transform = waveTransforms[id] {
                transform.stopAndReset()
                waveTransforms[id] = nil
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduced ? 0.12 : 0.08
                ctx.timingFunction = DumpUI.Motion.Window.easeOutExpo
                panel.animator().alphaValue = 1
            }
            return
        }

        // Fade with a quick ease-out so we don't see anything mid-spring.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DumpUI.Motion.Window.showFadeDuration
            ctx.timingFunction = DumpUI.Motion.Window.easeOutExpo
            panel.animator().alphaValue = 1
        }

        let transform = waveTransforms[id] ?? PanelWaveTransform(layer: layer)
        waveTransforms[id] = transform
        transform.show(fromRest: !wasVisible)
    }

    /// One-shot physical acknowledgment on an already-visible panel: a small
    /// velocity impulse into the drop spring so the panel dips ~2pt and
    /// settles back. Used when pinning the queue — the panel "anchors" itself.
    static func nudge(_ panel: NSPanel) {
        guard !reduceMotion, panel.isVisible, let layer = panel.contentView?.layer else { return }
        let id = ObjectIdentifier(panel)
        let transform = waveTransforms[id] ?? PanelWaveTransform(layer: layer)
        waveTransforms[id] = transform
        transform.impulse()
    }

    /// Hide with a fast fade-out + slight scale-down, then `orderOut`.
    static func hide(
        _ panel: NSPanel,
        intent: PanelDismissIntent = .cancelled,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard panel.isVisible else { completion?(); return }
        let reduced = reduceMotion
        let duration = reduced ? 0.10 : DumpUI.Motion.Window.hideFadeDuration
        let layer = panel.contentView?.layer
        let id = ObjectIdentifier(panel)
        generations[id, default: 0] += 1
        let generation = generations[id] ?? 0

        if !reduced, let layer {
            let transform = waveTransforms[id] ?? PanelWaveTransform(layer: layer)
            waveTransforms[id] = transform
            transform.hide(intent: intent)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = DumpUI.Motion.Window.easeInExit
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // NSAnimationContext's completion is nominally non-isolated; the
            // animation system invokes it on the main thread, so re-enter the
            // main actor explicitly to satisfy strict concurrency.
            MainActor.assumeIsolated {
                guard generations[id] == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                if let l = panel.contentView?.layer {
                    waveTransforms[id]?.stopAndReset()
                    waveTransforms[id] = nil
                    resetTransform(l)
                }
                generations[id] = nil
                // macOS won't auto-promote a remaining .nonactivatingPanel to
                // key when the current key panel orders out — leaving the user
                // with no key window, so Esc/Cmd-W don't reach the visible panel
                // until they click it. Only when Dump is the active app: a
                // nonactivating capture dismissed over another app must hand
                // keyboard focus back to that app, never grab it for a pinned
                // panel — and the status-item window must never be promoted,
                // hence the type filter.
                if NSApp.isActive,
                   let next = NSApp.windows.first(where: {
                       $0 !== panel && $0.isVisible && $0.canBecomeKey
                           && ($0 is KeyablePanel || $0.styleMask.contains(.titled))
                   }) {
                    next.makeKey()
                }
                completion?()
            }
        })
    }

    private static func resetTransform(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

// MARK: - Flow layout for citation chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width.isFinite ? width : rows.map { $0.width }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                let size = entry.size
                subviews[entry.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let prospectiveWidth = current.width + (current.entries.isEmpty ? 0 : spacing) + size.width
            if prospectiveWidth > maxWidth, !current.entries.isEmpty {
                rows.append(current)
                current = Row()
            }
            if !current.entries.isEmpty { current.width += spacing }
            current.entries.append(.init(index: i, size: size))
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.entries.isEmpty { rows.append(current) }
        return rows
    }

    struct Row {
        struct Entry { let index: Int; let size: CGSize }
        var entries: [Entry] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

@MainActor
private final class PanelWaveTransform: @unchecked Sendable {
    private weak var layer: CALayer?
    private var scale: CGFloat = 1
    private var drop: CGFloat = 0
    /// Set by stopAndReset(): tick Tasks enqueued before the reset check it
    /// on arrival and drop themselves, so a stale exit-spring value can't be
    /// re-applied to a layer that was just reset to identity. One-way — the
    /// transform is always discarded after stopAndReset().
    private var stopped = false
    private let scaleAnimator: SpringAnimator<CGFloat>
    private let dropAnimator: SpringAnimator<CGFloat>

    init(layer: CALayer) {
        self.layer = layer
        self.scaleAnimator = SpringAnimator<CGFloat>(spring: DumpUI.Motion.Window.showSpring)
        self.dropAnimator = SpringAnimator<CGFloat>(spring: DumpUI.Motion.Window.showDropSpring)

        // Wave ticks arrive on CVDisplayLink's own thread on macOS — NOT the
        // main thread — so this must hop, never assumeIsolated. Main-actor
        // jobs run FIFO, so ticks stay ordered; the `stopped` gate is what
        // keeps a hop enqueued before stopAndReset() from landing after it.
        scaleAnimator.valueChanged = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.scale = value
                self.apply()
            }
        }
        dropAnimator.valueChanged = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.drop = value
                self.apply()
            }
        }
    }

    func show(fromRest: Bool) {
        // Re-install the entrance physics — a show that interrupts a hide
        // reverses with preserved velocity on the entrance springs, not the
        // stiffer exit ones.
        scaleAnimator.spring = DumpUI.Motion.Window.showSpring
        dropAnimator.spring = DumpUI.Motion.Window.showDropSpring
        if fromRest {
            scale = DumpUI.Motion.Window.entranceScale
            drop = DumpUI.Motion.Window.entranceDrop
            scaleAnimator.value = scale
            dropAnimator.value = drop
            apply()
        }
        retarget(scale: 1, drop: 0)
    }

    func hide(intent: PanelDismissIntent) {
        // Exits are critically damped and quick; both intents retrace the
        // entrance axis (same drop sign), committed just travels further.
        scaleAnimator.spring = DumpUI.Motion.Window.exitSpring
        dropAnimator.spring = DumpUI.Motion.Window.exitSpring
        switch intent {
        case .cancelled:
            retarget(scale: DumpUI.Motion.Window.cancelScale, drop: DumpUI.Motion.Window.cancelDrop)
        case .committed:
            retarget(scale: DumpUI.Motion.Window.commitScale, drop: DumpUI.Motion.Window.commitDrop)
        }
    }

    /// Velocity-only kick into the drop spring: target stays at rest, so the
    /// panel dips a couple of points and springs back. Wave preserves
    /// caller-set velocity across start(), and an unpin mid-dip retargets
    /// smoothly.
    func impulse() {
        if dropAnimator.value == nil { dropAnimator.value = drop }
        dropAnimator.spring = DumpUI.Motion.Window.showDropSpring
        dropAnimator.target = 0
        dropAnimator.velocity = 220
        dropAnimator.start()
    }

    func stopAndReset() {
        stopped = true
        scaleAnimator.stop()
        dropAnimator.stop()
        scale = 1
        drop = 0
        apply()
    }

    private func retarget(scale targetScale: CGFloat, drop targetDrop: CGFloat) {
        if scaleAnimator.value == nil { scaleAnimator.value = scale }
        if dropAnimator.value == nil { dropAnimator.value = drop }
        scaleAnimator.target = targetScale
        dropAnimator.target = targetDrop
        scaleAnimator.start()
        dropAnimator.start()
    }

    private func apply() {
        guard let layer else { return }
        // Scale about the visual center regardless of the layer's
        // anchorPoint (transforms apply about the anchor):
        //   p' = s·p + (1−s)·(center − anchor) + (0, drop)
        // Computed from bounds — well-defined under any active transform,
        // unlike anchorPoint/frame round-trips which read `frame` while the
        // transform is non-identity.
        let bounds = layer.bounds
        let anchor = CGPoint(
            x: bounds.minX + layer.anchorPoint.x * bounds.width,
            y: bounds.minY + layer.anchorPoint.y * bounds.height
        )
        let tx = (1 - scale) * (bounds.midX - anchor.x)
        let ty = (1 - scale) * (bounds.midY - anchor.y) + drop
        var t = CATransform3DMakeTranslation(tx, ty, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = t
        CATransaction.commit()
    }
}

import AppKit
import SwiftUI

@MainActor
public final class QueryWindowController {
    public typealias OnRun = @MainActor (String, QueryMode) async -> Void

    private var panel: NSPanel?
    // `isShowing` tracks user *intent* and is updated synchronously. Don't
    // gate `toggle()` on `panel.isVisible` — the panel is still visible
    // during the ~130ms hide animation, so a hotkey press mid-animation
    // would re-close instead of re-opening.
    private var isShowing = false
    private var hideInFlight = false
    private var deactivateObserver: NSObjectProtocol?
    private let focusRequest = PanelFocusRequest()
    private let viewModel: QueryViewModel

    public init(viewModel: QueryViewModel) {
        self.viewModel = viewModel
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
                // User re-triggered during hide — re-present the same panel
                // without resetting the view model so their query survives.
                self.presentPanel()
            } else {
                self.viewModel.reset()
                self.panel = nil
            }
        }
    }

    private func presentPanel() {
        if panel == nil {
            let view = QueryView(
                viewModel: viewModel,
                focusRequest: focusRequest,
                onCancel: { [weak self] in self?.close() }
            )
            let host = NSHostingController(rootView: view)
            DumpWindowChrome.prepareHost(host, style: .query)

            // 720×520 is enough for the single-column results list with
            // one-line titles. The panel is resizable, so power users can
            // widen it if they're skimming PDF excerpts.
            let p = DumpWindowChrome.makeFloatingPanel(style: .query, resizable: true)
            p.contentViewController = host
            panel = p
        }
        guard let panel else { return }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        PanelAnimator.show(panel)
        focusRequest.request()
    }
}

public enum QueryMode: String, CaseIterable, Sendable, Identifiable {
    case search, ask
    public var id: String { rawValue }
    public var label: String { self == .search ? "Search" : "Ask" }
    public var toggled: QueryMode { self == .search ? .ask : .search }
}

/// What the user is currently focused on in the results pane. Drives which
/// preview shows on the right — the LLM answer or a specific hit.
public enum QuerySelection: Hashable, Sendable {
    case answer
    case hit(String)
}

@MainActor
public final class QueryViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public var lastRunQuery: String = ""
    @Published public var mode: QueryMode = .search
    @Published public var hits: [QueryEngine.Hit] = []
    @Published public var answer: SynthesisResult?
    @Published public var isLoading: Bool = false
    @Published public var error: String?
    @Published public var selection: QuerySelection?

    private let engine: QueryEngine
    private let synthesizer: Synthesizing

    public init(engine: QueryEngine, synthesizer: Synthesizing) {
        self.engine = engine
        self.synthesizer = synthesizer
    }

    public func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        answer = nil
        hits = []
        selection = nil
        do {
            let results = try await engine.search(q, limit: 10)
            hits = results
            lastRunQuery = q
            if mode == .ask, !results.isEmpty {
                answer = try await synthesizer.synthesize(query: q, hits: results)
            }
            // Default selection — answer if we have one, else first hit.
            if answer != nil {
                selection = .answer
            } else if let first = results.first {
                selection = .hit(first.id)
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    public func reset() {
        query = ""
        lastRunQuery = ""
        hits = []
        answer = nil
        error = nil
        selection = nil
    }

    /// Hit corresponding to the current selection, or nil if the answer is
    /// selected (or nothing is).
    public var selectedHit: QueryEngine.Hit? {
        guard case .hit(let id) = selection else { return nil }
        return hits.first(where: { $0.id == id })
    }

    public var isAnswerSelected: Bool {
        if case .answer = selection { return true }
        return false
    }

    /// Move selection one step down in the rail (answer → hit 1 → hit 2 …).
    /// Clamps at the end.
    public func selectNext() {
        let order = selectionOrder()
        guard !order.isEmpty else { return }
        if let current = selection, let idx = order.firstIndex(of: current) {
            selection = order[min(idx + 1, order.count - 1)]
        } else {
            selection = order.first
        }
    }

    /// Move selection one step up. Clamps at the start.
    public func selectPrevious() {
        let order = selectionOrder()
        guard !order.isEmpty else { return }
        if let current = selection, let idx = order.firstIndex(of: current) {
            selection = order[max(idx - 1, 0)]
        } else {
            selection = order.first
        }
    }

    private func selectionOrder() -> [QuerySelection] {
        var order: [QuerySelection] = []
        if answer != nil { order.append(.answer) }
        order.append(contentsOf: hits.map { .hit($0.id) })
        return order
    }
}

// MARK: - View

struct QueryView: View {
    @ObservedObject var viewModel: QueryViewModel
    @ObservedObject var focusRequest: PanelFocusRequest
    let onCancel: @MainActor () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DumpPanelShell(style: .query) {
            VStack(spacing: 0) {
                titleStrip
                searchHeader
                content
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
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.mode)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.isLoading)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.error)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.answer?.text)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.hits.count)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.selection)
    }

    private func requestInputFocus() {
        focused = false
        Task { @MainActor in
            focused = true
        }
    }

    // A slim drag strip that lets the user move the window without
    // taking visual weight from the search bar.
    private var titleStrip: some View {
        DumpPanelDragStrip()
    }

    private var searchHeader: some View {
        LiquidGlassGroup {
            HStack(spacing: 12) {
                searchField
                modePicker
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(viewModel.isLoading ? Color.accentColor : Color.primary.opacity(0.7))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: viewModel.isLoading)
            TextField(
                "Search archive",
                text: $viewModel.query,
                prompt: Text("Search or ask anything\u{2026}")
                    .foregroundColor(Color.primary.opacity(0.45))
            )
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .focused($focused)
                .onSubmit {
                    // If we already have results for the current query text,
                    // Return opens the highlighted hit (Spotlight-style).
                    // Otherwise it runs a new search.
                    let trimmed = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !viewModel.hits.isEmpty,
                       trimmed == viewModel.lastRunQuery,
                       let hit = viewModel.selectedHit {
                        openHit(hit)
                    } else {
                        Task { await viewModel.run() }
                    }
                }
                .onKeyPress(.tab) {
                    viewModel.mode = viewModel.mode.toggled
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if !viewModel.hits.isEmpty || viewModel.answer != nil {
                        viewModel.selectNext()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if !viewModel.hits.isEmpty || viewModel.answer != nil {
                        viewModel.selectPrevious()
                        return .handled
                    }
                    return .ignored
                }
                .frame(maxWidth: .infinity)
            if !viewModel.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    viewModel.query = ""
                    focused = true
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.55))
                .contentShape(Circle())
                .labelStyle(.iconOnly)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.86))
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .center).combined(with: .opacity),
                    removal: .scale(scale: 0.7, anchor: .center).combined(with: .opacity)
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .liquidGlass(in: Capsule(), interactive: true)
        .overlay(
            Capsule()
                .stroke(Color.accentColor, lineWidth: 1)
                .opacity(focused ? 0.45 : 0.12)
        )
        .scaleEffect(focused ? 1.0 : 0.995, anchor: .center)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.query.isEmpty)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: focused)
        .animation(resolved(Motion.snappy, reduceMotion: reduceMotion), value: viewModel.isLoading)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $viewModel.mode) {
            ForEach(QueryMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 140)
    }

    @ViewBuilder
    private var content: some View {
        if shouldShowEmpty {
            emptyState
                .transition(.opacity)
        } else if viewModel.hits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isLoading {
                    loadingRow
                        .transition(.opacity)
                }
                if let err = viewModel.error {
                    errorRow(err)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .transition(.opacity)
        } else {
            resultsList
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .transition(.opacity)
        }
    }

    /// Answer-first layout: the single best result fills the top with full
    /// detail (title, date, chips, body, actions), and a compact list of
    /// alternatives sits below. The user came here to get an answer, not
    /// to skim a list — so we lead with one, and keep the rest available
    /// without making them load-bearing.
    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            primarySlot

            if !otherItems.isEmpty {
                othersSection
            }
        }
    }

    @ViewBuilder
    private var primarySlot: some View {
        Group {
            if viewModel.isAnswerSelected, let answer = viewModel.answer {
                PrimaryAnswerCard(
                    answer: answer,
                    query: viewModel.lastRunQuery,
                    onCitationTap: { citation in
                        if let hit = viewModel.hits.first(where: { matches(file: $0.file, citationPath: citation.path) }) {
                            viewModel.selection = .hit(hit.id)
                        }
                    }
                )
                .id("primary-answer")
            } else if let hit = viewModel.selectedHit {
                PrimaryHitCard(
                    hit: hit,
                    query: viewModel.lastRunQuery,
                    onOpen: { openHit(hit) }
                )
                .id(hit.id)
            }
        }
        .transition(primaryTransition)
    }

    private var primaryTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
        )
    }

    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Other matches")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text("\(otherItems.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                Text("↑↓ to switch")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(otherItems) { item in
                            OtherMatchRow(
                                item: item,
                                onSelect: { viewModel.selection = item.selection }
                            )
                            .id(item.scrollID)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.selection) { _, _ in
                    // No scrolling needed here — selected items are never
                    // in this list. Hook reserved for future preview-mode
                    // selection that keeps everything in view.
                    _ = proxy
                }
            }
            .frame(maxHeight: 180)
        }
    }

    /// All non-primary items in display order — answer (if not primary),
    /// then hits (excluding the primary one). Used by both the section
    /// header count and the row list, so they can't disagree.
    private var otherItems: [OtherItem] {
        var items: [OtherItem] = []
        if viewModel.answer != nil, !viewModel.isAnswerSelected {
            items.append(.answer(viewModel.answer!))
        }
        for (idx, hit) in viewModel.hits.enumerated() {
            if viewModel.selectedHit?.id == hit.id { continue }
            items.append(.hit(hit, index: idx + 1))
        }
        return items
    }

    private func matches(file: String, citationPath: String) -> Bool {
        if citationPath.hasSuffix(file) { return true }
        let citationURL = URL(fileURLWithPath: citationPath).standardized
        let fileURL = StoragePreference.shared.root.appendingPathComponent(file).standardized
        return citationURL == fileURL
    }

    fileprivate func openHit(_ hit: QueryEngine.Hit) {
        let url = StoragePreference.shared.root.appendingPathComponent(hit.file)
        NSWorkspace.shared.open(url)
    }

    private var shouldShowEmpty: Bool {
        !viewModel.isLoading
            && viewModel.error == nil
            && viewModel.answer == nil
            && viewModel.hits.isEmpty
    }

    /// Per-card stagger: each result enters ~35ms after the previous one, with
    /// a bouncy spring so the list cascades into view.
    private func staggeredCardTransition(index: Int) -> AnyTransition {
        if reduceMotion { return .opacity }
        let delay = min(Double(index), 8) * 0.035
        let spring = Animation.spring(response: 0.42, dampingFraction: 0.78).delay(delay)
        return .asymmetric(
            insertion: AnyTransition
                .opacity
                .combined(with: .offset(y: 14))
                .combined(with: .scale(scale: 0.985, anchor: .top))
                .animation(spring),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: viewModel.mode == .ask ? "sparkles" : "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse.byLayer, options: .repeating, isActive: viewModel.mode == .ask && !reduceMotion)
            Text(viewModel.mode == .ask ? "Ask anything about your archive" : "Search your archive")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(viewModel.mode)
                .transition(.opacity)
            HStack(spacing: 16) {
                shortcut("return", "to run")
                shortcut("tab", "to switch")
                shortcut("esc", "to dismiss")
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private func shortcut(_ key: String, _ description: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Searching\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .queryQuietSurface(cornerRadius: 10)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
            Text("Search failed")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Text("Check that the Dump daemon is running, then try again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
            Spacer()
        }
        .padding(14)
        .queryQuietSurface(cornerRadius: 10)
    }
}


// MARK: - Result items (primary + others)

/// A row in the "other matches" list. Wraps either a hit or the answer so
/// the list can mix them — useful in Ask mode where the answer is the
/// primary by default and the user might want to peek at a specific
/// source hit instead.
enum OtherItem: Identifiable {
    case answer(SynthesisResult)
    case hit(QueryEngine.Hit, index: Int)

    var id: String {
        switch self {
        case .answer: return "__answer__"
        case .hit(let h, _): return h.id
        }
    }

    var scrollID: String { id }

    var selection: QuerySelection {
        switch self {
        case .answer: return .answer
        case .hit(let h, _): return .hit(h.id)
        }
    }
}

/// The "best answer" card for a hit. Big serif title, prominent date,
/// chips, optional body content, file path, and the three quick actions.
/// Designed to be the only thing the user needs to look at in the common
/// case — short notes have no body, so this just shows the entry's title
/// plus its metadata at a glance.
struct PrimaryHitCard: View {
    let hit: QueryEngine.Hit
    let query: String
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if hasBody {
                bodyBlock
            }
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .queryQuietSurface(cornerRadius: 14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 8) {
                Text(HitDisplay.title(for: hit))
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let date = HitDisplay.date(for: hit) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 11, weight: .medium))
                            Text(HitDisplay.format(date: date))
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !hit.collection.isEmpty {
                        chip(icon: "tray.full.fill", label: hit.collection, color: .secondary)
                    }
                    if let type = HitDisplay.type(for: hit) {
                        chip(icon: type.icon, label: type.label, color: type.color)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var bodyBlock: some View {
        HighlightedText(
            text: bodyText,
            query: query,
            baseFont: .system(.body, design: .serif),
            emphasisColor: .yellow
        )
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .lineSpacing(4)
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(QuerySurface.contentRail)
                .frame(width: 2.5)
                .padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(hit.file)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.file)
            }
            .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            QuickAction(icon: "doc.on.clipboard", label: "Copy", action: copyExcerpt)
            QuickAction(icon: "folder.fill", label: "Reveal", action: reveal)
            QuickAction(icon: "arrow.up.forward.app.fill", label: "Open", action: onOpen, prominent: true)
        }
    }

    // MARK: - Helpers

    private var bodyText: String { HitDisplay.body(for: hit) }
    private var hasBody: Bool { !bodyText.isEmpty }

    private var fileURL: URL {
        StoragePreference.shared.root.appendingPathComponent(hit.file)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func copyExcerpt() {
        NSPasteboard.general.clearContents()
        let text = hasBody ? bodyText : HitDisplay.title(for: hit)
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var iconName: String {
        let ext = (hit.file as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "pdf": return "doc.richtext"
        case "txt": return "doc.plaintext"
        default: return "doc"
        }
    }
}

/// Primary card for an LLM answer in Ask mode. Same chrome shape as
/// `PrimaryHitCard` so switching between the two animates cleanly.
struct PrimaryAnswerCard: View {
    let answer: SynthesisResult
    let query: String
    let onCitationTap: (SynthesisResult.Citation) -> Void

    @State private var sparkleTrigger: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text(answer.text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(5)
            if !answer.citations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Sources")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(answer.citations) { c in
                            CitationChip(citation: c, onTap: { onCitationTap(c) })
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .queryQuietSurface(cornerRadius: 14)
        .onAppear { sparkleTrigger += 1 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce.up.byLayer, value: sparkleTrigger)
                .frame(width: 28, alignment: .center)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                Text(echoedQuery)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Synthesised answer")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(QuerySurface.quietChipFill, in: Capsule())
            }
        }
    }

    private var echoedQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Answer" : trimmed
    }
}

/// A compact, single-line row in the "Other matches" list. Click to
/// promote it to the primary slot.
struct OtherMatchRow: View {
    let item: OtherItem
    let onSelect: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                leading
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !subtitle.isEmpty {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.99))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(QuerySurface.rowHoverFill(hovering))
        )
        .onHover { hovering = $0 }
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: hovering)
    }

    @ViewBuilder
    private var leading: some View {
        switch item {
        case .answer:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
        case .hit(_, let index):
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var title: String {
        switch item {
        case .answer: return "Answer"
        case .hit(let h, _): return HitDisplay.title(for: h)
        }
    }

    private var subtitle: String {
        switch item {
        case .answer(let a):
            return a.text.split(separator: "\n").first.map(String.init) ?? ""
        case .hit(let h, _):
            return h.collection
        }
    }

    private var trailing: String? {
        switch item {
        case .answer(let a):
            return "\(a.citations.count) source\(a.citations.count == 1 ? "" : "s")"
        case .hit(let h, _):
            return HitDisplay.date(for: h).map { HitDisplay.shortRelative(date: $0) }
        }
    }
}

// MARK: - Match highlighting

/// Renders a string with the user's query tokens highlighted. Used in both
/// the rail rows (subtle weight emphasis only) and the preview pane (full
/// amber background highlight on serif text).
struct HighlightedText: View {
    let text: String
    let query: String
    /// Base font for the whole string. Highlighted runs inherit this and
    /// add a weight bump.
    var baseFont: Font = .body
    /// If set, matched runs get this color as a background highlight. If
    /// nil, only weight emphasis is applied (used for compact rows).
    var emphasisColor: Color? = .yellow

    var body: some View {
        Text(makeAttributed())
            .font(baseFont)
    }

    private func makeAttributed() -> AttributedString {
        var result = AttributedString(text)

        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return result }

        for token in tokens {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: token, options: .caseInsensitive, range: cursor..<text.endIndex) {
                if let attrLow = AttributedString.Index(range.lowerBound, within: result),
                   let attrHigh = AttributedString.Index(range.upperBound, within: result) {
                    let attrRange = attrLow..<attrHigh
                    result[attrRange].inlinePresentationIntent = .stronglyEmphasized
                    if let color = emphasisColor {
                        result[attrRange].backgroundColor = color.opacity(0.32)
                    }
                }
                cursor = range.upperBound
            }
        }

        return result
    }

    /// Split the query into highlight-worthy tokens. Drops short stopword-y
    /// fragments (< 2 chars) so a query like "what is the api" doesn't
    /// paint every "is"/"the" yellow.
    private static func tokenize(_ query: String) -> [String] {
        query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }
}

// MARK: - Score indicator

/// Compact "match strength" pill. Three thresholds give a coarse but useful
/// signal — exact numeric scores are noisy and not meaningful to the user.
struct ScoreIndicator: View {
    let score: Double

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1.5) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(i < filledBars ? Color.primary.opacity(0.65) : Color.primary.opacity(0.18))
                        .frame(width: 2.5, height: CGFloat(4 + i * 2))
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }

    private var filledBars: Int {
        if score >= 0.75 { return 3 }
        if score >= 0.45 { return 2 }
        return 1
    }

    private var label: String {
        if score >= 0.75 { return "Strong match" }
        if score >= 0.45 { return "Good match" }
        return "Partial match"
    }
}

// MARK: - Quick action button

/// Pill-shaped action button for the preview pane footer. The prominent
/// variant uses the accent color and white text; the secondary variant is
/// a translucent neutral.
struct QuickAction: View {
    let icon: String
    let label: String
    let action: () -> Void
    var prominent: Bool = false

    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : .primary)
            .background(background)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
        .onHover { hovering = $0 }
        .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: hovering)
    }

    @ViewBuilder
    private var background: some View {
        if prominent {
            Capsule()
                .fill(Color.accentColor.opacity(hovering ? 1.0 : 0.92))
                .shadow(color: Color.accentColor.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 8 : 4, y: 2)
        } else {
            Capsule()
                .fill(QuerySurface.controlFill(hovering: hovering))
                .overlay(
                    Capsule().stroke(QuerySurface.controlStroke, lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Citation chip

/// Numbered, tappable chip representing one citation in the answer pane.
/// Tap routes to `onTap` if provided (used by the rail-based UI to switch
/// the preview pane to that source) and otherwise falls back to opening
/// the file in the default app.
struct CitationChip: View {
    let citation: SynthesisResult.Citation
    var onTap: (() -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if let onTap {
                onTap()
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: citation.path))
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(citation.index)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(QuerySurface.quietChipFill, in: Circle())
                Text(citation.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(QuerySurface.controlFill(hovering: hovering), in: Capsule())
            .overlay(
                Capsule().stroke(QuerySurface.controlStroke, lineWidth: 0.5)
            )
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.94))
        .scaleEffect(hovering ? 1.06 : 1, anchor: .center)
        .onHover { hovering = $0 }
        .animation(resolved(Motion.interactive, reduceMotion: reduceMotion), value: hovering)
    }
}

// MARK: - Query content surfaces

private enum QuerySurface {
    static var contentFill: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.92)
    }

    static var contentStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.65)
    }

    static var contentRail: Color {
        Color(nsColor: .separatorColor).opacity(0.95)
    }

    static var quietChipFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    static var controlStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.6)
    }

    static func rowHoverFill(_ hovering: Bool) -> Color {
        hovering ? DumpUI.SemanticStyle.hoverFill : .clear
    }

    static func controlFill(hovering: Bool) -> Color {
        Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.90 : 0.72)
    }
}

private struct QueryQuietSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)

        content
            .background(shape.fill(QuerySurface.contentFill))
            .overlay(shape.strokeBorder(QuerySurface.contentStroke, lineWidth: 0.5))
    }
}

private extension View {
    func queryQuietSurface(cornerRadius: CGFloat) -> some View {
        modifier(QueryQuietSurface(cornerRadius: cornerRadius))
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

// MARK: - Hit display formatting

/// Pure formatting helpers for turning raw `QMDHit` data into human-readable
/// titles, dates, and excerpts. Three problems this solves:
///   1. qmd returns line-numbered diff chunks (`N: line text` + `@@` hunk
///      headers). The user wants prose, not a patch.
///   2. Many of our entries are short notes whose only "content" is YAML
///      frontmatter — those bytes shouldn't show up as the excerpt.
///   3. Filenames carry a `YYYY-MM-DD-HHMM-slug.md` structure. The slug is
///      the real title, the date prefix is real "when this was captured"
///      data, and both are more useful than the raw basename.
enum HitDisplay {
    /// Human-readable title for a hit. Prefers the frontmatter title when
    /// it's clearly different from the filename; otherwise parses the slug
    /// out of the timestamped filename ("i-need-to-take-the-laundry" →
    /// "I need to take the laundry").
    static func title(for hit: QueryEngine.Hit) -> String {
        if let raw = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           !looksLikeTimestampedFilename(raw) {
            return raw
        }
        return slug(from: hit.file)
    }

    /// Date parsed from a `YYYY-MM-DD-HHMM-…` filename prefix. Returns nil
    /// for files that don't match the dump capture format.
    static func date(for hit: QueryEngine.Hit) -> Date? {
        let basename = (hit.file as NSString).lastPathComponent
        guard let captured = basename.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}"#, options: .regularExpression) else {
            return nil
        }
        let stamp = String(basename[captured])
        return timestampParser.date(from: stamp)
    }

    /// Optional content classification ("task", "reminder", …) extracted
    /// from the YAML frontmatter that often appears in the snippet. We mine
    /// it from the snippet itself because qmd doesn't expose frontmatter
    /// fields through its Hit shape.
    static func type(for hit: QueryEngine.Hit) -> TypeBadge? {
        let bag = (hit.snippet + "\n" + (hit.context ?? "")).lowercased()
        guard let range = bag.range(of: #"type:\s*([a-z]+)"#, options: .regularExpression) else { return nil }
        let line = String(bag[range])
        let value = line
            .replacingOccurrences(of: "type:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return TypeBadge(rawValue: value)
    }

    /// Verbose date string for the preview pane header. Switches between
    /// relative ("Today", "Yesterday"), weekday for the past week, and a
    /// month-day-year for older entries.
    static func format(date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday at' h:mm a"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
                  days > 0, days < 7 {
            formatter.dateFormat = "EEEE 'at' h:mm a"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d 'at' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    /// Tight time string for the rail rows where space is precious.
    /// "6:19 PM" today, "Mon" within the past week, "May 18" beyond that.
    static func shortRelative(date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
                  days > 0, days < 7 {
            formatter.dateFormat = "EEE"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    /// Body content for a hit: cleaned snippet minus any line that just
    /// repeats the title. Quick-capture entries write the user's one-line
    /// thought as both the filename slug and the file body, so the cleaned
    /// snippet effectively duplicates the title — which makes a body
    /// section pointless. PDFs, meeting notes, and longer entries have
    /// real bodies; those survive this filter.
    static func body(for hit: QueryEngine.Hit) -> String {
        let cleaned = cleanedContent(hit.snippet)
        guard !cleaned.isEmpty else { return "" }
        let title = title(for: hit).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return cleaned }
        let kept = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != title }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip qmd's diff scaffolding (line-number prefixes, `@@` hunk
    /// headers, YAML frontmatter blocks) so we're left with the readable
    /// content the user actually wrote.
    static func cleanedContent(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let unprefixed = lines.map(stripLineNumberPrefix)

        var output: [String] = []
        var inFrontmatter = false
        var seenContent = false

        for line in unprefixed {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // qmd's hunk headers, e.g. "@@ -1,4 @@ (0 before, 6 after)".
            if trimmed.hasPrefix("@@") { continue }

            // YAML frontmatter — only meaningful as a frontmatter fence
            // before we've seen any content. Once content is in, a `---`
            // is more likely a horizontal rule and shouldn't be eaten.
            if trimmed == "---" && !seenContent {
                inFrontmatter.toggle()
                continue
            }

            if inFrontmatter { continue }

            if !seenContent && trimmed.isEmpty { continue }
            seenContent = true
            output.append(line)
        }

        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Internals

    /// Drop a leading `N: ` line-number prefix if present. We compare digits
    /// rather than using a regex per-line — this is called for every line
    /// of every snippet on every keystroke.
    private static func stripLineNumberPrefix(_ line: String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
        guard i > line.startIndex, i < line.endIndex, line[i] == ":" else { return line }
        var j = line.index(after: i)
        if j < line.endIndex, line[j] == " " { j = line.index(after: j) }
        return String(line[j...])
    }

    private static func looksLikeTimestampedFilename(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}"#, options: .regularExpression) != nil
    }

    /// Turn "2026-05-18-1819-i-need-to-take-the-laundry.md" into
    /// "I need to take the laundry". Falls back to the basename if no
    /// timestamp prefix is present.
    private static func slug(from file: String) -> String {
        let basename = (file as NSString).lastPathComponent
        let withoutExt = (basename as NSString).deletingPathExtension
        var s = withoutExt
        if let range = s.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}-"#, options: .regularExpression) {
            s = String(s[range.upperBound...])
        }
        s = s.replacingOccurrences(of: "-", with: " ")
        guard let first = s.first else { return withoutExt }
        return String(first).uppercased() + s.dropFirst()
    }

    private static let timestampParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// A handful of well-known entry types from the classifier's
    /// frontmatter, mapped to a presentation. Unknown values return nil so
    /// we don't paint a meaningless badge for unclassified entries.
    enum TypeBadge {
        case task, reminder, note, idea, reference, meeting

        init?(rawValue: String) {
            switch rawValue {
            case "task": self = .task
            case "reminder": self = .reminder
            case "note": self = .note
            case "idea": self = .idea
            case "reference": self = .reference
            case "meeting": self = .meeting
            default: return nil  // including "unknown" — no badge
            }
        }

        var label: String {
            switch self {
            case .task: return "Task"
            case .reminder: return "Reminder"
            case .note: return "Note"
            case .idea: return "Idea"
            case .reference: return "Reference"
            case .meeting: return "Meeting"
            }
        }

        var icon: String {
            switch self {
            case .task: return "checkmark.circle"
            case .reminder: return "bell.fill"
            case .note: return "note.text"
            case .idea: return "lightbulb.fill"
            case .reference: return "bookmark.fill"
            case .meeting: return "person.2.fill"
            }
        }

        var color: Color {
            switch self {
            case .task: return .blue
            case .reminder: return .orange
            case .note: return .gray
            case .idea: return .yellow
            case .reference: return .purple
            case .meeting: return .pink
            }
        }
    }
}

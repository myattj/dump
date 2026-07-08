import SwiftUI

/// Shared formatting for queue metadata shown in row chips, the composer's
/// live parse strip, and the capture panel preview.
enum QueueFormat {
    // Formatter creation is expensive ICU work; these are immutable after init
    // and formatting is thread-safe on modern macOS, so cache them once.
    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE MMM d"; return f
    }()
    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    // RelativeDateTimeFormatter (unlike DateFormatter) is not marked Sendable
    // on this SDK; it's immutable after init and only formats, so the
    // annotation is safe.
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    static func date(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeString(date)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if date < now { return "overdue" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? Self.sameYearFormatter : Self.otherYearFormatter).string(from: date).lowercased()
    }

    static func timeString(_ date: Date) -> String {
        Self.shortTimeFormatter.string(from: date).lowercased()
    }

    static func effort(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func dueColor(_ date: Date, now: Date = Date()) -> Color {
        let interval = date.timeIntervalSince(now)
        if interval < 0 { return .red }
        if interval < 24 * 60 * 60 { return .orange }
        return .teal
    }

    static func importanceLabel(_ importance: Int) -> String {
        switch importance {
        case ...1: return "low"
        case 3: return "high"
        case 4...: return "critical"
        default: return "normal"
        }
    }

    static func importanceColor(_ importance: Int) -> Color {
        switch importance {
        case ...1: return .gray
        case 3: return .orange
        case 4...: return .red
        default: return .secondary
        }
    }

    /// Human explanation of why an item sits where it does — shown as a
    /// tooltip on the rank number.
    static func rankExplanation(for item: QueueItem, now: Date = Date()) -> String {
        var parts: [String] = []
        if let wake = item.wakeAt, item.isLater {
            parts.append("waiting until \(date(wake, now: now))")
        } else if let deadline = item.deadlineAt {
            parts.append("due \(relative(deadline, now: now))")
        } else if let scheduled = item.scheduledAt {
            parts.append(scheduled < now ? "reminder fired \(relative(scheduled, now: now))" : "reminder \(relative(scheduled, now: now))")
        } else {
            parts.append("no date · added \(relative(item.createdAt, now: now))")
        }
        if let effort = item.effortMinutes {
            parts.append("needs \(Self.effort(effort))")
        }
        if let importance = item.importance {
            parts.append("\(importanceLabel(importance)) importance")
        }
        if item.snoozeCount > 0 {
            parts.append("snoozed \(item.snoozeCount)×")
        }
        return parts.joined(separator: " · ")
    }

    private static func relative(_ date: Date, now: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

extension QueueViewModel.ParsePreview {
    /// Animation/equality key that is stable across re-parses: the raw
    /// `date` carries sub-second precision from "in 30 minutes"-style
    /// relative parses (each parse computes from a fresh `Date()`), so
    /// keying an animation on the preview itself would re-key it on every
    /// keystroke. This projects down to what the chips actually display.
    var animationKey: String {
        let dateText = date.map { QueueFormat.date($0) } ?? "none"
        return "\(dateKind == .reminder ? "r" : "d")|\(dateText)|\(effortMinutes ?? -1)|\(importance ?? -1)"
    }
}

/// The visual pill used for all queue metadata chips.
struct ChipLabel: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Live preview of what the current input parses to. Interactive when the
/// callbacks are set (queue composer): tapping the date chip flips
/// deadline ↔ reminder, the small ✕ discards a parsed field. Purely
/// informational in the capture panel.
struct ParsePreviewStrip: View {
    let preview: QueueViewModel.ParsePreview
    var onToggleDateKind: (@MainActor () -> Void)?
    var onClear: (@MainActor (QueueViewModel.ParsedField) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let date = preview.date {
                clearable(.date) {
                    chipButton(action: onToggleDateKind) {
                        ChipLabel(
                            icon: preview.dateKind == .reminder ? "bell" : "calendar",
                            text: "\(preview.dateKind == .reminder ? "remind" : "due") \(QueueFormat.date(date))",
                            color: preview.dateKind == .reminder ? .orange : .teal
                        )
                    }
                    .help(onToggleDateKind == nil
                        ? (preview.dateKind == .reminder ? "Reminder" : "Deadline")
                        : (preview.dateKind == .reminder ? "Reminder — click to make it a deadline" : "Deadline — click to make it a reminder"))
                }
            }
            if let effort = preview.effortMinutes {
                clearable(.effort) {
                    ChipLabel(icon: "hourglass", text: QueueFormat.effort(effort), color: .indigo)
                }
            }
            if let importance = preview.importance {
                clearable(.importance) {
                    ChipLabel(
                        icon: "flag",
                        text: QueueFormat.importanceLabel(importance),
                        color: QueueFormat.importanceColor(importance)
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chipButton(action: (@MainActor () -> Void)?, @ViewBuilder label: () -> some View) -> some View {
        if let action {
            Button(action: action, label: label)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.92))
                .modifier(ChipHoverHighlight())
        } else {
            label()
        }
    }

    @ViewBuilder
    private func clearable(_ field: QueueViewModel.ParsedField, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 2) {
            content()
            if let onClear {
                Button {
                    onClear(field)
                } label: {
                    Label("Discard", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .labelStyle(.iconOnly)
                        .frame(width: DumpUI.Controls.smallIconButton.width,
                               height: DumpUI.Controls.smallIconButton.height)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Color.primary.opacity(0.4))
                .buttonStyle(PressableButtonStyle(pressedScale: 0.86))
                .help("Discard")
            }
        }
    }
}

private struct ChipHoverHighlight: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.08 : 0)
            .scaleEffect(reduceMotion ? 1 : (hovering ? 1.03 : 1))
            .animation(resolved(Motion.micro, reduceMotion: reduceMotion), value: hovering)
            .onHover { hovering = $0 }
    }
}

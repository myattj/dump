import SwiftUI

/// Shared formatting for queue metadata shown in row chips, the composer's
/// live parse strip, and the capture panel preview.
enum QueueFormat {
    static func date(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeString(date)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if date < now { return "overdue" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "EEE MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date).lowercased()
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date).lowercased()
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
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
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
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
        } else {
            label()
        }
    }

    @ViewBuilder
    private func clearable(_ field: QueueViewModel.ParsedField, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 2) {
            content()
            if let onClear {
                Button("Discard", systemImage: "xmark.circle.fill") {
                    onClear(field)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.4))
                .labelStyle(.iconOnly)
                .buttonStyle(PressableButtonStyle(pressedScale: 0.86))
                .help("Discard")
            }
        }
    }
}

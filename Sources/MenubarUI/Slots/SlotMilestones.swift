import MenubarCore
import SwiftUI

/// The three dates of a slot as steps: code freeze, early access, release (SLOT-02). Pure, so the tests check which step
/// is passed and which is next.
///
/// The steps are evenly spaced, on purpose not a time scale: the roadmap above the cards is the only place with one.
struct SlotMilestones: Equatable {
    /// Where a step stands from today.
    enum Phase: Equatable {
        case passed
        /// the first date from today on; a date today is next, not passed
        case next
        case later
    }

    struct Step: Equatable {
        var milestone: SlotDates.Milestone
        var date: Date
        var phase: Phase
        /// "today", "in 21 days", "3 days ago"
        var relative: String
    }

    var steps: [Step]

    /// the widest a step's name, date and distance get, in points, measured in the caption font
    static let labelWidth: CGFloat = 92

    /// - Parameters:
    ///   - dates: the slot's dates
    ///   - today: any time of today
    ///   - calendar: the calendar whose days count
    init(dates: SlotDates, today: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: today)
        let ordered = SlotDates.Milestone.allCases.sorted { dates.date(of: $0) < dates.date(of: $1) }
        var hasNext = false
        steps = ordered.map { milestone in
            let date = dates.date(of: milestone)
            let phase: Phase
            if date < start {
                phase = .passed
            } else if !hasNext {
                phase = .next
                hasNext = true
            } else {
                phase = .later
            }
            return Step(milestone: milestone, date: date, phase: phase, relative: Self.relative(date, today: today, calendar: calendar))
        }
    }

    /// how much of the line between the first and the last step is filled: up to the last passed step
    var filled: CGFloat {
        guard let last = steps.lastIndex(where: { $0.phase == .passed }), steps.count > 1 else { return 0 }
        return CGFloat(last) / CGFloat(steps.count - 1)
    }

    /// Returns where each step's text goes in a row of the width: the first starts at the left edge, the middle one is
    /// centered and the last ends at the right edge, each as wide as ``labelWidth``.
    static func labelSpans(count: Int, width: CGFloat) -> [ClosedRange<CGFloat>] {
        (0..<count).map { index in
            let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            let start = fraction * (width - labelWidth)
            return start...(start + labelWidth)
        }
    }

    /// the tooltip of a step: its name and full date, how far away it is, and what it means
    static func help(of step: Step) -> String {
        let full = step.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        let relative = step.relative.prefix(1).uppercased() + step.relative.dropFirst()
        return "\(step.milestone.title) · \(full)\n\(relative)\n\(step.milestone.meaning)"
    }

    /// "today", "tomorrow", "in 12 days", "yesterday" or "5 days ago"
    static func relative(_ date: Date, today: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }
}

extension SlotDates.Milestone {
    /// what the date means for the slot, for the tooltip
    var meaning: String {
        switch self {
        case .codeFreeze: "The last day for new work to go into this slot."
        case .earlyAccess: "The slot's early access build opens for testing."
        case .release: "The slot ships."
        }
    }
}

/// A slot's three dates as a row of steps: passed ones checked and quiet, the next one in the accent color, the line
/// filled up to the last passed step.
struct SlotMilestoneRow: View {
    let dates: SlotDates
    let today: Date
    /// the color of the passed path and the next step: orange for an overdue slot
    var tint: Color = .accentColor

    private static let dot: CGFloat = 16

    var body: some View {
        let milestones = SlotMilestones(dates: dates, today: today)
        let count = milestones.steps.count
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(milestones.steps.enumerated()), id: \.element.milestone) { index, step in
                let alignment = Self.alignment(index, count: count)
                VStack(alignment: alignment, spacing: 5) {
                    marker(step)
                    text(step, alignment: alignment)
                }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
                .contentShape(Rectangle())
                .help(SlotMilestones.help(of: step))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SlotMilestones.help(of: step).replacingOccurrences(of: "\n", with: ". "))
            }
        }
        .background(alignment: .top) {
            line(filled: milestones.filled)
        }
    }

    private static func alignment(_ index: Int, count: Int) -> HorizontalAlignment {
        index == 0 ? .leading : index == count - 1 ? .trailing : .center
    }

    /// the line from the first dot's center to the last's, behind the dots
    private func line(filled: CGFloat) -> some View {
        GeometryReader { proxy in
            let length = max(proxy.size.width - Self.dot, 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.opacity(0.55)).frame(width: length * filled)
            }
            .frame(width: length, height: 2)
            .offset(x: Self.dot / 2, y: Self.dot / 2 - 1)
        }
        .frame(height: Self.dot)
    }

    @ViewBuilder
    private func marker(_ step: SlotMilestones.Step) -> some View {
        ZStack {
            // the card's color behind the dot, so the line stops at its edge
            Circle().fill(.background.secondary)
            switch step.phase {
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tint.opacity(0.6))
            case .next:
                Circle().fill(tint.opacity(0.22))
                Circle().fill(tint).padding(4)
            case .later:
                Circle().strokeBorder(.tertiary, lineWidth: 1.5).padding(2)
            }
        }
        .frame(width: Self.dot, height: Self.dot)
    }

    private func text(_ step: SlotMilestones.Step, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(verbatim: step.milestone.title)
                .font(.caption.weight(step.phase == .next ? .semibold : .medium))
                .foregroundStyle(step.phase == .next ? AnyShapeStyle(tint) : step.phase == .passed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Text(verbatim: step.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(step.phase == .passed ? .secondary : .primary)
            Text(verbatim: step.relative)
                .font(.caption2)
                .foregroundStyle(step.phase == .next ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
        }
        .lineLimit(1)
        .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
    }
}

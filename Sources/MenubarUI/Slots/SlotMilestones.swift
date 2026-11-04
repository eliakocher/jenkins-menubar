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

    /// Where today lies between two steps, for the marker on the line.
    struct TodayPosition: Equatable {
        /// where on the whole line, 0 at the first step and 1 at the last; inside the segment by date, the steps stay evenly spaced
        var fraction: CGFloat
        /// the days from the step before to today
        var day: Int
        /// the days between the step before and the next
        var days: Int
        /// the step ahead
        var toward: SlotDates.Milestone

        /// "Today, 4 of 10 days to early access"
        var spoken: String {
            "Today, \(day) of \(days) days to \(toward.title.lowercased())"
        }
    }

    var steps: [Step]
    /// where today lies strictly between the first and the last step; `nil` before the first, on a step's day and after the last
    var today: TodayPosition?

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
        self.today = Self.todayPosition(today: today, steps: steps, calendar: calendar)
    }

    /// Returns where today lies on the line, by date within the segment it falls in: 4 days into a 10-day segment of
    /// three steps is `(1 + 0.4) / 2`. `nil` before the first step, after the last and on a step's own day, where the
    /// step itself is today.
    static func todayFraction(today: Date, steps: [Step], calendar: Calendar = .current) -> CGFloat? {
        todayPosition(today: today, steps: steps, calendar: calendar)?.fraction
    }

    /// the position behind ``todayFraction(today:steps:calendar:)``, with the days for the spoken label
    static func todayPosition(today: Date, steps: [Step], calendar: Calendar = .current) -> TodayPosition? {
        guard steps.count > 1 else { return nil }
        func days(_ from: Date, _ to: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        }
        for index in 0..<(steps.count - 1) {
            let total = days(steps[index].date, steps[index + 1].date)
            let day = days(steps[index].date, today)
            if day > 0, day < total {
                let fraction = (CGFloat(index) + CGFloat(day) / CGFloat(total)) / CGFloat(steps.count - 1)
                return TodayPosition(fraction: fraction, day: day, days: total, toward: steps[index + 1].milestone)
            }
        }
        return nil
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
/// filled up to the last passed step, or up to today's marker when today lies between two steps: the roadmap's blue
/// tick with a small "Today" capsule above the line, the steps' texts below it.
struct SlotMilestoneRow: View {
    let dates: SlotDates
    let today: Date
    /// the color of the passed path and the next step: orange for an overdue slot
    var tint: Color = .accentColor

    private static let dot: CGFloat = 16
    private static let pillWidth: CGFloat = 38
    private static let pillHeight: CGFloat = 14
    /// the room above the line for the marker's capsule and its stem
    private static let reserve: CGFloat = pillHeight + 4

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
                .tip(SlotMilestones.help(of: step))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SlotMilestones.help(of: step).replacingOccurrences(of: "\n", with: ". "))
            }
        }
        .background(alignment: .top) {
            track(milestones)
        }
        .padding(.top, milestones.today == nil ? 0 : Self.reserve)
    }

    private static func alignment(_ index: Int, count: Int) -> HorizontalAlignment {
        index == 0 ? .leading : index == count - 1 ? .trailing : .center
    }

    /// the line from the first dot's center to the last's, behind the dots, and today's marker on it
    private func track(_ milestones: SlotMilestones) -> some View {
        GeometryReader { proxy in
            let length = max(proxy.size.width - Self.dot, 0)
            let filled = milestones.today?.fraction ?? milestones.filled
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.opacity(0.55)).frame(width: length * filled)
                }
                .frame(width: length, height: 2)
                .offset(x: Self.dot / 2, y: Self.dot / 2 - 1)
                if let today = milestones.today {
                    todayMarker(today, x: Self.dot / 2 + length * today.fraction, width: proxy.size.width)
                }
            }
        }
        .frame(height: Self.dot)
    }

    /// a dot on the line, a stem up to a "Today" capsule above the line: the steps' texts are below, so nothing collides
    /// and the milestone dots, drawn over it, win when today is a day from one; the capsule stays inside the row
    private func todayMarker(_ today: SlotMilestones.TodayPosition, x: CGFloat, width: CGFloat) -> some View {
        let start = SlotRoadmapLayout.pillStart(todayX: x, pillWidth: Self.pillWidth, width: width)
        let line = Self.dot / 2
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: Self.reserve - Self.pillHeight + line)
                .offset(x: x - 0.75, y: -(Self.reserve - Self.pillHeight))
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(.background.secondary, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .offset(x: x - 4.5, y: line - 4.5)
            Text("Today")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.pillWidth, height: Self.pillHeight)
                .background(Color.accentColor, in: Capsule())
                .offset(x: start, y: -Self.reserve)
        }
        .tip("Today · \(today.spoken.dropFirst("Today, ".count))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(today.spoken)
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

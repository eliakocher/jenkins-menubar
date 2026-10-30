import MenubarCore
import SwiftUI

/// Where the bars of the roadmap go (SLOT-02): every shown slot from its code freeze to its release on one date axis,
/// the only real time scale of the section. Pure, so the tests check the scale, that today is never moved onto a date,
/// and that the month names don't overlap.
struct SlotRoadmapLayout: Equatable {
    /// a slot's bar
    struct Bar: Equatable {
        var start: CGFloat
        var earlyAccess: CGFloat
        var end: CGFloat
    }

    /// the first day of a month on the axis, with its name when there is room for it
    struct Tick: Equatable {
        var x: CGFloat
        /// "Nov", or "Jan 2027" when the year isn't today's; `nil` when the name before it takes the room
        var title: String?
    }

    var bars: [Bar]
    /// today's x, at its real date
    var todayX: CGFloat
    var ticks: [Tick]
    /// the width of the axis
    var width: CGFloat

    /// the days of room around the dates on the axis
    static let paddingDays = 3
    /// the room a month's name takes, in points
    static let tickTitleWidth: CGFloat = 54

    /// - Parameters:
    ///   - slots: the dates of the slots shown
    ///   - today: any time of today
    ///   - width: the width of the axis
    ///   - calendar: the calendar whose days count
    init(slots: [SlotDates], today: Date, width: CGFloat, calendar: Calendar = .current) {
        self.width = width
        let start = calendar.startOfDay(for: today)
        let all = slots.flatMap { [$0.codeFreeze, $0.earlyAccess, $0.release] } + [start]
        let pad = TimeInterval(Self.paddingDays * 86400)
        let lower = all.min()!.addingTimeInterval(-pad)
        let upper = all.max()!.addingTimeInterval(pad)
        let length = max(upper.timeIntervalSince(lower), 86400)
        func x(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(lower) / length) * width
        }
        bars = slots.map { Bar(start: x($0.codeFreeze), earlyAccess: x($0.earlyAccess), end: x($0.release)) }
        todayX = x(start)

        var ticks: [Tick] = []
        var lastTitled = -CGFloat.infinity
        let year = calendar.component(.year, from: today)
        var month = calendar.dateInterval(of: .month, for: lower).map { calendar.date(byAdding: .month, value: 1, to: $0.start)! }
        while let date = month, date < upper {
            let at = x(date)
            var title: String?
            if at - lastTitled >= Self.tickTitleWidth, at + Self.tickTitleWidth <= width {
                title = calendar.component(.year, from: date) == year
                    ? date.formatted(.dateTime.month(.abbreviated))
                    : date.formatted(.dateTime.month(.abbreviated).year())
                lastTitled = at
            }
            ticks.append(Tick(x: at, title: title))
            month = calendar.date(byAdding: .month, value: 1, to: date)
        }
        self.ticks = ticks
    }

    /// Returns where the "Today" pill starts: centered on today's line, kept inside the axis.
    static func pillStart(todayX: CGFloat, pillWidth: CGFloat, width: CGFloat) -> CGFloat {
        min(max(todayX - pillWidth / 2, 0), max(width - pillWidth, 0))
    }
}

/// The section's roadmap: one thin bar per slot from its code freeze to its release, early access where the bar turns
/// lighter, the current slot in the accent color, months below and one line for today. A row scrolls to its card.
struct SlotRoadmap: View {
    let slots: [SlotSummary]
    let today: Date
    let select: (SlotName) -> Void

    private static let nameWidth: CGFloat = 54
    private static let row: CGFloat = 20
    private static let pill: CGFloat = 18
    private static let pillWidth: CGFloat = 46
    private static let months: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(width: Self.nameWidth, height: Self.pill)
                ForEach(slots) { slot in
                    Button { select(slot.name) } label: {
                        Text(verbatim: slot.name.description)
                            .font(.caption.monospacedDigit().weight(slot.state == .current ? .semibold : .regular))
                            .foregroundStyle(slot.state == .current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: Self.nameWidth, height: Self.row, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(slot))
                    .accessibilityLabel(help(slot))
                }
            }
            GeometryReader { proxy in
                axis(SlotRoadmapLayout(slots: slots.map(\.dates), today: today, width: proxy.size.width))
            }
            .frame(height: height)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var height: CGFloat {
        Self.pill + CGFloat(slots.count) * Self.row + Self.months
    }

    private func axis(_ layout: SlotRoadmapLayout) -> some View {
        let rows = CGFloat(slots.count) * Self.row
        return ZStack(alignment: .topLeading) {
            // the months: a faint line at each first day, the name below the rows
            ForEach(Array(layout.ticks.enumerated()), id: \.offset) { _, tick in
                Rectangle()
                    .fill(.quaternary.opacity(0.7))
                    .frame(width: 1, height: rows + 4)
                    .offset(x: tick.x - 0.5, y: Self.pill)
                if let title = tick.title {
                    Text(verbatim: title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: tick.x + 3, y: Self.pill + rows + 2)
                }
            }
            ForEach(Array(zip(slots, layout.bars)), id: \.0.id) { pair in
                let (slot, bar) = pair
                let index = slots.firstIndex { $0.id == slot.id } ?? 0
                self.bar(bar, of: slot)
                    .offset(y: Self.pill + CGFloat(index) * Self.row + (Self.row - 6) / 2)
            }
            today(layout, rows: rows)
        }
    }

    /// the stretch to early access solid, the rest lighter, with a hairline gap at early access
    private func bar(_ bar: SlotRoadmapLayout.Bar, of slot: SlotSummary) -> some View {
        let color = color(of: slot)
        let first = max(bar.earlyAccess - bar.start - 1, 2)
        let second = max(bar.end - bar.earlyAccess - 1, 2)
        return Button { select(slot.name) } label: {
            HStack(spacing: 2) {
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3)
                    .fill(color)
                    .frame(width: first)
                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                    .fill(color.opacity(0.45))
                    .frame(width: second)
            }
            .frame(height: 6)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: bar.start, y: -7)
        .help(help(slot))
        .accessibilityLabel(help(slot))
    }

    private func color(of slot: SlotSummary) -> Color {
        switch slot.state {
        case .current: .accentColor
        case .overdue: .orange
        case .upcoming: Color.primary.opacity(0.28)
        }
    }

    private func today(_ layout: SlotRoadmapLayout, rows: CGFloat) -> some View {
        let help = "Today · \(today.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))"
        let pillStart = SlotRoadmapLayout.pillStart(todayX: layout.todayX, pillWidth: Self.pillWidth, width: layout.width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: rows + 4)
                .offset(x: layout.todayX - 0.75, y: Self.pill - 2)
            Text("Today")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Self.pillWidth, height: 15)
                .background(Color.accentColor, in: Capsule())
                .offset(x: pillStart)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    private func help(_ slot: SlotSummary) -> String {
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        return "\(slot.name) · Code freeze \(slot.dates.codeFreeze.formatted(format)), early access \(slot.dates.earlyAccess.formatted(format)), release \(slot.dates.release.formatted(format))"
    }
}

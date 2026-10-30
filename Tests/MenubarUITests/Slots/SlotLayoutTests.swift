import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("SlotLayout")
struct SlotLayoutTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }()

    private static func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// the slots a team on the 3-week cadence shows on 30 October 2026, with the default rules: 2026.45, 2026.48,
    /// 2026.51, 2027.03
    private static let cadence: [SlotDates] = ["2026.45", "2026.48", "2026.51", "2027.03"].map {
        SlotRules(team: TeamValues()).dates(of: SlotName($0)!, calendar: calendar)!
    }

    /// 10:42 on Fri 30 Oct 2026
    private static let today = day(10, 30).addingTimeInterval(10 * 3600 + 42 * 60)

    @Test("SLOT-02 the steps: passed ones before today, the next one from today on, the line filled to the last passed")
    func steps() {
        let current = SlotMilestones(dates: Self.cadence[0], today: Self.today, calendar: Self.calendar)
        #expect(current.steps.map(\.phase) == [.passed, .passed, .next])
        #expect(current.steps.map(\.relative) == ["21 days ago", "11 days ago", "in 3 days"])
        #expect(current.filled == 0.5)
        // 2026.48 freezes today: today is the next step, not a passed one
        let freezing = SlotMilestones(dates: Self.cadence[1], today: Self.today, calendar: Self.calendar)
        #expect(freezing.steps.map(\.phase) == [.next, .later, .later])
        #expect(freezing.steps[0].relative == "today")
        #expect(freezing.filled == 0)
        // all passed: an overdue slot's line is full
        let overdue = SlotMilestones(dates: Self.cadence[0], today: Self.day(11, 10), calendar: Self.calendar)
        #expect(overdue.steps.map(\.phase) == [.passed, .passed, .passed])
        #expect(overdue.filled == 1)
        let help = SlotMilestones.help(of: SlotMilestones(dates: Self.cadence[2], today: Self.today, calendar: Self.calendar).steps[0])
        #expect(help.contains("Code freeze") && help.contains("In 21 days"))
    }

    @Test("SLOT-02 the step names don't overlap at 480 points")
    func stepsDontOverlap() {
        // a 480-point window: 16 points of section padding and 14 of card padding on each side
        for width in [480 - 60, 560 - 60, 760 - 60] as [CGFloat] {
            let spans = SlotMilestones.labelSpans(count: 3, width: width)
            #expect(zip(spans, spans.dropFirst()).allSatisfy { $1.lowerBound - $0.upperBound >= 8 })
            #expect(spans.first!.lowerBound >= 0 && spans.last!.upperBound <= width)
        }
    }

    @Test("SLOT-02 the roadmap is one date scale: today at its real date, never moved onto a slot's date, months don't overlap")
    func roadmap() {
        let width: CGFloat = 358
        let layout = SlotRoadmapLayout(slots: Self.cadence, today: Self.today, width: width, calendar: Self.calendar)
        let perDay = (layout.bars[2].start - layout.bars[1].start) / 21
        // 2026.48 freezes today, 2026.51 in 21 days: today sits on the first and 21 days before the second
        #expect(abs(layout.todayX - layout.bars[1].start) < 0.5)
        #expect(abs(layout.bars[2].start - layout.todayX - 21 * perDay) < 0.5)
        // 2026.45's release in 3 days is 3 days right of today, not on it
        #expect(abs(layout.bars[0].end - layout.todayX - 3 * perDay) < 0.5)
        // a later today moves the line, not the bars
        let later = SlotRoadmapLayout(slots: Self.cadence, today: Self.day(11, 5), width: width, calendar: Self.calendar)
        #expect(later.bars == layout.bars)
        #expect(abs(later.todayX - layout.todayX - 6 * perDay) < 0.5)
        // everything inside the axis, early access inside each bar
        #expect(layout.bars.allSatisfy { $0.start > 0 && $0.start < $0.earlyAccess && $0.earlyAccess < $0.end && $0.end < width })
        // months: Nov, Dec and Jan 2027, named without overlap and inside the width, even over a year
        #expect(layout.ticks.compactMap(\.title).first == "Nov")
        let year = SlotRoadmapLayout(slots: Self.cadence + [SlotDates(release: Self.day(10, 4, year: 2027), codeFreeze: Self.day(9, 10, year: 2027), earlyAccess: Self.day(9, 20, year: 2027))], today: Self.today, width: width, calendar: Self.calendar)
        for ticks in [layout.ticks, year.ticks] {
            let named = ticks.filter { $0.title != nil }.map(\.x)
            #expect(zip(named, named.dropFirst()).allSatisfy { $1 - $0 >= SlotRoadmapLayout.tickTitleWidth })
            #expect(named.allSatisfy { $0 + SlotRoadmapLayout.tickTitleWidth <= width })
        }
        // the pill stays inside, the line doesn't move
        #expect(SlotRoadmapLayout.pillStart(todayX: 4, pillWidth: 46, width: width) == 0)
    }
}

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
        #expect(current.filled == 0.5)
        // 2026.48 freezes today: today is the next step, not a passed one
        let freezing = SlotMilestones(dates: Self.cadence[1], today: Self.today, calendar: Self.calendar)
        #expect(freezing.steps.map(\.phase) == [.next, .later, .later])
        #expect(freezing.filled == 0)
        // all passed: an overdue slot's line is full
        let overdue = SlotMilestones(dates: Self.cadence[0], today: Self.day(11, 10), calendar: Self.calendar)
        #expect(overdue.steps.map(\.phase) == [.passed, .passed, .passed])
        #expect(overdue.filled == 1)
    }

    @Test("SLOT-02 the today marker sits by date inside its segment, and nowhere before, on a step's day or after")
    func todayMarker() {
        // 2026.45: code freeze Fri 9 Oct, early access Mon 19 Oct (10 days), release Mon 2 Nov (14 days)
        func position(_ today: Date) -> SlotMilestones.TodayPosition? {
            SlotMilestones(dates: Self.cadence[0], today: today, calendar: Self.calendar).today
        }
        #expect(position(Self.day(10, 8)) == nil)
        let first = position(Self.day(10, 13).addingTimeInterval(15 * 3600))
        #expect(first?.fraction == 0.2)
        let second = position(Self.day(10, 26))
        #expect(second?.fraction == (1 + 7.0 / 14) / 2)
        #expect(second?.toward == .release)
        for day in [(10, 9), (10, 19), (11, 2)] {
            #expect(position(Self.day(day.0, day.1)) == nil)
        }
        #expect(position(Self.day(11, 3)) == nil)
        let steps = SlotMilestones(dates: Self.cadence[0], today: Self.today, calendar: Self.calendar).steps
        #expect(SlotMilestones.todayFraction(today: Self.day(10, 14), steps: steps, calendar: Self.calendar) == 0.25)
    }
}

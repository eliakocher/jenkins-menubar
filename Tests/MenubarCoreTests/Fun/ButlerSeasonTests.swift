import Foundation
import Testing

@testable import MenubarCore

/// FUN-03 and FUN-05: the seasons of the butler's art (Carnival, Easter, Halloween, New Year, Santa) and the weather over a
/// failed build's butler.
@Suite("ButlerSeason")
struct ButlerSeasonTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func season(_ year: Int, _ month: Int, _ day: Int, _ level: FunLevel = .normal) -> ButlerSeason? {
        ButlerSeason.current(on: date(year, month, day), calendar: calendar, level: level)
    }

    @Test("FUN-03 Halloween runs from October 17 to November 7, every year")
    func halloween() {
        #expect(Self.season(2026, 10, 16) == nil)
        #expect(Self.season(2026, 10, 17) == .halloween && Self.season(2026, 10, 31) == .halloween)
        #expect(Self.season(2026, 11, 7) == .halloween)
        #expect(Self.season(2026, 11, 8) == nil)
        #expect(Self.season(2031, 10, 17) == .halloween && Self.season(2031, 11, 7) == .halloween)
    }

    @Test("FUN-03 New Year runs from December 31 to January 14 and takes over from Santa on the 31st")
    func newYear() {
        #expect(Self.season(2026, 12, 30) == .santa)
        #expect(Self.season(2026, 12, 31) == .newYear && Self.season(2027, 1, 1) == .newYear)
        #expect(Self.season(2027, 1, 14) == .newYear)
        #expect(Self.season(2027, 1, 15) == nil)
        #expect(Self.season(2026, 12, 1) == .santa && Self.season(2026, 11, 30) == nil)
    }

    @Test(
        "FUN-03 Carnival shows only on the days of the table, both ends included",
        arguments: [
            ((2027, 2, 10), (2027, 2, 20)), ((2028, 3, 3), (2028, 3, 13)), ((2029, 2, 15), (2029, 2, 26)),
            ((2030, 3, 5), (2030, 3, 20)),
        ] as [((Int, Int, Int), (Int, Int, Int))])
    func carnival(first: (Int, Int, Int), last: (Int, Int, Int)) {
        func season(_ day: (Int, Int, Int), by offset: Int = 0) -> ButlerSeason? {
            let base = Self.date(day.0, day.1, day.2)
            let shifted = Self.calendar.date(byAdding: .day, value: offset, to: base)!
            return ButlerSeason.current(on: shifted, calendar: Self.calendar, level: .normal)
        }
        #expect(season(first, by: -1) != .carnival)
        #expect(season(first) == .carnival && season(last) == .carnival)
        #expect(season(last, by: 1) != .carnival)
    }

    @Test("FUN-03 a year without a Carnival entry has none")
    func noCarnival() {
        for year in [2026, 2031] {
            for (month, day) in [(2, 10), (2, 20), (3, 5), (3, 13)] {
                #expect(Self.season(year, month, day) != .carnival)
            }
        }
    }

    @Test(
        "FUN-03 Western Easter Sunday by the computus",
        arguments: [
            (2027, 3, 28), (2028, 4, 16), (2029, 4, 1), (2030, 4, 21), (2031, 4, 13), (2038, 4, 25), (2026, 4, 5),
        ] as [(Int, Int, Int)])
    func easterSunday(year: Int, month: Int, day: Int) {
        #expect(ButlerSeason.easterSunday(of: year) == ButlerSeason.Day(year, month, day))
    }

    @Test("FUN-03 Easter shows from Palm Sunday to Easter Monday")
    func easter() {
        // Easter 2027 is March 28: Palm Sunday March 21, Easter Monday March 29
        #expect(Self.season(2027, 3, 20) == nil)
        #expect(Self.season(2027, 3, 21) == .easter && Self.season(2027, 3, 28) == .easter && Self.season(2027, 3, 29) == .easter)
        #expect(Self.season(2027, 3, 30) == nil)
        // Easter 2029 is April 1: the week starts in March
        #expect(Self.season(2029, 3, 25) == .easter && Self.season(2029, 4, 2) == .easter && Self.season(2029, 4, 3) == nil)
    }

    @Test("FUN-03 the seasons other than Santa need Normal; Santa shows at every level")
    func levels() {
        #expect(Self.season(2026, 10, 20, .subtle) == nil && Self.season(2026, 10, 20, .normal) == .halloween)
        #expect(Self.season(2026, 10, 20, .party) == .halloween)
        #expect(Self.season(2027, 2, 12, .subtle) == nil && Self.season(2027, 2, 12, .party) == .carnival)
        #expect(Self.season(2026, 12, 31, .subtle) == .santa && Self.season(2026, 12, 31, .normal) == .newYear)
        #expect(Self.season(2026, 12, 10, .subtle) == .santa)
    }

    @Test("FUN-03 when seasons overlap: Carnival, Easter, Halloween, New Year, then Santa")
    func order() {
        #expect(ButlerSeason.allCases == [.carnival, .easter, .halloween, .newYear, .santa])
        // `current(on:)` takes the first case that contains the day, so the case order is the overlap order.
        // December 31 is in both New Year and Santa's month: New Year wins.
        #expect(Self.season(2026, 12, 31) == .newYear)
    }

    @Test("FUN-03 every season maps to a hat")
    func hats() {
        #expect(ButlerSeason.allCases.map(\.hat) == [.carnival, .easter, .witch, .newYear, .santa])
    }

    // MARK: FUN-05 the weather

    private static func weather(
        _ result: BuildResult, memory: inout EggMemory, at now: Date, level: FunLevel, enabled: Bool = true
    ) -> SadWeather? {
        EggRules.annotate(
            [EggAlertTests.alert("MR-9", 7, result)], memory: &memory, now: now, calendar: calendar, enabled: enabled, level: level
        )[0].content.weather
    }

    @Test("FUN-05 a failed build gets rain, an unstable one a drizzle, from Normal; never a green or aborted one")
    func weatherByResult() {
        let wednesday = Self.date(2026, 11, 4)
        var memory = EggMemory()
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .normal) == .rain)
        #expect(Self.weather(.unstable, memory: &memory, at: wednesday, level: .normal) == .drizzle)
        #expect(Self.weather(.success, memory: &memory, at: wednesday, level: .party) == nil)
        #expect(Self.weather(.aborted, memory: &memory, at: wednesday, level: .party) == nil)
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .subtle) == nil)
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .party) == .rain)
    }

    @Test("FUN-05 the third failure in a row and a Friday failure after 16:00 get a storm at Party only")
    func storm() {
        let wednesday = Self.date(2026, 11, 4)
        var memory = EggMemory()
        memory.redRuns["MR-9"] = 2
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .normal) == .rain)
        memory.redRuns["MR-9"] = 2
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .party) == .storm)
        // the fourth is plain rain again
        #expect(Self.weather(.failure, memory: &memory, at: wednesday, level: .party) == .rain)
        // 2026-11-06 is a Friday
        var fresh = EggMemory()
        #expect(Self.weather(.failure, memory: &fresh, at: Self.date(2026, 11, 6, 16), level: .party) == .storm)
        #expect(Self.weather(.failure, memory: &fresh, at: Self.date(2026, 11, 6, 15), level: .party) == .rain)
        #expect(Self.weather(.failure, memory: &fresh, at: Self.date(2026, 11, 6, 17), level: .normal) == .rain)
    }

    @Test("FUN-05 no weather with the easter eggs off")
    func weatherOff() {
        var memory = EggMemory()
        #expect(Self.weather(.failure, memory: &memory, at: Self.date(2026, 11, 4), level: .party, enabled: false) == nil)
    }
}

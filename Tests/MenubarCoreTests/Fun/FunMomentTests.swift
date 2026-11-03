import Foundation
import Testing

@testable import MenubarCore

/// FUN-01 to FUN-04: the moments that react to real builds, the streak counter, the hats and the celebrations.
@Suite("FunMoments")
struct FunMomentTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-02 is a Monday, 11-04 a Wednesday, 11-06 a Friday
    private static func date(_ month: Int, _ day: Int, _ hour: Int = 14, _ minute: Int = 30, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func run(
        _ alerts: [BuildAlert], store: FunStore, memory: inout EggMemory, at now: Date, level: FunLevel = .normal,
        enabled: Bool = true
    ) -> [BuildAlert] {
        EggRules.annotate(alerts, memory: &memory, now: now, calendar: calendar, enabled: enabled, level: level, fun: store)
    }

    private static func one(
        _ job: String, _ number: Int, _ result: BuildResult, at now: Date, store: FunStore, memory: inout EggMemory,
        duration: TimeInterval = 600, level: FunLevel = .normal
    ) -> BuildAlert {
        run([EggAlertTests.alert(job, number, result, duration: duration)], store: store, memory: &memory, at: now, level: level)[0]
    }

    private static let wednesday = date(11, 4)

    @Test("FUN-01 the first green build after red ones is a redemption, once per redemption")
    func redemption() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        _ = Self.one("MR-9", 1, .failure, at: Self.wednesday, store: store, memory: &memory)
        let green = Self.one("MR-9", 2, .success, at: Self.wednesday, store: store, memory: &memory)
        #expect(FunLines.redemption.contains(green.content.eggLine ?? ""))
        #expect(green.content.celebration == .confetti)
        // The next green build is no redemption.
        let again = Self.one("MR-9", 3, .success, at: Self.wednesday, store: store, memory: &memory)
        #expect(!FunLines.redemption.contains(again.content.eggLine ?? ""))
        #expect(again.content.celebration == nil)
    }

    @Test("FUN-01 a green streak of 5, 10 and 25 gets its fire line; a red build ends the streak")
    func streaks() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        var lines: [Int: String] = [:]
        for number in 1...25 {
            let alert = Self.one("MR-\(number)", 1, .success, at: Self.wednesday, store: store, memory: &memory)
            if let line = alert.content.eggLine, line.hasPrefix("🔥") {
                lines[number] = line
            }
            // The party hat's own line at the third green build is the old egg; streak lines start at 5.
        }
        #expect(Set(lines.keys) == [5, 10, 25])
        #expect(lines[10]?.hasPrefix("🔥 10 green in a row. ") == true)
        #expect(store.snapshot.greenStreak == 25 && store.snapshot.bestStreak == 25)
        // Aborted builds neither add nor end it; a red one ends it.
        _ = Self.one("MR-1", 2, .aborted, at: Self.wednesday, store: store, memory: &memory)
        #expect(store.snapshot.greenStreak == 25)
        _ = Self.one("MR-1", 3, .failure, at: Self.wednesday, store: store, memory: &memory)
        #expect(store.snapshot.greenStreak == 0 && store.snapshot.bestStreak == 25)
        // 10 and more get confetti, 5 does not.
        var other = EggMemory()
        let fresh = FunStore(calendar: Self.calendar)
        var celebrations: [FunCelebration?] = []
        for number in 1...10 {
            celebrations.append(Self.one("MR-\(number)", 1, .success, at: Self.wednesday, store: fresh, memory: &other).content.celebration)
        }
        #expect(celebrations[4] == nil && celebrations[9] == .confetti)
    }

    @Test("FUN-01 the third failure in a row on one merge request, and only that one")
    func thirdFailure() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        let lines = (1...4).map { number in
            Self.one("MR-5", number, .failure, at: Self.wednesday, store: store, memory: &memory).content.eggLine
        }
        #expect(lines[0] == nil && lines[1] == nil)
        #expect(FunLines.thirdFailure.contains(lines[2] ?? ""))
        #expect(!FunLines.thirdFailure.contains(lines[3] ?? ""))
        // Another job's failures are counted apart.
        var other = EggMemory()
        let first = Self.one("MR-6", 1, .failure, at: Self.wednesday, store: FunStore(calendar: Self.calendar), memory: &other)
        #expect(first.content.eggLine == nil)
    }

    @Test("FUN-01 a failure on a Friday after 16:00, once a day; never before 16:00 or on another day")
    func fridayFailure() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        func line(_ job: String, _ result: BuildResult, at date: Date) -> String? {
            Self.one(job, 1, result, at: date, store: store, memory: &memory).content.eggLine
        }
        #expect(!FunLines.fridayFail.contains(line("MR-1", .failure, at: Self.date(11, 6, 15, 59)) ?? ""))
        #expect(!FunLines.fridayFail.contains(line("MR-2", .failure, at: Self.date(11, 5, 17, 0)) ?? ""))
        #expect(FunLines.fridayFail.contains(line("MR-3", .failure, at: Self.date(11, 6, 16, 0)) ?? ""))
        // Once a day.
        #expect(!FunLines.fridayFail.contains(line("MR-4", .failure, at: Self.date(11, 6, 17, 30)) ?? ""))
        // A green build on Friday afternoon is none.
        #expect(!FunLines.fridayFail.contains(line("MR-5", .success, at: Self.date(11, 13, 16, 30)) ?? ""))
        // The next Friday it comes again.
        #expect(FunLines.fridayFail.contains(line("MR-6", .unstable, at: Self.date(11, 13, 16, 30)) ?? ""))
    }

    @Test("FUN-01 a build over an hour is a long build; Monday's first build gets its line, once")
    func longBuildAndMonday() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        let short = Self.one("MR-1", 7, .success, at: Self.wednesday, store: store, memory: &memory, duration: 3599)
        let long = Self.one("MR-2", 7, .success, at: Self.wednesday, store: store, memory: &memory, duration: 3600 + 12 * 60)
        #expect(short.content.eggLine == nil)
        #expect(long.content.eggLine?.contains("1h12m") == true)
        #expect(long.content.eggLine?.contains("{") == false)

        let monday = Self.date(11, 2, 9, 0)
        let first = Self.one("MR-3", 7, .success, at: monday, store: store, memory: &memory)
        let second = Self.one("MR-4", 7, .success, at: monday, store: store, memory: &memory)
        #expect(FunLines.mondayFirst.contains(first.content.eggLine ?? ""))
        #expect(!FunLines.mondayFirst.contains(second.content.eggLine ?? ""))
    }

    @Test("FUN-02 Subtle plays only the old eggs, and with the eggs off nothing is added but the counters move")
    func levels() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        _ = Self.one("MR-9", 1, .failure, at: Self.wednesday, store: store, memory: &memory, level: .subtle)
        let green = Self.one("MR-9", 2, .success, at: Self.wednesday, store: store, memory: &memory, level: .subtle)
        #expect(!FunLines.redemption.contains(green.content.eggLine ?? ""))
        #expect(green.content.celebration == nil && green.content.funLevel == nil)

        let off = Self.run(
            [EggAlertTests.alert("MR-9", 3, .success)], store: store, memory: &memory, at: Self.wednesday, enabled: false)
        #expect(off[0].content.eggLine == nil && off[0].content.celebration == nil)
        #expect(store.snapshot.buildsSeen == 3 && store.snapshot.greenStreak == 2)
        // Normal and Party tell the alert's butler how much to move.
        let normal = Self.one("MR-9", 4, .success, at: Self.wednesday, store: store, memory: &memory)
        #expect(normal.content.funLevel == .normal)
    }

    @Test("FUN-02 a thousandth build gets confetti; New Year and the anniversary get fireworks at Party, once a day")
    func celebrations() {
        let store = FunStore(calendar: Self.calendar)
        var memory = EggMemory()
        let thousand = Self.one("MR-1", 1000, .success, at: Self.wednesday, store: store, memory: &memory)
        #expect(thousand.content.celebration == .confetti)
        let newYear = Self.date(1, 1, 10, 0, year: 2027)
        let normal = Self.one("MR-2", 5, .success, at: newYear, store: store, memory: &memory, level: .normal)
        #expect(normal.content.celebration != .fireworks)
        let party = Self.one("MR-3", 5, .success, at: newYear, store: store, memory: &memory, level: .party)
        #expect(party.content.celebration == .fireworks)
        let later = Self.one("MR-4", 5, .success, at: newYear.addingTimeInterval(3600), store: store, memory: &memory, level: .party)
        #expect(later.content.celebration != .fireworks)
    }

    @Test("FUN-03 the hat of the day: Santa all December but New Year's Eve; the other seasons need Normal")
    func hats() {
        let memory = EggMemory()
        func hat(_ month: Int, _ day: Int, _ level: FunLevel, year: Int = 2026) -> ButlerHat? {
            EggRules.hat(memory: memory, now: Self.date(month, day, year: year), calendar: Self.calendar, level: level)
        }
        #expect(hat(10, 28, .party) == .witch && hat(10, 28, .normal) == .witch && hat(10, 28, .subtle) == nil)
        #expect(hat(12, 31, .party) == .newYear && hat(1, 2, .normal, year: 2027) == .newYear)
        #expect(hat(12, 31, .subtle) == .santa && hat(12, 15, .party) == .santa && hat(12, 15, .subtle) == .santa)
        #expect(hat(11, 8, .party) == nil)
    }
}

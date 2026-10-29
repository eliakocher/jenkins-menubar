import Foundation
import Testing

@testable import MenubarCore

@Suite("EggAlerts")
struct EggAlertTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let jobURL = URL(string: "https://jenkins.example.com/job/team/job/project")!

    /// a time on a calendar day, in the tests' time zone; the default day is a Wednesday without a special date
    static func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 16, _ hour: Int = 14, _ minute: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// the alert of a finished build
    static func alert(
        _ job: String = "MR-1", _ number: Int = 7, _ result: BuildResult = .success, kind: JobKind = .mine,
        duration: TimeInterval = 600, estimate: TimeInterval? = nil, tests: TestCounts? = nil
    ) -> BuildAlert {
        let build = Build(
            job: job, number: number, title: "Fix the login", kind: kind,
            phase: .finished(result: result, duration: duration), startedAt: date(), estimatedDuration: estimate,
            testCounts: tests)
        let content = AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: jobURL))!
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    /// the egg lines of the alerts of one check
    private static func lines(
        _ alerts: [BuildAlert], memory: inout EggMemory, at now: Date = date(), enabled: Bool = true
    ) -> [String?] {
        EggRules.annotate(alerts, memory: &memory, now: now, calendar: calendar, enabled: enabled).map(\.content.eggLine)
    }

    private static func line(_ alert: BuildAlert, memory: EggMemory = EggMemory(), at now: Date = date()) -> String? {
        var memory = memory
        return lines([alert], memory: &memory, at: now).first.flatMap { $0 }
    }

    // MARK: EGG-12

    private static let numberCases: [(Int, BuildResult, String?)] = [
        (42, BuildResult.failure, "Build #42. The answer to everything. The question is still in review."),
        (404, .success, "Build #404. Found it, surprisingly."),
        (404, .failure, "Build #404: success not found."),
        (1337, .unstable, "Build #1337. Very l33t."),
        (314, .success, "Build #314. π, roughly."),
        (2000, .success, "Build #2000. The butler would like a raise."),
        (10000, .failure, "Build #10000. The butler has seen things. Some of them were green."),
        (41, .success, nil),
        (1001, .success, nil),
    ]

    @Test("EGG-12 build numbers and milestones get their line", arguments: numberCases)
    func buildNumbers(number: Int, result: BuildResult, expected: String?) {
        #expect(Self.line(Self.alert("feature%252Ffoo", number, result)) == expected)
    }

    // MARK: EGG-13

    @Test("EGG-13 the job's history decides the line")
    func history() {
        var memory = EggMemory()
        let results: [BuildResult] = [.failure, .unstable, .failure, .failure, .failure, .aborted, .failure]
        var lines: [String?] = []
        for (index, result) in results.enumerated() {
            lines += Self.lines([Self.alert("MR-5", 11 + index, result)], memory: &memory)
        }
        // A merge request job: no line for the first two, then the tissues grow; ABORTED neither adds nor ends the run.
        #expect(lines == [
            nil, nil, "Third failure in a row. The butler is out of tissues.",
            "Fourth in a row. The butler has moved on to the curtains.",
            "Failure #5 in a row. The butler isn't crying. It's the rain.", nil,
            "Failure #6 in a row. The butler isn't crying. It's the rain.",
        ])
        #expect(Self.lines([Self.alert("MR-5", 20, .success)], memory: &memory) == [nil])
        #expect(memory.redRuns["MR-5"] == nil)
    }

    @Test("EGG-13 a branch job, the first and the tenth run of a merge request")
    func kingAndRuns() {
        var memory = EggMemory()
        #expect(Self.lines([Self.alert("main", 5, .failure)], memory: &memory) == ["You come at the king, you best not miss."])
        #expect(Self.lines([Self.alert("main", 6, .success)], memory: &memory) == ["The king stay the king."])
        #expect(Self.lines([Self.alert("main", 7, .success)], memory: &memory) == [nil])
        #expect(Self.lines([Self.alert("MR-8", 1, .success)], memory: &memory)
            == ["First try. Screenshot this, nobody will believe you."])
        #expect(Self.lines([Self.alert("MR-8", 1, .failure)], memory: &memory) == [nil])
        #expect(Self.lines([Self.alert("MR-8", 10, .success)], memory: &memory)
            == ["Ten runs. At this point it's a relationship."])
        #expect(Self.lines([Self.alert("MR-8", 10, .failure)], memory: &memory) == ["Run #10. The game is the game."])
    }

    // MARK: EGG-14

    private static let factCases: [(BuildResult, TestCounts, TimeInterval, TimeInterval, String?)] = [
        (BuildResult.failure, TestCounts(failed: 40, total: 40), 600.0, 0.0, "Sheeeeeeit."),
        (.failure, TestCounts(failed: 9, total: 9), 600, 0, nil),
        (.success, TestCounts(failed: 40, total: 40), 600, 0, nil),
        (.unstable, TestCounts(failed: 1, total: 1200), 600, 0, "One test. One. Out of 1200."),
        (.unstable, TestCounts(failed: 1, total: 99), 600, 0, nil),
        (.success, TestCounts(failed: 0, total: 10), 1200, 600, "Twice the estimate. Still faster than the spellcheck."),
        (.success, TestCounts(failed: 0, total: 10), 1199, 600, nil),
        (.failure, TestCounts(failed: 3, total: 50), 3 * 3600, 0, "Deserve got nothin' to do with it."),
        (.unstable, TestCounts(failed: 3, total: 50), 3 * 3600, 0, nil),
    ]

    @Test("EGG-14 the build's facts decide the line", arguments: factCases)
    func facts(result: BuildResult, tests: TestCounts, duration: TimeInterval, estimate: TimeInterval, expected: String?) {
        let alert = Self.alert("MR-3", 7, result, duration: duration, estimate: estimate > 0 ? estimate : nil, tests: tests)
        #expect(Self.line(alert) == expected)
    }

    // MARK: EGG-15

    @Test("EGG-15 Jinx goes to the later alert of one check, for the same result of a mine and a watched build")
    func jinx() {
        var memory = EggMemory()
        let mine = Self.alert("MR-1", 7, .failure, kind: .mine)
        let watched = Self.alert("MR-2", 7, .failure, kind: .watched)
        #expect(Self.lines([mine, watched], memory: &memory) == [nil, "Jinx. You owe each other a coffee."])
        var fresh = EggMemory()
        #expect(Self.lines([mine, Self.alert("MR-2", 7, .success, kind: .watched)], memory: &fresh) == [nil, nil])
        fresh = EggMemory()
        #expect(Self.lines([mine, Self.alert("MR-4", 7, .failure, kind: .mine)], memory: &fresh) == [nil, nil])
    }

    // MARK: EGG-16

    @Test("EGG-16 the clock lines show once a night and once a day")
    func clock() {
        var memory = EggMemory()
        let late = Self.date(2026, 9, 16, 23, 40)
        #expect(Self.lines([Self.alert()], memory: &memory, at: late) == ["It's 23:40. The build is done; you should be too."])
        // The same night, past midnight: nothing; the next night: again.
        #expect(Self.lines([Self.alert()], memory: &memory, at: Self.date(2026, 9, 17, 1, 5)) == [nil])
        #expect(Self.lines([Self.alert()], memory: &memory, at: Self.date(2026, 9, 17, 22, 0))
            == ["It's 22:00. The build is done; you should be too."])
        #expect(Self.lines([Self.alert()], memory: &memory, at: Self.date(2026, 9, 18, 4, 59)) == [nil])

        // A Saturday, once.
        let saturday = Self.date(2026, 9, 19, 11, 0)
        #expect(Self.lines([Self.alert()], memory: &memory, at: saturday) == ["A weekend build. The butler is billing overtime."])
        #expect(Self.lines([Self.alert()], memory: &memory, at: saturday) == [nil])
        #expect(Self.lines([Self.alert()], memory: &memory, at: Self.date(2026, 9, 20, 11, 0))
            == ["A weekend build. The butler is billing overtime."])
    }

    // MARK: EGG-17

    private static let dayCases: [(Int, Int, Int, BuildResult, String?)] = [
        (2028, 10, 31, BuildResult.success, "Treat."),
        (2028, 10, 31, .failure, "Trick."),
        (2026, 5, 25, .failure, "Don't panic. The butler brought a towel."),
        (2026, 5, 25, .success, nil),
        (2028, 3, 14, .success, "Happy π Day. Irrational, like this pipeline."),
        (2026, 11, 13, .success, "Friday the 13th. The tests know."),
        (2027, 9, 13, .success, "Day 256 (0x100). Happy Programmers' Day."),
        (2028, 9, 12, .success, "Day 256 (0x100). Happy Programmers' Day."),
        (2028, 9, 13, .success, nil),
        (2026, 6, 17, .success, nil),
    ]

    @Test("EGG-17 the calendar days", arguments: dayCases)
    func calendarDays(year: Int, month: Int, day: Int, result: BuildResult, expected: String?) {
        // Midday on a weekday, so the clock lines stay out of it.
        var memory = EggMemory(lastAlertYear: year)
        #expect(Self.lines([Self.alert("MR-1", 7, result)], memory: &memory, at: Self.date(year, month, day, 12, 0)) == [expected])
    }

    @Test("EGG-17 the first build of the year shows once, and not before there was a build to compare with")
    func firstBuildOfTheYear() {
        var memory = EggMemory()
        let tuesday = Self.date(2027, 6, 1, 12, 0)
        #expect(Self.lines([Self.alert()], memory: &memory, at: Self.date(2026, 12, 30, 12, 0)) == [nil])
        #expect(memory.lastAlertYear == 2026)
        #expect(Self.lines([Self.alert(), Self.alert("MR-2")], memory: &memory, at: tuesday)
            == ["First build of the year. No pressure.", nil])
    }

    // MARK: EGG-03, EGG-04

    @Test("EGG-03 three green builds since midnight give the party hat until the next red one")
    func partyHat() {
        var memory = EggMemory()
        let morning = Self.date(2026, 9, 16, 9, 0)
        func hat(_ alerts: [BuildAlert], at now: Date) -> [ButlerHat?] {
            EggRules.annotate(alerts, memory: &memory, now: now, calendar: Self.calendar, enabled: true).map(\.content.hat)
        }
        #expect(hat([Self.alert("MR-1", 7), Self.alert("MR-2", 7)], at: morning) == [nil, nil])
        // The third starts the streak: the line, and the happy butler's hat.
        let third = EggRules.annotate([Self.alert("MR-3", 7)], memory: &memory, now: morning, calendar: Self.calendar, enabled: true)
        #expect(third.first?.content.eggLine == "Three for three today. The butler put on a party hat.")
        #expect(third.first?.content.hat == .party)
        #expect(EggRules.hat(memory: memory, now: morning, calendar: Self.calendar) == .party)
        // The hat stays on the next day, and the sad butler never wears it; the next red build takes it off.
        let next = Self.date(2026, 9, 17, 9, 0)
        #expect(EggRules.hat(memory: memory, now: next, calendar: Self.calendar) == .party)
        #expect(hat([Self.alert("MR-1", 8, .failure)], at: next) == [nil])
        #expect(EggRules.hat(memory: memory, now: next, calendar: Self.calendar) == nil)
        // A red build blocks the day's streak: three greens after it don't count.
        _ = hat([Self.alert("MR-1", 9), Self.alert("MR-2", 8), Self.alert("MR-3", 8)], at: next)
        #expect(EggRules.hat(memory: memory, now: next, calendar: Self.calendar) == nil)
        // ABORTED counts neither way.
        let day = Self.date(2026, 9, 18, 9, 0)
        _ = hat([Self.alert("MR-1", 10), Self.alert("MR-1", 11, .aborted), Self.alert("MR-2", 9)], at: day)
        #expect(EggRules.hat(memory: memory, now: day, calendar: Self.calendar) == nil)
    }

    private static let santaCases: [(Int, ButlerHat?)] = [(23, nil), (24, .santa), (25, .santa), (26, .santa), (27, nil)]

    @Test("EGG-04 the Santa hat from December 24 to 26 wins over the party hat", arguments: santaCases)
    func santaHat(day: Int, expected: ButlerHat?) {
        let memory = EggMemory(partyHat: false)
        #expect(EggRules.hat(memory: memory, now: Self.date(2026, 12, day), calendar: Self.calendar) == expected)
        let streak = EggMemory(partyHat: true)
        #expect(EggRules.hat(memory: streak, now: Self.date(2026, 12, day), calendar: Self.calendar) == (expected ?? .party))
        // Both butlers wear the Santa hat in an alert, with the sad one's tissue.
        var forAlert = EggMemory()
        let alerts = EggRules.annotate(
            [Self.alert("MR-1", 7, .failure)], memory: &forAlert, now: Self.date(2026, 12, day), calendar: Self.calendar,
            enabled: true)
        #expect(alerts.first?.content.hat == expected)
    }

    // MARK: EGG-11

    @Test("EGG-11 one line per alert, the first rule wins, the banner ends with it and the log leaves it out")
    func oneLine() {
        var memory = EggMemory()
        // Build 42 (the number) beats the third red build in a row (the history) and the Sheeeeeeit (the facts).
        memory.redRuns["MR-9"] = 2
        let alert = Self.alert("MR-9", 42, .failure, tests: TestCounts(failed: 20, total: 20))
        let annotated = EggRules.annotate([alert], memory: &memory, now: Self.date(), calendar: Self.calendar, enabled: true)
        let content = annotated[0].content
        #expect(content.eggLine == "Build #42. The answer to everything. The question is still in review.")
        #expect(content.bannerBody.hasSuffix("\n" + (content.eggLine ?? "")))
        #expect(content.bannerBodyWithoutEggLine == alert.content.bannerBody)
        // The facts stay exactly as they were.
        #expect(content.facts == alert.content.facts)
        #expect(content.headline == alert.content.headline)
    }

    @Test("EGG-11 no line in a stage banner or a preview, and none with the eggs off")
    func noLine() throws {
        var memory = EggMemory()
        var stage = Self.alert("MR-1", 42)
        stage.kind = .stageFailed
        var preview = Self.alert("MR-1", 42)
        preview.kind = .preview
        let alerts = EggRules.annotate([stage, preview], memory: &memory, now: Self.date(), calendar: Self.calendar, enabled: true)
        #expect(alerts.map(\.content.eggLine) == [nil, nil])
        #expect(memory == EggMemory())

        // Off: the alert is untouched, though the memory goes on (the streak is there when they are switched on).
        let off = EggRules.annotate(
            [Self.alert("MR-1", 42), Self.alert("MR-2", 7), Self.alert("MR-3", 7)], memory: &memory, now: Self.date(),
            calendar: Self.calendar, enabled: false)
        #expect(off.map(\.content) == [Self.alert("MR-1", 42), Self.alert("MR-2", 7), Self.alert("MR-3", 7)].map(\.content))
        #expect(memory.partyHat)
    }
}

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

    // MARK: EGG-13

    @Test("EGG-13 the job's history decides the line")
    func history() {
        var memory = EggMemory()
        let results: [BuildResult] = [.failure, .unstable, .failure, .failure, .failure, .aborted, .failure]
        var lines: [String?] = []
        for (index, result) in results.enumerated() {
            lines += Self.lines([Self.alert("MR-5", 11 + index, result)], memory: &memory)
        }
        // A merge request job: no line for the first two, then one for every failure in a row; ABORTED neither adds nor
        // ends the run.
        #expect(lines.map { $0 != nil } == [false, false, true, true, true, false, true])
        #expect(Self.lines([Self.alert("MR-5", 20, .success)], memory: &memory) == [nil])
        #expect(memory.redRuns["MR-5"] == nil)
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
        #expect(third.first?.content.eggLine != nil)
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

    // MARK: EGG-11

    @Test("EGG-11 one line per alert, the first rule wins, the banner ends with it and the log leaves it out")
    func oneLine() {
        var memory = EggMemory()
        // Build 42 (the number) beats the third red build in a row (the history) and the Sheeeeeeit (the facts).
        memory.redRuns["MR-9"] = 2
        let alert = Self.alert("MR-9", 42, .failure, tests: TestCounts(failed: 20, total: 20))
        let annotated = EggRules.annotate([alert], memory: &memory, now: Self.date(), calendar: Self.calendar, enabled: true)
        let content = annotated[0].content
        #expect(content.eggLine?.hasPrefix("Build #42") == true)
        #expect(content.bannerBody.hasSuffix("\n" + (content.eggLine ?? "")))
        #expect(content.bannerBodyWithoutEggLine == alert.content.bannerBody)
        // The facts stay exactly as they were.
        #expect(content.facts == alert.content.facts)
        #expect(content.headline == alert.content.headline)
    }

    @Test("EGG-11 no line in a preview, and none with the eggs off")
    func noLine() throws {
        var memory = EggMemory()
        var preview = Self.alert("MR-1", 42)
        preview.kind = .preview
        let alerts = EggRules.annotate([preview], memory: &memory, now: Self.date(), calendar: Self.calendar, enabled: true)
        #expect(alerts.map(\.content.eggLine) == [nil])
        #expect(memory == EggMemory())

        // Off: the alert is untouched, though the memory goes on (the streak is there when they are switched on).
        let off = EggRules.annotate(
            [Self.alert("MR-1", 42), Self.alert("MR-2", 7), Self.alert("MR-3", 7)], memory: &memory, now: Self.date(),
            calendar: Self.calendar, enabled: false)
        #expect(off.map(\.content) == [Self.alert("MR-1", 42), Self.alert("MR-2", 7), Self.alert("MR-3", 7)].map(\.content))
        #expect(memory.partyHat)
    }
}

import Foundation
import Testing

@testable import MenubarCore

@Suite("EggRules")
struct EggRulesTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: EGG-06 to EGG-08

    private static let searchCases: [(String, EggRules.SearchMatch?)] = [
        ("sudo", .note("Nice try.")),
        ("  SUDO rm everything ", .note("Nice try.")),
        ("sudoku", nil),
        ("xyzzy", .note("Nothing happens.")),
        ("Works on my machine", .note("Then we'll ship your machine.")),
        ("rm -rf /", .note("Not today.")),
        ("rm -r", nil),
        ("coffee", .coffee),
        ("Spell-Check", .spellcheck),
        ("spell check", .spellcheck),
        ("jenkis", .typo("jenkins")),
        ("merge reqeust", .typo("merge request")),
        ("spellckeck", .typo("spellcheck")),
        ("jenkins", nil),
        ("", nil),
    ]

    @Test("EGG-06 the search words and the typos", arguments: searchCases)
    func searchWords(query: String, expected: EggRules.SearchMatch?) {
        #expect(EggRules.searchMatch(query) == expected)
    }

    @Test("EGG-06 coffee reads the real ETA")
    func coffee() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func running(_ elapsed: TimeInterval, estimate: TimeInterval?) -> Build {
            Build(
                job: "MR-1", number: 1, kind: .mine, phase: .running, startedAt: now.addingTimeInterval(-elapsed),
                estimatedDuration: estimate)
        }
        #expect(EggRules.coffeeNote(running: [], now: now) == "Nothing is running. Go anyway.")
        // The shortest ETA of the builds that have one, in PIPE-02's format.
        #expect(EggRules.coffeeNote(running: [running(300, estimate: 1500), running(0, estimate: 5000)], now: now)
            == "Your build has ~0h20m left. Go.")
        #expect(EggRules.coffeeNote(running: [running(2000, estimate: 1500)], now: now)
            == "Your build is past its estimate. Go anyway.")
        #expect(EggRules.coffeeNote(running: [running(2000, estimate: nil)], now: now)
            == "Your build is still running. Go anyway.")
    }

    @Test("EGG-07 the spellcheck demo notes", arguments: [
        (1, "Spellcheck demo #1. Exciting times."),
        (7, "Spellcheck demo #7. Same slides, new font."),
        (10, "Spellcheck demo #10. The butler knows the slides by heart."),
        (25, "Spellcheck demo #25. The butler presents it now."),
        (50, "Spellcheck demo #50. Sheeeeeeit."),
        (1234, "Spellcheck demo #1234. Same slides, new font."),
    ])
    func spellcheckNotes(count: Int, expected: String) {
        #expect(EggRules.spellcheckNote(count: count) == expected)
    }

    // MARK: EGG-02, EGG-09

    @Test("EGG-02 the Konami code needs its keys in order, at most 1.5 s apart")
    func konami() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ keys: [KonamiKey], gap: TimeInterval) -> [Bool] {
            var matcher = KonamiMatcher()
            return keys.enumerated().map { matcher.feed($1, at: start.addingTimeInterval(Double($0) * gap)) }
        }
        let code = KonamiMatcher.code
        #expect(run(code, gap: 0.5).last == true)
        #expect(run(code, gap: 0.5).dropLast().allSatisfy { !$0 })
        // A stray key before the code, or an extra ↑ inside it, doesn't hide it.
        #expect(run([.left, .up] + code, gap: 0.5).last == true)
        #expect(run([.up, .up, .up, .down, .down, .left, .right, .left, .right, .b, .a], gap: 0.5).last == true)
        // Too slow, or a wrong key.
        #expect(run(code, gap: 1.6).last == false)
        #expect(run(Array(code.dropLast()) + [.b], gap: 0.5).last == false)
        // Forgotten once it fired: the same keys again need the whole code.
        var matcher = KonamiMatcher()
        var fired = 0
        for (index, key) in (code + [.b, .a]).enumerated() where matcher.feed(key, at: start.addingTimeInterval(Double(index) * 0.2)) {
            fired += 1
        }
        #expect(fired == 1)
    }

    @Test("EGG-02 the bow has five frames of 0.4 s, and under Reduce Motion one frame for 1.6 s")
    func bow() {
        #expect(BowSequence.steps(reduceMotion: false).map(\.frame) == [.upright, .half, .full, .half, .upright])
        #expect(BowSequence.steps(reduceMotion: false).allSatisfy { $0.duration == .milliseconds(400) })
        #expect(BowSequence.steps(reduceMotion: true).map(\.frame) == [.full])
        #expect(BowSequence.steps(reduceMotion: true).map(\.duration) == [.milliseconds(1600)])
    }

    @Test("EGG-09 ten Check Nows within 10 s fire once per 10 min")
    func checkNowMashing() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func presses(_ gaps: [TimeInterval], counter: inout CheckMashCounter, from first: Date) -> [Bool] {
            var time = first
            return gaps.map { gap in
                time = time.addingTimeInterval(gap)
                return counter.press(at: time)
            }
        }
        var counter = CheckMashCounter()
        let fast = presses(Array(repeating: 1, count: 10), counter: &counter, from: start)
        #expect(fast == Array(repeating: false, count: 9) + [true])
        // Mashing again within 10 min stays quiet; after it, it fires again.
        #expect(presses(Array(repeating: 0.5, count: 10), counter: &counter, from: start.addingTimeInterval(30)).last == false)
        #expect(presses(Array(repeating: 0.5, count: 10), counter: &counter, from: start.addingTimeInterval(700)).last == true)
        // Ten presses spread over more than 10 s never fire.
        var slow = CheckMashCounter()
        #expect(presses(Array(repeating: 2, count: 20), counter: &slow, from: start).allSatisfy { !$0 })
    }

    // MARK: EGG-18 to EGG-20

    @Test("EGG-18 the watch lines", arguments: [
        ("paint dry", "Watching paint dry is not supported. Yet."),
        ("Grass Growing", "Watching grass grow is not supported. Yet."),
        ("the spellcheck", "Watching the spellcheck? Bring snacks. It takes a while."),
        (" autocorrect ", "Watching the spellcheck? Bring snacks. It takes a while."),
    ])
    func watchRefusals(text: String, expected: String) {
        #expect(EggRules.watchRefusal(text) == expected)
        #expect(EggRules.watchRefusal("!123") == nil)
    }

    @Test("EGG-18 deploying on a Friday from 16:00", arguments: [
        (2026, 9, 18, 15, false), (2026, 9, 18, 16, true), (2026, 9, 18, 23, true),
        (2026, 9, 17, 17, false), (2026, 9, 19, 17, false),
    ])
    func fridayDeploy(year: Int, month: Int, day: Int, hour: Int, expected: Bool) {
        let line = EggRules.fridayDeploy(now: Self.date(year, month, day, hour), calendar: Self.calendar)
        #expect((line == "Deploying on a Friday? Bold.") == expected)
        #expect(expected || line == nil)
    }

    private static let diffCases: [(MergeRequest.DiffStats?, String?)] = [
        (.init(additions: 5000, deletions: 4000, fileCount: 100), "That's not an MR, that's a migration."),
        (.init(additions: 1, deletions: 1, fileCount: 1), "One-line change. Famous last words."),
        (.init(additions: 2, deletions: 1, fileCount: 1), nil),
        (.init(additions: 40, deletions: 500, fileCount: 12), "Net negative code. The butler bows."),
        (.init(additions: 51, deletions: 500, fileCount: 12), nil),
        (.init(additions: 0, deletions: 499, fileCount: 12), nil),
        (nil, nil),
    ]

    @Test("EGG-19 the diff stat lines", arguments: diffCases)
    func diffLines(stats: MergeRequest.DiffStats?, expected: String?) {
        #expect(EggRules.diffLine(stats) == expected)
    }

    private static let birthdayCases: [(Date, Date, String?)] = [
        (date(2025, 9, 16), date(2026, 9, 16), "Untouched for a year today. Happy birthday, #31. 🎂"),
        (date(2023, 9, 16, 3), date(2026, 9, 16), "Untouched for 3 years today. Happy birthday, #31. 🎂"),
        (date(2026, 9, 16, 3), date(2026, 9, 16), nil),
        (date(2025, 9, 15), date(2026, 9, 16), nil),
        (date(2024, 2, 29), date(2027, 2, 28), "Untouched for 3 years today. Happy birthday, #31. 🎂"),
        (date(2024, 2, 29), date(2028, 2, 28), nil),
        (date(2024, 2, 29), date(2028, 2, 29), "Untouched for 4 years today. Happy birthday, #31. 🎂"),
    ]

    @Test("EGG-20 a work item's birthday", arguments: birthdayCases)
    func birthday(updated: Date, now: Date, expected: String?) {
        #expect(EggRules.birthday(reference: "#31", updatedAt: updated, now: now, calendar: Self.calendar) == expected)
    }

    // MARK: EGG-01, EGG-21

    @Test("EGG-01 the switch is on by default, and a stored preference without it reads as on")
    func theSwitch() throws {
        #expect(Preferences().easterEggs)
        let old = try JSONSerialization.data(withJSONObject: ["checkIntervalSeconds": 60])
        #expect(try JSONDecoder().decode(Preferences.self, from: old).easterEggs)
        var off = Preferences()
        off.easterEggs = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(off))
        #expect(!decoded.easterEggs)
    }

    @Test("EGG-21 the credits keep the butler's attribution with the eggs off")
    func credits() {
        #expect(EggRules.credits(eggs: false) == EggRules.attribution)
        #expect(EggRules.attribution.contains("CC BY-SA 3.0"))
        #expect(EggRules.attribution.contains("jenkins.io"))
        #expect(EggRules.credits(eggs: true).hasPrefix("Directed by the butler"))
        #expect(EggRules.credits(eggs: true).hasSuffix(EggRules.attribution))
    }

    @Test("EGG-11 the memory reads a file with missing keys")
    func memoryCoding() throws {
        let decoded = try JSONDecoder().decode(EggMemory.self, from: Data("{\"partyHat\":true}".utf8))
        #expect(decoded == EggMemory(partyHat: true))
        let memory = EggMemory(redRuns: ["MR-1": 2], greenDay: "2026-9-16", greensToday: 2, spellcheckDemos: 4, lastAlertYear: 2026)
        #expect(try JSONDecoder().decode(EggMemory.self, from: JSONEncoder().encode(memory)) == memory)
    }
}

@Suite("EggStage")
@MainActor
struct EggStageTests {
    @Test("EGG-02 the code plays the bow frame by frame, and the eggs off play nothing")
    func bowPlays() async {
        let clock = TestClock()
        let stage = EggStage(now: { Date(timeIntervalSince1970: 1_800_000_000) }, clock: clock)
        for key in KonamiMatcher.code {
            stage.key(key, enabled: false, reduceMotion: false)
        }
        #expect(stage.bow == nil)

        for key in KonamiMatcher.code {
            stage.key(key, enabled: true, reduceMotion: false)
        }
        var frames: [BowFrame?] = []
        for _ in 0..<5 {
            await clock.waitForSleepers()
            frames.append(stage.bow)
            clock.advance(by: .milliseconds(400))
        }
        for _ in 0..<100 where stage.bow != nil {
            await Task.yield()
        }
        #expect(frames == [.upright, .half, .full, .half, .upright])
        #expect(stage.bow == nil)
    }
}

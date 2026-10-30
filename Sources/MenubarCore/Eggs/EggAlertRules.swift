import Foundation

extension EggRules {
    /// Gives the alerts of a check their egg line and their hat, and notes them in the memory (`docs/easter-eggs.md`,
    /// rule 7).
    ///
    /// - A finished build's alert gets at most one line, from the first rule that matches, in this order: the build's
    ///   number, the job's history, the build's facts, Jinx, the clock, the calendar. The line is the last line of the
    ///   banner's body too.
    /// - A stage banner and a preview stay as they are, and so does everything with the eggs off; the memory is kept up
    ///   either way, so switching them on finds the streaks as they are.
    /// - The hat of a happy alert is the party hat during a green streak; of every alert, the Santa hat all of December.
    ///
    /// - Parameters:
    ///   - alerts: the alerts of one check, in order
    ///   - memory: what the eggs remember; updated
    ///   - now: the time of the check
    ///   - calendar: the calendar
    ///   - enabled: whether the eggs are on (EGG-01)
    /// - Returns: the alerts, with their egg lines
    public static func annotate(
        _ alerts: [BuildAlert], memory: inout EggMemory, now: Date, calendar: Calendar = .current, enabled: Bool
    ) -> [BuildAlert] {
        var annotated = alerts
        for (index, alert) in alerts.enumerated() where alert.kind == .finished {
            guard let result = alert.build.result, case .finished(_, let duration) = alert.build.phase else {
                continue
            }
            let build = alert.build
            let facts = BuildFacts(build: build, result: result, duration: duration)
            let history = record(facts, in: &memory, now: now, calendar: calendar)
            let earlier = alerts[..<index].filter { $0.kind == .finished }.map(\.build)
            let line = enabled
                ? firstLine(of: facts, history: history, earlier: earlier, memory: &memory, now: now, calendar: calendar)
                : nil
            memory.lastAlertYear = calendar.component(.year, from: now)
            guard enabled else {
                continue
            }
            if let line {
                annotated[index].content.eggLine = line
                annotated[index].content.bannerBody += "\n" + line
            }
            if let hat = hat(memory: memory, now: now, calendar: calendar),
                hat == .santa || alert.content.result == .success
            {
                annotated[index].content.hat = hat
            }
        }
        return annotated
    }

    /// what the rules read of a finished build
    struct BuildFacts {
        var build: Build
        var result: BuildResult
        var duration: TimeInterval

        var isRed: Bool { result == .failure || result == .unstable }
        var isSuccess: Bool { result == .success }
        var isMergeRequest: Bool { build.mergeRequestIID != nil }
    }

    /// what ``record(_:in:now:calendar:)`` found out about the job and the streak
    struct History {
        /// the job's red builds in a row before this build
        var redRunBefore: Int
        /// the job's red builds in a row including this build
        var redRun: Int
        /// whether this build started the green streak
        var startedStreak: Bool
    }

    /// Notes a finished build in the memory: the job's red run and the day's green count.
    private static func record(_ facts: BuildFacts, in memory: inout EggMemory, now: Date, calendar: Calendar) -> History {
        let job = facts.build.job
        let before = memory.redRuns[job] ?? 0
        var run = before
        if facts.isRed {
            run += 1
        } else if facts.isSuccess {
            run = 0
        }
        memory.redRuns[job] = run > 0 ? run : nil

        let today = EggMemory.dayKey(now, calendar)
        if memory.greenDay != today {
            memory.greenDay = today
            memory.greensToday = 0
            memory.redToday = false
        }
        var started = false
        if facts.isRed {
            memory.redToday = true
            memory.partyHat = false
        } else if facts.isSuccess {
            memory.greensToday += 1
            if !memory.redToday, memory.greensToday >= 3, !memory.partyHat {
                memory.partyHat = true
                started = true
            }
        }
        return History(redRunBefore: before, redRun: run, startedStreak: started)
    }

    private static func firstLine(
        of facts: BuildFacts, history: History, earlier: [Build], memory: inout EggMemory, now: Date, calendar: Calendar
    ) -> String? {
        buildNumberLine(facts) ?? historyLine(facts, history) ?? factsLine(facts) ?? jinxLine(facts, earlier)
            ?? clockLine(now: now, memory: &memory, calendar: calendar)
            ?? calendarLine(facts, now: now, memory: &memory, calendar: calendar)
    }

    // MARK: - 1. The build's number

    private static func buildNumberLine(_ facts: BuildFacts) -> String? {
        let number = facts.build.number
        switch number {
        case 42: return "Build #42. The answer to everything. The question is still in review."
        case 404:
            return facts.isSuccess ? "Build #404. Found it, surprisingly." : "Build #404: success not found."
        case 1337: return "Build #1337. Very l33t."
        case 314: return "Build #314. π, roughly."
        default: break
        }
        if number % 10000 == 0 {
            return "Build #\(String(number)). The butler has seen things. Some of them were green."
        }
        if number % 1000 == 0 {
            return "Build #\(String(number)). The butler would like a raise."
        }
        return nil
    }

    // MARK: - 2. The job's history

    private static func historyLine(_ facts: BuildFacts, _ history: History) -> String? {
        if facts.isRed {
            switch history.redRun {
            case 3: return "Third failure in a row. The butler is out of tissues."
            case 4: return "Fourth in a row. The butler has moved on to the curtains."
            case 5...: return "Failure #\(String(history.redRun)) in a row. The butler isn't crying. It's the rain."
            default: break
            }
        }
        if !facts.isMergeRequest {
            if facts.isRed {
                return "You come at the king, you best not miss."
            }
            if facts.isSuccess, history.redRunBefore > 0 {
                return "The king stay the king."
            }
        }
        if facts.isMergeRequest {
            if facts.build.number == 1, facts.isSuccess {
                return "First try. Screenshot this, nobody will believe you."
            }
            if facts.build.number == 10 {
                return facts.isSuccess ? "Ten runs. At this point it's a relationship." : "Run #10. The game is the game."
            }
        }
        if history.startedStreak {
            return "Three for three today. The butler put on a party hat."
        }
        return nil
    }

    // MARK: - 3. The build's facts

    private static func factsLine(_ facts: BuildFacts) -> String? {
        if facts.isRed, let counts = facts.build.testCounts {
            if counts.failed == counts.total, counts.total >= 10 {
                return "Sheeeeeeit."
            }
            if counts.failed == 1, counts.total >= 100 {
                return "One test. One. Out of \(String(counts.total))."
            }
        }
        if let estimate = facts.build.estimatedDuration, estimate > 0, facts.duration >= 2 * estimate {
            return "Twice the estimate. Still faster than the spellcheck."
        }
        if facts.result == .failure, facts.duration >= 3 * 3600 {
            return "Deserve got nothin' to do with it."
        }
        return nil
    }

    // MARK: - 4. Jinx

    private static func jinxLine(_ facts: BuildFacts, _ earlier: [Build]) -> String? {
        let jinxed = earlier.contains { $0.kind != facts.build.kind && $0.result == facts.result }
        return jinxed ? "Jinx. You owe each other a coffee." : nil
    }

    // MARK: - 5. The clock

    private static func clockLine(now: Date, memory: inout EggMemory, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let hour = parts.hour ?? 12
        if hour >= 22 || hour < 5 {
            // A night is one night across midnight: the day five hours earlier.
            let night = EggMemory.dayKey(now.addingTimeInterval(-5 * 3600), calendar)
            if memory.shown["late-night"] != night {
                memory.shown["late-night"] = night
                let time = String(format: "%02d:%02d", hour, parts.minute ?? 0)
                return "It's \(time). The build is done; you should be too."
            }
        }
        if calendar.isDateInWeekend(now), once("weekend", now: now, memory: &memory, calendar: calendar) {
            return "A weekend build. The butler is billing overtime."
        }
        return nil
    }

    // MARK: - 6. The calendar

    private static func calendarLine(_ facts: BuildFacts, now: Date, memory: inout EggMemory, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let (month, day) = (parts.month ?? 0, parts.day ?? 0)
        if month == 10, day == 31 {
            return facts.isSuccess ? "Treat." : "Trick."
        }
        if month == 5, day == 25, !facts.isSuccess, once("towel", now: now, memory: &memory, calendar: calendar) {
            return "Don't panic. The butler brought a towel."
        }
        if month == 3, day == 14, once("pi", now: now, memory: &memory, calendar: calendar) {
            return "Happy π Day. Irrational, like this pipeline."
        }
        if let last = memory.lastAlertYear, let year = parts.year, year > last,
            once("new-year", now: now, memory: &memory, calendar: calendar)
        {
            return "First build of the year. No pressure."
        }
        if parts.weekday == 6, day == 13, once("friday-13", now: now, memory: &memory, calendar: calendar) {
            return "Friday the 13th. The tests know."
        }
        if calendar.ordinality(of: .day, in: .year, for: now) == 256,
            once("programmers", now: now, memory: &memory, calendar: calendar)
        {
            return "Day 256 (0x100). Happy Programmers' Day."
        }
        return nil
    }

    /// Returns whether a once-a-day line hasn't shown today, and notes that it does now.
    private static func once(_ key: String, now: Date, memory: inout EggMemory, calendar: Calendar) -> Bool {
        let today = EggMemory.dayKey(now, calendar)
        guard memory.shown[key] != today else {
            return false
        }
        memory.shown[key] = today
        return true
    }
}

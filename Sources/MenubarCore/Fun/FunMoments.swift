import Foundation

/// A moment of a finished build that gets a funny line (`docs/easter-eggs.md`, the fun layer).
enum FunMoment: Equatable {
    /// the first green build after red ones of the job; the number is the red builds before it
    case redemption(Int)
    /// a green streak of 5, 10, 25, 50 or 100 builds in a row
    case streak(Int)
    /// the third failure in a row on the same merge request
    case thirdFailure
    /// a failure on a Friday after 16:00
    case fridayFail
    /// a build that ran for over an hour; the number is its seconds
    case longBuild(Int)
    /// the first build of a Monday
    case mondayFirst

    /// the confetti the moment plays over its alert
    var celebration: FunCelebration? {
        switch self {
        case .redemption: .confetti
        case .streak(let count): count >= 10 ? .confetti : nil
        default: nil
        }
    }
}

/// The rules that find the moments of a finished build, in the order they win: redemption, a streak, the third failure,
/// a Friday failure, a long build, Monday's first build. Pure: the time and the calendar come in.
enum FunMoments {
    /// the streaks that get a line
    static let streakMilestones: Set<Int> = [5, 10, 25, 50, 100]
    /// a build that ran this long is a long one: one hour
    static let longBuildSeconds: TimeInterval = 3600

    /// Finds the moment of a finished build.
    ///
    /// - Parameters:
    ///   - facts: what the build was
    ///   - history: the job's red run
    ///   - streak: the green streak after this build
    ///   - now: the time
    ///   - calendar: the calendar
    ///   - fun: the store, which keeps the once-a-day marks of the Friday and Monday moments
    static func detect(
        _ facts: EggRules.BuildFacts, history: EggRules.History, streak: Int, now: Date, calendar: Calendar, fun: FunStore
    ) -> FunMoment? {
        if facts.isSuccess, history.redRunBefore > 0 {
            return .redemption(history.redRunBefore)
        }
        if facts.isSuccess, streakMilestones.contains(streak) {
            return .streak(streak)
        }
        if facts.isRed, history.redRun == 3 {
            return .thirdFailure
        }
        let parts = calendar.dateComponents([.weekday, .hour], from: now)
        if facts.isRed, parts.weekday == 6, (parts.hour ?? 0) >= 16, fun.mark("friday-fail", now: now) {
            return .fridayFail
        }
        if facts.duration >= longBuildSeconds {
            return .longBuild(Int(facts.duration))
        }
        if parts.weekday == 2, fun.mark("monday-first", now: now) {
            return .mondayFirst
        }
        return nil
    }

    /// Returns the line of a moment, drawn from Haiku's pool or the built-in lines.
    ///
    /// - Parameters:
    ///   - moment: the moment
    ///   - build: the build, whose number picks among equal built-in lines
    ///   - fun: the store the line is drawn from
    ///   - now: the time
    static func line(_ moment: FunMoment, build: Build, fun: FunStore, now: Date) -> String {
        switch moment {
        case .redemption:
            return fun.draw(.redemption, now: now, seed: build.number)
        case .streak(let count):
            return "🔥 \(count) green in a row. " + fun.draw(.streak, now: now, seed: build.number)
        case .thirdFailure:
            return fun.draw(.thirdFailure, now: now, seed: build.number)
        case .fridayFail:
            return fun.draw(.fridayFail, now: now, seed: build.number)
        case .longBuild(let seconds):
            return fun.draw(.longBuild, now: now, seed: build.number, values: ["{d}": AlertContent.durationText(TimeInterval(seconds))])
        case .mondayFirst:
            return fun.draw(.mondayFirst, now: now, seed: build.number)
        }
    }
}

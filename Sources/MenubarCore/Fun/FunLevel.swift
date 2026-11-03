import Foundation

/// How much fun the app has (Settings → General → Fun level), under the "Easter eggs" switch.
///
/// - ``subtle``: only the rare, hidden eggs of the first catalog.
/// - ``normal``: the moments that react to real events, the butler's tip, the small surprises, the small
///   animations (a bounce, a shake, a little confetti) and Claude Haiku's fresh lines.
/// - ``party`` (the default, the user 2026-11-03): everything of Normal, with the full confetti, the fireworks, the steam, the Inbox Zero butler and the
///   seasonal hats.
public enum FunLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case subtle
    case normal
    case party

    /// the picker's title
    public var title: String {
        switch self {
        case .subtle: "Subtle"
        case .normal: "Normal"
        case .party: "Party"
        }
    }

    /// what the level adds, for the row's caption
    public var detail: String {
        switch self {
        case .subtle: "Only the rare, hidden eggs"
        case .normal: "Moments, tips and small surprises"
        case .party: "Everything, with full confetti and fireworks"
        }
    }

    /// whether the moments, the tip, the surprises and Haiku's lines are on
    public var showsMoments: Bool { self != .subtle }

    /// whether the small animations (bounce, shake, small confetti) play
    public var animates: Bool { self != .subtle }

    /// whether the full confetti, the fireworks, the steam, the Inbox Zero butler and the seasonal hats are on
    public var isParty: Bool { self == .party }
}

/// The kinds of lines the fun layer draws from: each has built-in lines (``FunLines``) and a pool of Haiku's fresh ones.
public enum FunKey: String, Codable, Hashable, Sendable, CaseIterable {
    /// the first green build after red ones
    case redemption
    /// the line after "🔥 10 green in a row"
    case streak
    /// a build that ran over an hour; `{d}` is the duration
    case longBuild
    /// a failure on a Friday after 16:00
    case fridayFail
    /// the first build of a Monday
    case mondayFirst
    /// the third failure in a row on one merge request
    case thirdFailure
    /// a merge request merged from the app
    case merged
    /// the Inbox's empty state
    case inboxZero
    /// a remark about the builds the butler saw; `{builds}`, `{greens}` and `{days}` are the counters
    case funFact
    /// the butler's tip of the day
    case tip
    /// the secret line after catching the peeking butler
    case caught
    /// the lunch line at noon
    case lunch
    /// the line at 17:30 on a weekday
    case goHome
    /// the Friday 16:00 warning
    case noDeploys
    /// the yawn after 22:00; `{time}` is the time
    case midnightOil
    /// a random joke for the pane's footer
    case joke
    /// a running build's birthday; `{h}` is the hours it has run
    case birthday
    /// the app's anniversary; `{y}` is the years
    case anniversary

    /// what the key is for, for Haiku's batch prompt: the moment, never anything of the user's
    public var promptHint: String {
        switch self {
        case .redemption: "a build is green again after red ones"
        case .streak: "a kicker after the words \"N green builds in a row\" (do not write the number)"
        case .longBuild: "a build that ran for over an hour; you may write {d} where its duration goes"
        case .fridayFail: "a build failed on a Friday afternoon"
        case .mondayFirst: "the first build of a Monday morning"
        case .thirdFailure: "the third failed build in a row on the same merge request"
        case .merged: "a merge request was just merged"
        case .inboxZero: "the inbox is empty, nothing needs the developer"
        case .funFact: "a remark about how many builds the butler has watched (do not write a number)"
        case .tip: "a one-line tip or joke of the day for software developers (do not name features of any app)"
        case .caught: "someone caught the butler peeking out of the screen's edge"
        case .lunch: "it is lunch time"
        case .goHome: "it is time to go home on a weekday evening"
        case .noDeploys: "a gentle warning not to deploy on a Friday afternoon"
        case .midnightOil: "the developer is still working late at night; you may write {time} for the time"
        case .joke: "a random one-liner joke about builds, tests or merge requests"
        case .birthday: "a running build has been running for hours; you may write {h} for the hours"
        case .anniversary: "the app's anniversary; you may write {y} for the years"
        }
    }

    /// the tokens a line of this key may hold; any other digit or brace makes Haiku's line unusable
    public var tokens: [String] {
        switch self {
        case .longBuild: ["{d}"]
        case .funFact: ["{builds}", "{greens}", "{days}"]
        case .midnightOil: ["{time}"]
        case .birthday: ["{h}"]
        case .anniversary: ["{y}"]
        default: []
        }
    }
}

/// What a celebration in the alert panel is: confetti, or fireworks on New Year and the app's anniversary.
public enum FunCelebration: String, Codable, Hashable, Sendable {
    case confetti
    case fireworks
}

/// The sad twin of the celebration: the weather over a failed build's butler (`docs/easter-eggs.md`, the fun layer). Never
/// for a green build, an aborted one or the coffee panel.
public enum SadWeather: String, Codable, Hashable, Sendable {
    /// an unstable build: a few drops from a small grey cloud
    case drizzle
    /// a failed build: a small grey cloud and about two seconds of light rain
    case rain
    /// at Party, the third failure in a row or a failure on a Friday after 16:00: a dark cloud, heavy rain and a flash or two
    case storm
}

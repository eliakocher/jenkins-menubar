import Foundation

/// The rules of the easter eggs that aren't alert lines (`docs/easter-eggs.md`): which search words, watch texts, diff
/// stats and dates get a line, and the copy of each. Pure: the time and the calendar come in, so each rule has a test.
///
/// Every egg adds a line; none replaces a fact, makes a sound or takes the focus.
public enum EggRules {
    // MARK: - The hats

    /// Returns the hat the butler wears now.
    ///
    /// - Parameters:
    ///   - memory: what the eggs remember
    ///   - now: the time
    ///   - calendar: the calendar, which says what the local date is
    /// - Returns: the Santa hat all of December, which wins over the party hat; the party hat from the third green
    ///   build of a day until the next red one; otherwise `nil`
    public static func hat(memory: EggMemory, now: Date, calendar: Calendar = .current) -> ButlerHat? {
        let parts = calendar.dateComponents([.month], from: now)
        if parts.month == 12 {
            return .santa
        }
        return memory.partyHat ? .party : nil
    }

    // MARK: - The search

    /// What a search text asks of the eggs.
    public enum SearchMatch: Hashable, Sendable {
        /// a note that needs nothing else: sudo, xyzzy, works on my machine, rm -rf
        case note(String)
        /// coffee, which reads the ETA of the running builds
        case coffee
        /// spellcheck, which counts the demos
        case spellcheck
        /// a known typo, with the word it means
        case typo(String)
    }

    /// the typos the search corrects, by what was typed
    static let typos: [String: String] = [
        "jenkis": "jenkins", "jekins": "jenkins", "jnekins": "jenkins", "jenkisn": "jenkins",
        "gitlba": "gitlab", "gtilab": "gitlab", "gitlav": "gitlab",
        "pipline": "pipeline", "pipeine": "pipeline", "piepline": "pipeline",
        "mrege": "merge request", "merg request": "merge request", "merge reqeust": "merge request",
        "buidl": "build", "biuld": "build",
        "spellckeck": "spellcheck", "spelcheck": "spellcheck", "spellchek": "spellcheck", "speelcheck": "spellcheck",
    ]

    /// Returns what a search text asks of the eggs.
    ///
    /// - Parameter query: the search text; trimmed and compared without case
    /// - Returns: the match, or `nil` for any other text
    public static func searchMatch(_ query: String) -> SearchMatch? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "sudo" || text.hasPrefix("sudo ") {
            return .note("Nice try.")
        }
        if text.hasPrefix("rm -rf") {
            return .note("Not today.")
        }
        switch text {
        case "xyzzy": return .note("Nothing happens.")
        case "works on my machine": return .note("Then we'll ship your machine.")
        case "coffee": return .coffee
        case "spellcheck", "spell check", "spell-check": return .spellcheck
        default: return typos[text].map(SearchMatch.typo)
        }
    }

    /// Returns the note for "coffee", which reads the real ETA of my running builds.
    ///
    /// - Parameters:
    ///   - running: my running builds
    ///   - now: the time
    /// - Returns: the shortest ETA in PIPE-02's format; the past-estimate note when every build with an estimate is past
    ///   it; the nothing-is-running note without a running build
    public static func coffeeNote(running: [Build], now: Date) -> String {
        let running = running.filter(\.isRunning)
        guard !running.isEmpty else {
            return "Nothing is running. Go anyway."
        }
        let remaining = running.compactMap { $0.remaining(at: now) }
        guard !remaining.isEmpty else {
            return "Your build is still running. Go anyway."
        }
        guard let shortest = remaining.filter({ $0 > 0 }).min() else {
            return "Your build is past its estimate. Go anyway."
        }
        return "Your build has ~\(AlertContent.durationText(shortest)) left. Go."
    }

    /// Returns the note of the spellcheck demo counter.
    ///
    /// - Parameter count: which demo this is, 1 or more
    public static func spellcheckNote(count: Int) -> String {
        switch count {
        case 1: "Spellcheck demo #1. Exciting times."
        case 10: "Spellcheck demo #10. The butler knows the slides by heart."
        case 25: "Spellcheck demo #25. The butler presents it now."
        case 50: "Spellcheck demo #50. Sheeeeeeit."
        default: "Spellcheck demo #\(String(count)). Same slides, new font."
        }
    }

    /// Returns the note under the system's "Check the spelling or try a new search." for a known typo.
    ///
    /// - Parameter suggestion: the word the typo means
    public static func typoNote(suggestion: String) -> String {
        "Did you mean “\(suggestion)”? Autocorrect is still in its demo phase."
    }

    // MARK: - Watch a Build…

    /// Returns the line under the outcome of a successful watch.
    ///
    /// - Parameters:
    ///   - now: the time
    ///   - calendar: the calendar
    /// - Returns: the line on a Friday from 16:00; `nil` otherwise
    public static func fridayDeploy(now: Date, calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.weekday, .hour], from: now)
        guard parts.weekday == 6, let hour = parts.hour, hour >= 16 else {
            return nil
        }
        return "Deploying on a Friday? Bold."
    }

    /// Returns the line after the refusal of a text that isn't a build.
    ///
    /// - Parameter text: the text typed into the Watch a Build… sheet
    /// - Returns: the line for paint, grass and the spellcheck; `nil` for any other text
    public static func watchRefusal(_ text: String) -> String? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "paint dry", "paint drying": "Watching paint dry is not supported. Yet."
        case "grass grow", "grass growing": "Watching grass grow is not supported. Yet."
        case "spellcheck", "the spellcheck", "spell check", "autocorrect":
            "Watching the spellcheck? Bring snacks. It takes a while."
        default: nil
        }
    }

    // MARK: - The details

    /// Returns the line under a merge request's diff stats.
    ///
    /// - Parameter stats: the diff stats; the first rule that matches wins
    public static func diffLine(_ stats: MergeRequest.DiffStats?) -> String? {
        guard let stats else {
            return nil
        }
        if stats.fileCount >= 100 {
            return "That's not an MR, that's a migration."
        }
        if stats.fileCount == 1, stats.additions == 1, stats.deletions == 1 {
            return "One-line change. Famous last words."
        }
        if stats.deletions >= 500, stats.additions * 10 <= stats.deletions {
            return "Net negative code. The butler bows."
        }
        return nil
    }

    /// Returns the line under a work item's last update on its birthday.
    ///
    /// - Parameters:
    ///   - reference: the item's short reference, like `#31`, `&12` or `web#34`
    ///   - updatedAt: the last update
    ///   - now: the time
    ///   - calendar: the calendar
    /// - Returns: the line when the last update was a whole number of years ago, on today's month and day; a February 29
    ///   counts on February 28 in other years
    public static func birthday(reference: String, updatedAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        let then = calendar.dateComponents([.year, .month, .day], from: updatedAt)
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let thenYear = then.year, let year = today.year, year > thenYear else {
            return nil
        }
        var sameDay = then.month == today.month && then.day == today.day
        if !sameDay, then.month == 2, then.day == 29, today.month == 2, today.day == 28,
            calendar.range(of: .day, in: .month, for: now)?.count == 28
        {
            sameDay = true
        }
        guard sameDay else {
            return nil
        }
        let years = year - thenYear
        let span = years == 1 ? "a year" : "\(String(years)) years"
        return "Untouched for \(span) today. Happy birthday, \(reference). 🎂"
    }

    // MARK: - Words around the app

    /// the welcome flow's last step
    public static let welcomeLine = "The butler will take it from here."

    /// the sentence the import's Activity entry ends with, when something moved
    public static let importLine = "The butler carried the boxes."

    /// the Quit row's title while Option is held
    public static let optionQuit = "Give the Butler the Evening Off"

    /// the line that replaces Check Now's "Last checked" while it is mashed
    public static let checkNowMashing = "Checking harder won't make it faster."

    /// The butler's CC BY-SA credit, which stays when the eggs are off: it is owed anyway.
    public static let attribution =
        "The butler is the Jenkins logo by Charles Lowell and Frontside (jenkins.io), licensed under CC BY-SA 3.0. "
        + "The butler images keep that license."

    /// Returns the About panel's credits.
    ///
    /// - Parameter eggs: whether the easter eggs are on
    /// - Returns: the roll and the attribution; the attribution alone with the eggs off
    public static func credits(eggs: Bool) -> String {
        guard eggs else {
            return attribution
        }
        return [
            "Directed by the butler",
            "Flaky tests as themselves",
            "The VPN as the VPN",
            "\"Works on my machine\" as the machine",
            "Catering: the coffee machine",
            "Spellcheck: coming in the next demo",
            "",
            attribution,
        ].joined(separator: "\n")
    }
}

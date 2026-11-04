import Foundation

/// The live sentence at the top of Settings → Notifications: what the current choices do for the finished builds, in
/// plain words (the user, 2026-11-03: "i don't know what controls what, and when i get which banner").
///
/// Three sentences at most: my build failing, my build succeeding, the builds I watch. Every choice but Off waits in the
/// Inbox, which the words say.
public enum NotificationSummary {
    /// Returns the summary of the builds' rows.
    ///
    /// - Parameter rules: the table of Settings → Notifications
    /// - Returns: the sentences, like "When your Jenkins build fails: a pop-up with a sound, and it waits in the Inbox until you
    ///   mark it done. When it succeeds: a pop-up with a sound, and it waits in the Inbox. Jenkins builds you only watch: a banner when
    ///   they finish; both wait in the Inbox."
    public static func text(for rules: InboxNotificationRules) -> String {
        let failed = rules.delivery(for: .buildFailed)
        let succeeded = rules.delivery(for: .buildSucceeded)
        let watchedFailed = rules.delivery(for: .watchedBuildFailed)
        let watchedSucceeded = rules.delivery(for: .watchedBuildSucceeded)
        return [
            "When your Jenkins build fails: \(mine(failed, untilDone: true)).",
            "When it succeeds: \(mine(succeeded, untilDone: false)).",
            watched(failed: watchedFailed, succeeded: watchedSucceeded),
        ].joined(separator: " ")
    }

    /// what my build's choice does, in a few words
    private static func mine(_ choice: InboxDelivery, untilDone: Bool) -> String {
        let wait = untilDone ? "it waits in the Inbox until you mark it done" : "it waits in the Inbox"
        switch choice {
        case .popUp: return "a pop-up with a sound, and \(wait)"
        case .banner: return "a banner with a sound, and \(wait)"
        case .inbox: return "no pop-up, no sound; \(wait)"
        case .off: return "nothing"
        }
    }

    /// the sentence of the watched builds
    private static func watched(failed: InboxDelivery, succeeded: InboxDelivery) -> String {
        if failed == .off, succeeded == .off {
            return "Jenkins builds you only watch: nothing."
        }
        let ending = failed != .off && succeeded != .off ? "; both wait in the Inbox" : "; it waits in the Inbox"
        if failed == succeeded {
            return "Jenkins builds you only watch: \(short(failed)) when they finish\(ending)."
        }
        return "Jenkins builds you only watch: \(short(failed)) when they fail, \(short(succeeded)) when they succeed\(ending)."
    }

    private static func short(_ choice: InboxDelivery) -> String {
        switch choice {
        case .popUp: "a pop-up"
        case .banner: "a banner"
        case .inbox: "only an Inbox entry"
        case .off: "nothing"
        }
    }
}

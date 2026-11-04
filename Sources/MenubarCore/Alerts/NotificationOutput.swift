import Foundation

/// What one event does: the rule table of Settings → Notifications as plain values (ALERT-03, ALERT-10).
///
/// A choice (``InboxDelivery``) says it all: Pop-up shows the app's window, Banner posts macOS's banner, both with a
/// sound for a finished build, and both leave an entry in the Inbox; Inbox is the entry alone; Off is nothing.
public struct NotificationOutput: Equatable, Sendable {
    /// the app's window in the middle of the screen
    public var popUp: Bool
    /// macOS's notification banner
    public var banner: Bool
    /// the result's sound; only a finished build has one
    public var sound: Bool
    /// an entry in the Inbox
    public var inboxEntry: Bool

    public init(popUp: Bool = false, banner: Bool = false, sound: Bool = false, inboxEntry: Bool = false) {
        self.popUp = popUp
        self.banner = banner
        self.sound = sound
        self.inboxEntry = inboxEntry
    }

    /// no pop-up, no banner, no sound and no entry
    public static let nothing = NotificationOutput()

    /// Returns what a choice does.
    ///
    /// - Parameters:
    ///   - choice: the row's choice
    ///   - isBuild: whether the event is a finished build, which plays a sound with a pop-up or a banner
    public init(_ choice: InboxDelivery, isBuild: Bool = false) {
        switch choice {
        case .popUp: self = NotificationOutput(popUp: true, sound: isBuild, inboxEntry: true)
        case .banner: self = NotificationOutput(banner: true, sound: isBuild, inboxEntry: true)
        case .inbox: self = NotificationOutput(inboxEntry: true)
        case .off: self = NotificationOutput()
        }
    }
}

extension InboxNotificationRules {
    /// Returns the kind of the row a finished build follows: my build or a watched one, failed (or unstable) or
    /// succeeded.
    ///
    /// - Parameters:
    ///   - ownership: whose build it is
    ///   - result: how it ended
    /// - Returns: the kind; `nil` for an aborted build and any other result, which alert nothing
    public static func buildKind(ownership: AlertContent.Ownership, result: AlertContent.ResultKind) -> InboxEventKind? {
        switch (ownership, result) {
        case (.mine, .failure), (.mine, .unstable): .buildFailed
        case (.mine, .success): .buildSucceeded
        case (.watched, .failure), (.watched, .unstable): .watchedBuildFailed
        case (.watched, .success): .watchedBuildSucceeded
        case (_, .aborted), (_, .other): nil
        }
    }

    /// Returns what a kind does.
    ///
    /// - Parameter kind: the kind
    public func output(for kind: InboxEventKind) -> NotificationOutput {
        NotificationOutput(delivery(for: kind), isBuild: kind.isFinishedBuild)
    }

    /// Returns what a finished build's alert does.
    ///
    /// - A job set to Never does nothing, not even an Inbox entry. A job set to Always follows my build's rows, whoever's
    ///   it is.
    /// - An aborted build and any other result do nothing.
    ///
    /// - Parameters:
    ///   - alert: the alert of the finished build
    ///   - jobSetting: the job's own setting
    public func output(for alert: BuildAlert, jobSetting: NotificationPolicy.JobSetting?) -> NotificationOutput {
        guard let kind = Self.buildKind(for: alert, jobSetting: jobSetting) else {
            return .nothing
        }
        return output(for: kind)
    }

    /// Returns the kind of the row a build's alert follows, with the job's own setting applied.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - jobSetting: the job's own setting
    /// - Returns: the kind; `nil` when the alert does nothing: a job set to Never, an aborted or other result
    public static func buildKind(for alert: BuildAlert, jobSetting: NotificationPolicy.JobSetting?) -> InboxEventKind? {
        if jobSetting == .never {
            return nil
        }
        let ownership = jobSetting == .always ? AlertContent.Ownership.mine : alert.content.ownership ?? .mine
        return buildKind(ownership: ownership, result: alert.content.result)
    }
}

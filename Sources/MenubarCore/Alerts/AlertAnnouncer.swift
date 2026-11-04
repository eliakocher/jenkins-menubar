import Foundation

/// Hands the alerts to the ``Effects`` as the table of Settings → Notifications says, and logs them.
///
/// - A finished build follows the row of its kind (``InboxNotificationRules/output(for:jobSetting:muted:)``): Pop-up plays
///   the sound and shows the alert window, Banner plays the sound and posts macOS's banner, Inbox and Off show nothing
///   (ALERT-03, ALERT-10). It is never both. When a banner of one of my builds can't show because notifications aren't
///   allowed, the alert window shows instead; a watched build's banner stays quiet then.
/// - Aborted builds and other results alert nothing.
/// - A preview shows like a finished build of mine, and is logged as a preview, not as an alert (ALERT-07).
///
/// The Inbox entry of a finished build isn't made here: ``AppModel`` adds it from the same rule.
public struct AlertAnnouncer: Sendable {
    private let effects: any Effects
    private let log: ActivityLog

    public init(effects: any Effects, log: ActivityLog) {
        self.effects = effects
        self.log = log
    }

    /// Announces the alerts of a check, in order.
    ///
    /// - Parameters:
    ///   - alerts: the alerts, from ``AlertPolicy``
    ///   - rules: the table of Settings → Notifications
    ///   - policy: the jobs with a setting of their own
    public func announce(
        _ alerts: [BuildAlert], rules: InboxNotificationRules, policy: NotificationPolicy = NotificationPolicy()
    ) async {
        for alert in alerts {
            await announce(alert, rules: rules, policy: policy)
        }
    }

    /// Announces one alert.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - rules: the table of Settings → Notifications
    ///   - policy: the jobs with a setting of their own
    public func announce(
        _ alert: BuildAlert, rules: InboxNotificationRules, policy: NotificationPolicy = NotificationPolicy()
    ) async {
        let setting = alert.kind == .preview ? nil : policy.jobs[alert.build.jobKey]
        let output = rules.output(for: alert, jobSetting: setting)
        let shownAs = await show(alert, output, asMine: Self.followsMyRows(alert, setting))
        guard alert.kind == .finished else {
            return
        }
        let build = alert.build
        await log.log(.info, .jenkins, "\(build.id.label) finished", detail: build.title, outcome: alert.outcome)
        await log.log(
            .info, .alerts, "\(alert.content.headline) (\(shownAs))", detail: alert.content.bannerBodyWithoutEggLine,
            outcome: alert.outcome)
    }

    /// Logs the finished builds of jobs set to Never, without showing anything (ALERT-09): they leave no Inbox entry
    /// either, but Activity still says the build finished.
    ///
    /// - Parameter alerts: the alerts of the jobs set to Never
    public func logMuted(_ alerts: [BuildAlert]) async {
        for alert in alerts where alert.kind == .finished {
            let build = alert.build
            await log.log(.info, .jenkins, "\(build.id.label) finished", detail: build.title, outcome: alert.outcome)
            await log.log(
                .info, .alerts, "\(alert.content.headline) (muted)", detail: alert.content.bannerBodyWithoutEggLine,
                outcome: alert.outcome)
        }
    }

    /// Shows a sample alert, as my build's rows and the sounds choose (ALERT-07).
    ///
    /// - Parameters:
    ///   - sample: the success or the failure sample
    ///   - team: the team values, for the links
    ///   - rules: the table of Settings → Notifications
    /// - Returns: `false` when there was nothing to show, because the team's Jenkins job URL isn't set
    @discardableResult
    public func preview(_ sample: BuildAlert.PreviewSample, team: TeamValues, rules: InboxNotificationRules) async -> Bool {
        guard let alert = BuildAlert.preview(sample, team: team) else {
            return false
        }
        await log.log(.info, .alerts, "Preview of the \(sample.rawValue) alert")
        await announce(alert, rules: rules)
        return true
    }

    /// whether a build's alert follows my build's rows, so its banner falls back to the window
    private static func followsMyRows(_ alert: BuildAlert, _ setting: NotificationPolicy.JobSetting?) -> Bool {
        setting == .always || !alert.content.isWatched
    }

    /// Plays the sound, then shows the window or the banner.
    ///
    /// - Returns: how it was shown, as the log says it: `alert`, `banner`, `alert, notifications are off`,
    ///   `banner, notifications are off`, `inbox only` or `no alert`
    private func show(_ alert: BuildAlert, _ output: NotificationOutput, asMine: Bool) async -> String {
        if output.sound {
            await effects.playSound(alert.content.sound)
        }
        if output.popUp {
            await effects.showAlertWindow(alert)
            return "alert"
        }
        if output.banner {
            if await effects.postBanner(alert) {
                return "banner"
            }
            guard asMine else {
                return "banner, notifications are off"
            }
            await effects.showAlertWindow(alert)
            return "alert, notifications are off"
        }
        return output.inboxEntry ? "inbox only" : "no alert"
    }
}

import Foundation

/// Hands the alerts to the ``Effects`` as the preferences say, and logs them.
///
/// - A finished build plays its sound, then shows the alert window or a banner, never both (ALERT-03). When the style
///   is banner but notifications aren't allowed, the alert window shows instead.
/// - A stage banner is always a banner, with the Basso sound (ALERT-05).
/// - A preview shows like a finished build, and is logged as a preview, not as an alert (ALERT-07).
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
    ///   - preferences: the alert style and stage alerts
    public func announce(_ alerts: [BuildAlert], preferences: Preferences) async {
        for alert in alerts {
            await announce(alert, preferences: preferences)
        }
    }

    /// Announces one alert.
    ///
    /// - Parameters:
    ///   - alert: the alert
    ///   - preferences: the alert style and stage alerts
    public func announce(_ alert: BuildAlert, preferences: Preferences) async {
        switch alert.kind {
        case .finished, .preview:
            let shownAs = await show(alert, preferences: preferences)
            guard alert.kind == .finished else {
                return
            }
            let build = alert.build
            await log.log(.info, .jenkins, "\(build.id.label) finished", detail: build.title, outcome: alert.outcome)
            await log.log(
                .info, .alerts, "\(alert.content.headline) (\(shownAs))", detail: alert.content.bannerBodyWithoutEggLine,
                outcome: alert.outcome)
        case .stageFailed:
            guard preferences.stageAlerts else {
                return
            }
            await effects.playSound(alert.content.sound)
            let posted = await effects.postBanner(alert)
            let stages = alert.build.failedStages?.joined(separator: ", ") ?? ""
            await log.log(
                .info, .alerts, "Banner: \(alert.build.id.label) stage failed: \(stages)\(posted ? "" : " (notifications are off)")",
                detail: alert.build.title, outcome: alert.outcome)
        }
    }

    /// Shows a sample alert, as the current style and sound settings choose (ALERT-07).
    ///
    /// - Parameters:
    ///   - sample: the success or the failure sample
    ///   - team: the team values, for the links
    ///   - preferences: the alert style
    /// - Returns: `false` when there was nothing to show, because the team's Jenkins job URL isn't set
    @discardableResult
    public func preview(_ sample: BuildAlert.PreviewSample, team: TeamValues, preferences: Preferences) async -> Bool {
        guard let alert = BuildAlert.preview(sample, team: team) else {
            return false
        }
        await log.log(.info, .alerts, "Preview of the \(sample.rawValue) alert")
        await announce(alert, preferences: preferences)
        return true
    }

    /// Plays the sound, then shows the window or the banner.
    ///
    /// - Returns: how it was shown, as the log says it: `alert`, `banner`, or `alert, notifications are off`
    private func show(_ alert: BuildAlert, preferences: Preferences) async -> String {
        await effects.playSound(alert.content.sound)
        let shownAs: String
        switch preferences.alertStyle {
        case .window:
            await effects.showAlertWindow(alert)
            shownAs = "alert"
        case .banner:
            if await effects.postBanner(alert) {
                shownAs = "banner"
            } else {
                await effects.showAlertWindow(alert)
                shownAs = "alert, notifications are off"
            }
        }
        return shownAs
    }
}

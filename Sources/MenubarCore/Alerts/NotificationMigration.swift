import Foundation

/// The one-time move from the notification settings of before the single table (Task 7.14) to the table of Settings →
/// Notifications. The old keys stay readable and untouched; nothing deletes them.
///
/// - The old build alert style, `alertStyle`: `window` → my failed build is a Pop-up and my succeeded one too; `banner` →
///   Banner for both; `inboxOnly` → Inbox for the failed one, Off for the succeeded one.
/// - The watched rows get their new defaults (Banner), unless the old Watching switch was off: then both are Off. The
///   old My Builds switch off turns my two rows Off.
/// - A kind whose Inbox toggle was off and whose delivery was Inbox Only is Off now. One that popped up keeps its pop-up
///   (an entry comes with it now): the user asked for the pop-up.
/// - The Inbox bit of the routes goes; the Red Dot (the old badge) stays.
/// - `stageAlerts` is dropped: stage banners are gone. The dead keys (`speaksResult`, the banner sound, quiet hours) were
///   ignored before and are now.
public enum NotificationMigration {
    /// the version of the notification settings this app writes
    public static let version = 1
    /// the UserDefaults key of the version the settings were migrated to; absent before the single table
    public static let versionKey = "notificationsVersion"
    /// the UserDefaults key of the old build alert style
    public static let alertStyleKey = "alertStyle"
    /// the UserDefaults key of the old stage banners switch, which nothing reads any more
    public static let stageAlertsKey = "stageAlerts"

    /// Returns the table after the move.
    ///
    /// - Parameters:
    ///   - rules: the old rules as stored: their overrides still have the Inbox bit, their deliveries are those of the
    ///     other kinds
    ///   - alertStyle: the old build alert style's raw value (`window`, `banner`, `inboxOnly`); `nil` and anything else is
    ///     `window`, the old default
    ///   - mine: the old My Builds switch
    ///   - watching: the old Watching switch
    /// - Returns: the new rules
    public static func migrated(
        rules: InboxNotificationRules, alertStyle: String?, mine: Bool = true, watching: Bool = true
    ) -> InboxNotificationRules {
        var builds: [InboxEventKind: InboxDelivery] = [:]
        switch alertStyle {
        case "banner":
            builds[.buildFailed] = InboxDelivery.banner
            builds[.buildSucceeded] = InboxDelivery.banner
        case "inboxOnly":
            builds[.buildFailed] = InboxDelivery.inbox
            builds[.buildSucceeded] = InboxDelivery.off
        default:
            builds[.buildFailed] = InboxDelivery.popUp
            builds[.buildSucceeded] = InboxDelivery.popUp
        }
        if !mine {
            builds[.buildFailed] = .off
            builds[.buildSucceeded] = .off
        }
        let watched: InboxDelivery = watching ? .banner : .off
        builds[.watchedBuildFailed] = watched
        builds[.watchedBuildSucceeded] = watched

        var result = rules
        result.overrides = [:]
        result.deliveries = [:]
        for kind in InboxNotificationRules.deliveryKinds {
            let legacy = rules.deliveries[kind.rawValue]
            var delivery = builds[kind] ?? legacy ?? kind.defaultDelivery
            // The old Inbox toggle was off and nothing announced the event: nothing is what the user chose.
            let inboxWasOff = rules.overrides[kind.rawValue].map { !$0.contains(.inbox) } ?? false
            if inboxWasOff, delivery == .inbox {
                delivery = .off
            }
            result.set(delivery, for: kind)
        }
        for (key, routes) in rules.overrides {
            if let kind = InboxEventKind(rawValue: key) {
                result.setRoutes(routes.contains(.badge) ? [.badge] : [], for: kind)
            }
        }
        return result
    }

    /// Reads the two switches of an old notification policy, stored as JSON text.
    ///
    /// - Parameter text: the stored text; `nil` or text that doesn't decode is the old default, both on
    /// - Returns: the My Builds and the Watching switches
    public static func groupSwitches(inPolicyText text: String?) -> (mine: Bool, watching: Bool) {
        guard let text, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return (true, true)
        }
        return (object["mine"] as? Bool ?? true, object["watching"] as? Bool ?? true)
    }
}

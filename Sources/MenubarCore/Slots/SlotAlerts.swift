import Foundation

/// A quiet notice about a slot: a banner without a sound (SLOT-04).
public struct SlotNotice: Hashable, Sendable {
    /// the slot, which is also what the notice is remembered by
    public var slot: SlotName
    /// like "Code freeze in 3 days"
    public var title: String
    /// like "Slot 2026.51"
    public var subtitle: String
    /// like "6 committed items have no merged MR"
    public var body: String
    /// what a click opens: the main window at Slots
    public var url: URL

    public init(slot: SlotName, title: String, subtitle: String, body: String, url: URL) {
        self.slot = slot
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.url = url
    }
}

/// The slot alert (SLOT-04): "Code freeze in 3 days: 6 committed items have no merged MR".
///
/// - It comes once per slot, from the warning days before the code freeze (Team, 3 by default) until the freeze, and
///   only while some committed item is open without a merged merge request.
/// - It waits until GitLab has answered for the merge requests of every open item, so a missing answer never sounds
///   like missing work.
/// - The work items are the ones Work Items loads: mine, by the filter's scope. A developer is told about their own
///   items only; a team-wide count would need a wider query.
/// - It never plays a sound.
public enum SlotAlerts {
    /// the UserDefaults key of the slots already announced
    static let announcedKey = "slotAlerts.announced"

    /// Returns the notices to post now.
    ///
    /// - Parameters:
    ///   - plan: the slot plan
    ///   - warnDays: how many days before the code freeze the alert comes
    ///   - announced: the slots announced before
    /// - Returns: at most one notice per slot, in the order of the slots
    public static func notices(of plan: SlotPlan, warnDays: Int, announced: Set<String>) -> [SlotNotice] {
        plan.slots.compactMap { slot in
            let days = slot.daysToCodeFreeze
            guard slot.state != .overdue, (0...warnDays).contains(days), !announced.contains(slot.name.description) else {
                return nil
            }
            let open = slot.openItems.filter { !$0.workItem.isEpic }
            guard open.allSatisfy(\.mergeRequestsLoaded) else { return nil }
            let unmerged = open.count { !$0.hasMergedMergeRequest }
            guard unmerged > 0 else { return nil }
            let when = switch days {
            case 0: "today"
            case 1: "tomorrow"
            default: "in \(days) days"
            }
            return SlotNotice(
                slot: slot.name, title: "Code freeze \(when)", subtitle: "Slot \(slot.name)",
                body: unmerged == 1 ? "1 committed item has no merged MR" : "\(unmerged) committed items have no merged MR",
                url: AppRoute.open(.slots).url)
        }
    }

    /// Posts the notices of a plan that weren't posted before, when Slots' alert is on.
    ///
    /// - Parameters:
    ///   - plan: the slot plan
    ///   - team: the team values, for the warning days
    ///   - preferences: whether the alert is on
    ///   - defaults: where the announced slots are kept
    ///   - effects: shows the banner
    ///   - log: the Activity log
    @MainActor
    public static func announce(
        _ plan: SlotPlan, team: TeamValues, preferences: Preferences, defaults: UserDefaults, effects: any Effects,
        log: ActivityLog
    ) async {
        guard preferences.slotAlerts else { return }
        var announced = Set(defaults.stringArray(forKey: announcedKey) ?? [])
        let warnDays = SlotRules(team: team).warnDays
        for notice in notices(of: plan, warnDays: warnDays, announced: announced) {
            let posted = await effects.postNotice(notice)
            // Remembered even when no banner could show, so a later permission doesn't bring an old warning.
            announced.insert(notice.slot.description)
            defaults.set(announced.sorted(), forKey: announcedKey)
            await log.log(
                .info, .alerts, "\(notice.title): \(notice.body)\(posted ? "" : " (notifications are off)")",
                detail: notice.subtitle)
        }
    }
}

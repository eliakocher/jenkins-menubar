import Foundation
import MenubarCore

/// What the Slots section shows, from the plan and the stores' state (SLOT-02). Pure, so the window, the gallery and the
/// tests get the same answers.
struct SlotsListModel: Hashable, Sendable {
    /// What the section says instead of slots.
    enum Empty: Hashable, Sendable {
        /// the team has no slot label prefix
        case noPrefix
        /// GitLab has no token, so no work item loaded (MR-04)
        case noToken
        /// the work items haven't loaded yet
        case notLoaded
        /// work items loaded, none with a slot label
        case noSlots
        /// the search matches no slot and no item
        case findsNothing(String)
    }

    var slots: [SlotSummary]
    var empty: Empty?
    /// the planning tool's page, for "Open Slot Planning"; `nil` when Team has none
    var planningURL: URL?
    /// the team's project path, for short references
    var project: String
    /// how many work items have no slot label and don't show
    var withoutSlot: Int
    /// why only the slots of the work items and the remembered labels show: GitLab's slot labels didn't load
    var labelsNote: String?
    /// the status label prefix, whose value the rows show
    var statusPrefix: String
    /// how many issues of the slot group loaded; 0 without a slot group
    var groupItems: Int
    /// whether the slot group's issues are loading
    var isLoadingGroup: Bool

    /// - Parameters:
    ///   - plan: the slots
    ///   - team: the team values
    ///   - hasLoaded: whether the work items loaded once
    ///   - needsToken: whether GitLab has no token
    ///   - query: the window's search text
    ///   - labelsProblem: why GitLab's slot labels or the group's issues didn't load; `nil` when they did
    ///   - groupItems: how many issues of the slot group loaded
    ///   - isLoadingGroup: whether they are loading
    init(
        plan: SlotPlan, team: TeamValues, hasLoaded: Bool, needsToken: Bool, query: String, labelsProblem: String? = nil,
        groupItems: Int = 0, isLoadingGroup: Bool = false
    ) {
        labelsNote = labelsProblem
        statusPrefix = team.statusLabelPrefix
        self.groupItems = groupItems
        self.isLoadingGroup = isLoadingGroup
        planningURL = team.slotPlanning
        project = team.gitLabProject
        withoutSlot = plan.withoutSlot
        let text = query.trimmingCharacters(in: .whitespaces)
        slots = text.isEmpty ? plan.slots : plan.slots.compactMap { Self.filtered($0, by: text) }
        if team.slotLabelPrefix.isEmpty {
            empty = .noPrefix
        } else if needsToken {
            empty = .noToken
        } else if !hasLoaded {
            empty = .notLoaded
        } else if plan.slots.isEmpty {
            empty = .noSlots
        } else if slots.isEmpty {
            empty = .findsNothing(text)
        }
    }

    /// Returns the slot with the items that match the text in their title or reference, or the whole slot when its
    /// name matches; `nil` when nothing matches.
    static func filtered(_ slot: SlotSummary, by text: String) -> SlotSummary? {
        if slot.name.description.localizedCaseInsensitiveContains(text) {
            return slot
        }
        var matching = slot
        let matches = { (item: SlotItem) in
            item.workItem.title.localizedCaseInsensitiveContains(text) || item.workItem.reference.localizedCaseInsensitiveContains(text)
                || (item.workItem.epic?.title.localizedCaseInsensitiveContains(text) ?? false)
                || (item.workItem.assignees ?? []).contains { $0.displayName.localizedCaseInsensitiveContains(text) }
        }
        matching.items = slot.items.filter(matches)
        matching.planned = slot.planned.filter(matches)
        return matching.items.isEmpty && matching.planned.isEmpty ? nil : matching
    }
}

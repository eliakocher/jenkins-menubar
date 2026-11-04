import Foundation

/// The chips that are on in the Slots section, combinable as in the team's slot planning web tool (SLOT-07): chips of
/// the same field (status: Triage and Remaining Work; type: Open Bugs; members: Me, the teams, the squads) are
/// alternatives, chips of different fields narrow each other down. No chip on is Everyone, which is a reset, never a
/// member of the set.
public struct SlotChipSelection: Hashable, Sendable {
    /// the chips on; never Everyone
    public private(set) var chips: Set<SlotChip>

    /// - Parameter chips: the chips to turn on; Everyone is ignored
    public init(_ chips: some Sequence<SlotChip> = []) {
        self.chips = Set(chips.filter { $0 != .all })
    }

    /// no chip on
    public static let everyone = SlotChipSelection()

    /// whether nothing filters
    public var isEveryone: Bool { chips.isEmpty }

    /// Returns whether a chip shows as on: Everyone while nothing else is, any other while it is in the set.
    public func isActive(_ chip: SlotChip) -> Bool {
        chip == .all ? isEveryone : chips.contains(chip)
    }

    /// Returns the selection after a click: Everyone clears the others, an active chip goes off, any other comes on.
    public func toggled(_ chip: SlotChip) -> SlotChipSelection {
        if chip == .all { return .everyone }
        var copy = self
        if copy.chips.contains(chip) { copy.chips.remove(chip) } else { copy.chips.insert(chip) }
        return copy
    }

    // MARK: Remembered

    /// the chips' ids as the setting keeps them: sorted, separated by commas (a comma or percent sign in a name is
    /// escaped); `all` for Everyone
    public var id: String {
        guard !chips.isEmpty else { return SlotChip.all.id }
        return chips.map { Self.escape($0.id) }.sorted().joined(separator: ",")
    }

    /// Reads the remembered setting, the old single chip id too. Unknown ids are dropped; an id that names chips but
    /// leaves none is Me, as the single chip always fell back; nothing at all is Everyone.
    ///
    /// - Parameter id: the setting
    public init(id: String) {
        self = Self.restore(id: id, among: nil)
    }

    /// Reads the remembered setting against the chips there are now (SLOT-07): each id as ``SlotChip/restored(id:among:)``
    /// does, except that a chip that is gone is dropped, not Me; when that leaves nothing of a setting that named chips,
    /// it is Me. Nothing remembered, or only Everyone, is Everyone.
    ///
    /// - Parameters:
    ///   - id: the setting
    ///   - chips: the chips there are
    /// - Returns: the selection to show
    public static func restored(id: String, among chips: [SlotChip]) -> SlotChipSelection {
        restore(id: id, among: chips)
    }

    private static func restore(id: String, among chips: [SlotChip]?) -> SlotChipSelection {
        let parts = id.split(separator: ",").map { unescape(String($0)) }.filter { !$0.isEmpty && $0 != SlotChip.all.id }
        guard !parts.isEmpty else { return .everyone }
        let kept = parts.compactMap { part -> SlotChip? in
            guard let chips else { return SlotChip(id: part) }
            return SlotChip.resolve(id: part, among: chips)
        }
        return kept.isEmpty ? SlotChipSelection([.me]) : SlotChipSelection(kept)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ",", with: "%2C")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "%2C", with: ",").replacingOccurrences(of: "%25", with: "%")
    }

    // MARK: Rules

    /// Returns whether a work item shows: for every field with a chip on, one of its chips matches (SLOT-07). Everyone
    /// shows all.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values
    ///   - me: my GitLab username; `nil` when unknown, and then Me matches nothing
    public func matches(_ item: WorkItem, team: TeamValues, me: String?) -> Bool {
        let teams = SlotTeams(team.slotTeams)
        return Self.matches(item, groups: groups, team: team, teams: teams, me: me)
    }

    /// Returns the work items that show: ``matches(_:team:me:)`` for each, with the team value read once and the chips
    /// grouped once, not per item.
    ///
    /// - Parameters:
    ///   - items: the work items
    ///   - team: the team values
    ///   - me: my GitLab username; `nil` when unknown
    /// - Returns: the items that show, in their order
    public func filter(_ items: [WorkItem], team: TeamValues, me: String?) -> [WorkItem] {
        guard !chips.isEmpty else { return items }
        let teams = SlotTeams(team.slotTeams)
        let grouped = groups
        return items.filter { Self.matches($0, groups: grouped, team: team, teams: teams, me: me) }
    }

    /// the chips on, grouped by their field
    private var groups: [[SlotChip]] {
        Array(Dictionary(grouping: chips, by: \.field).values)
    }

    private static func matches(
        _ item: WorkItem, groups: [[SlotChip]], team: TeamValues, teams: SlotTeams?, me: String?
    ) -> Bool {
        groups.allSatisfy { group in group.contains { $0.matches(item, team: team, teams: teams, me: me) } }
    }

    /// Returns what a slot can take under the selection (SLOT-08, SLOT-13). With member chips (Me, teams, squads), the
    /// union of what they have: the person-days of the people of the teams and me, each person once, or the sum of the
    /// squads' points. Status and type chips filter the items, not the capacity. Without member chips it is Everyone's.
    ///
    /// - Parameters:
    ///   - team: the team values
    ///   - squads: the squads there are, for Everyone without teams
    ///   - me: my GitLab username; `nil` when unknown
    /// - Returns: the capacity; `nil` when there is no load to show
    public func capacity(team: TeamValues, squads: [String], me: String?) -> SlotCapacity? {
        let members = chips.filter { $0.field == .members }
        guard !members.isEmpty else { return SlotChip.all.capacity(team: team, squads: squads, me: me) }
        var people: [String] = []
        var seen: Set<String> = []
        var workDays: SlotWorkDays?
        var points: Int?
        for chip in members.sorted(by: { $0.id < $1.id }) {
            switch chip.capacity(team: team, squads: squads, me: me) {
            case .people(let names, let days)?:
                workDays = days
                people += names.filter { seen.insert($0.lowercased()).inserted }
            case .points(let value)?:
                points = (points ?? 0) + value
            case nil:
                break
            }
        }
        if let workDays, !people.isEmpty { return .people(people, workDays: workDays) }
        return points.map(SlotCapacity.points)
    }
}

import Foundation

/// A quick filter of the Slots section, built in for now (SLOT-07): my items, everyone's, one team's (by its members, else
/// one squad's by the squad label), or the three the team's slot planning web tool has.
public enum SlotChip: Hashable, Sendable, Identifiable {
    /// the items assigned to me
    case me
    /// every item of the slot group
    case all
    /// the items with the squad's label, by its value after the squad prefix: the chips when Team names no teams
    case squad(String)
    /// the items assigned to one of the team's members (SLOT-13)
    case team(String)
    /// the items whose status is Triage or MaintainerTriage
    case triage
    /// the items whose status is Todo or InProgress
    case remainingWork
    /// the open items of type Bug
    case openBugs

    public var id: String {
        switch self {
        case .me: "me"
        case .all: "all"
        case .squad(let name): "squad:\(name)"
        case .team(let name): "team:\(name)"
        case .triage: "triage"
        case .remainingWork: "remaining"
        case .openBugs: "bugs"
        }
    }

    /// What a chip filters, as in the team's tool: chips of one field are alternatives, different fields narrow each
    /// other down (SLOT-07).
    public enum Field: Hashable, Sendable {
        /// Triage, Remaining Work
        case status
        /// Open Bugs
        case type
        /// Me, teams, squads: whose items
        case members
    }

    /// the field the chip filters; `nil` for Everyone, which filters nothing
    public var field: Field? {
        switch self {
        case .all: nil
        case .triage, .remainingWork: .status
        case .openBugs: .type
        case .me, .team, .squad: .members
        }
    }

    public var title: String {
        switch self {
        case .me: "Me"
        case .all: "Everyone"
        case .squad(let name), .team(let name): name
        case .triage: "Triage"
        case .remainingWork: "Remaining Work"
        case .openBugs: "Open Bugs"
        }
    }

    /// Reads a chip from its stable id, as ``id`` writes it; `nil` for an id that names no chip.
    ///
    /// - Parameter id: `me`, `all`, `triage`, `remaining`, `bugs`, `team:<name>` or `squad:<name>`
    public init?(id: String) {
        switch id {
        case "me": self = .me
        case "all": self = .all
        case "triage": self = .triage
        case "remaining": self = .remainingWork
        case "bugs": self = .openBugs
        default:
            if id.hasPrefix("team:"), id.count > 5 {
                self = .team(String(id.dropFirst(5)))
            } else if id.hasPrefix("squad:"), id.count > 6 {
                self = .squad(String(id.dropFirst(6)))
            } else {
                return nil
            }
        }
    }

    /// Returns the chip a remembered id stands for among the chips there are now (SLOT-07): the chip itself when it
    /// exists. A squad that has become a team of the same name (Team names teams now) is that team; a team whose
    /// squad label is all there is again is that squad. Anything else, an id that is unknown or whose chip is gone,
    /// is Me.
    ///
    /// - Parameters:
    ///   - id: the remembered id
    ///   - chips: the chips there are
    /// - Returns: the chip to select
    public static func restored(id: String, among chips: [SlotChip]) -> SlotChip {
        resolve(id: id, among: chips) ?? .me
    }

    /// Returns the chip a remembered id stands for as ``restored(id:among:)`` does, but `nil` where that gives Me
    /// because the chip is gone.
    static func resolve(id: String, among chips: [SlotChip]) -> SlotChip? {
        guard let chip = SlotChip(id: id) else { return nil }
        if chips.contains(chip) { return chip }
        let name: String
        switch chip {
        case .squad(let squad): name = squad
        case .team(let team): name = team
        default: return nil
        }
        let sameName = { (other: SlotChip) -> Bool in
            switch other {
            case .team(let candidate), .squad(let candidate): candidate.caseInsensitiveCompare(name) == .orderedSame
            default: false
            }
        }
        // A team is preferred over a squad of the same name: it is the tool's rule.
        return chips.first { if case .team = $0 { sameName($0) } else { false } }
            ?? chips.first { if case .squad = $0 { sameName($0) } else { false } }
    }

    /// Returns the chips in the tool's order, with Everyone, the reset, in front: Everyone, Triage, Remaining Work, Open
    /// Bugs, Me, then one per team (else one per squad) by name.
    ///
    /// - Parameters:
    ///   - squads: the squad names, as ``squads(of:prefix:)`` finds them
    ///   - teams: the team chips' names; `nil` when Team names no teams, and then the squads show. With teams named,
    ///     they replace the squads, also when none has work (empty)
    /// - Returns: the chips
    public static func chips(squads: [String], teams: [String]? = nil) -> [SlotChip] {
        let groups = teams.map { $0.map(SlotChip.team) } ?? squads.map(SlotChip.squad)
        return [.all, .triage, .remainingWork, .openBugs, .me] + groups
    }

    /// Returns the squads of the items: every label value after the squad prefix, sorted, each once.
    ///
    /// - Parameters:
    ///   - items: the work items
    ///   - prefix: the squad label prefix from Team; empty means no squads
    /// - Returns: the squad names
    public static func squads(of items: [WorkItem], prefix: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let names = items.flatMap(\.labels).compactMap { label -> String? in
            guard label.title.hasPrefix(prefix) else { return nil }
            let name = String(label.title.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Returns the teams that get a chip, as the team's tool does (SLOT-13): a team shows only when one of its members
    /// is an assignee of some item, sorted by name.
    ///
    /// - Parameters:
    ///   - teams: the teams and their members from Team
    ///   - items: the loaded work items
    /// - Returns: the team names
    public static func teamsWithWork(_ teams: SlotTeams, items: [WorkItem]) -> [String] {
        let assigned = Set(items.flatMap { ($0.assignees ?? []).map { $0.username.lowercased() } })
        let names = teams.teams.filter { team in team.members.contains { assigned.contains($0.lowercased()) } }.map(\.name)
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Returns the team value that the squad labels suggest, ready to paste into Team: per squad, the assignees of the
    /// items carrying its label. A person is in one team, as in the tool, so each goes to the squad whose items they
    /// have most of (the first by name when equal). Squads whose items have no assignee are left out.
    ///
    /// - Parameters:
    ///   - items: the loaded work items
    ///   - prefix: the squad label prefix from Team; empty gives nothing
    /// - Returns: `Alpha: user1, user2; Bravo: user3`; empty when there is nothing to suggest
    public static func suggestedTeams(of items: [WorkItem], prefix: String) -> String {
        guard !prefix.isEmpty else { return "" }
        var counts: [String: [String: Int]] = [:]  // username → squad → items
        for item in items {
            let squads = Set(item.labels.compactMap { label -> String? in
                guard label.title.hasPrefix(prefix), label.title.count > prefix.count else { return nil }
                return String(label.title.dropFirst(prefix.count))
            })
            for person in item.assignees ?? [] {
                for squad in squads { counts[person.username, default: [:]][squad, default: 0] += 1 }
            }
        }
        var members: [String: [String]] = [:]
        for (username, bySquad) in counts {
            let best = bySquad.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            if let squad = best.first?.key { members[squad, default: []].append(username) }
        }
        return members.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { squad in
            let names = members[squad]!.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return "\(squad): \(names.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    /// Returns whether a work item shows under the chip.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values: the teams and the squad, status and type prefixes
    ///   - me: my GitLab username; `nil` when unknown, and then Me matches nothing
    /// - Returns: whether it matches
    public func matches(_ item: WorkItem, team: TeamValues, me: String?) -> Bool {
        matches(item, team: team, teams: SlotTeams(team.slotTeams), me: me)
    }

    /// Returns whether a work item shows under the chip, with the teams read once for many items: parsing the team value
    /// for every item made the plan slow.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values: the squad, status and type prefixes
    ///   - teams: the teams of Team's value, `SlotTeams(team.slotTeams)`
    ///   - me: my GitLab username; `nil` when unknown, and then Me matches nothing
    /// - Returns: whether it matches
    public func matches(_ item: WorkItem, team: TeamValues, teams: SlotTeams?, me: String?) -> Bool {
        let titles = Set(item.labels.map(\.title))
        let assignees = (item.assignees ?? []).map(\.username)
        let isOpen = item.state != .closed
        let status = team.statusLabelPrefix
        switch self {
        case .me:
            guard let me else { return false }
            return assignees.contains(me)
        case .all:
            return true
        case .squad(let name):
            return !team.squadLabelPrefix.isEmpty && titles.contains(team.squadLabelPrefix + name)
        case .team(let name):
            let members = teams?.members(of: name) ?? []
            return assignees.contains { SlotTeams.contains(members, $0) }
        case .triage:
            return !status.isEmpty && (titles.contains(status + "Triage") || titles.contains(status + "MaintainerTriage"))
        case .remainingWork:
            // The tool's rule: the status alone, whatever the commitment; without a status prefix the open items.
            guard !status.isEmpty else { return isOpen }
            return titles.contains(status + "Todo") || titles.contains(status + "InProgress")
        case .openBugs:
            return isOpen && !team.typeLabelPrefix.isEmpty && titles.contains(team.typeLabelPrefix + "Bug")
        }
    }

    /// Returns what a slot can take under the chip (SLOT-08, SLOT-13). With teams in Team: a team's members, everyone of
    /// every team, or me when I am a member; their work days give the person-days of each slot. Without teams: a squad's
    /// points from the squad capacity, the sum over the squads for Everyone. Triage, Remaining Work and Open Bugs have
    /// none.
    ///
    /// - Parameters:
    ///   - team: the team values: the teams, the work days and the squad capacity
    ///   - squads: the squads there are, for Everyone without teams
    ///   - me: my GitLab username; `nil` when unknown
    /// - Returns: the capacity; `nil` when there is no load to show
    public func capacity(team: TeamValues, squads: [String], me: String?) -> SlotCapacity? {
        if let teams = SlotTeams(team.slotTeams) {
            let workDays = SlotWorkDays(team.slotMemberWorkDays) ?? SlotWorkDays()
            let members: [String]
            switch self {
            case .team(let name): members = teams.members(of: name)
            case .all: members = teams.everyone
            case .me: members = me.map { SlotTeams.contains(teams.everyone, $0) ? [$0] : [] } ?? []
            case .squad, .triage, .remainingWork, .openBugs: members = []
            }
            return members.isEmpty ? nil : .people(members, workDays: workDays)
        }
        guard let capacity = SquadCapacity(team.squadCapacity) else { return nil }
        switch self {
        case .squad(let name):
            return capacity.points(of: name).map(SlotCapacity.points)
        case .all:
            let points = squads.compactMap { capacity.points(of: $0) }
            return points.isEmpty ? nil : .points(points.reduce(0, +))
        case .me, .team, .triage, .remainingWork, .openBugs:
            return nil
        }
    }
}

/// The points each squad takes per slot, from the team value: `Alpha: 60, Delta: 120`, `Alpha=60`, or a bare number
/// for every squad not named (SLOT-08).
public struct SquadCapacity: Hashable, Sendable {
    /// the points of the squads named
    public var bySquad: [String: Int]
    /// the points of every squad not named; `nil` without a bare number
    public var everySquad: Int?

    /// Reads the team value; `nil` when it is empty or a part isn't `name: points` or a number of 0 or more.
    ///
    /// - Parameter text: the value, parts separated by commas or semicolons
    public init?(_ text: String) {
        var bySquad: [String: Int] = [:]
        var everySquad: Int?
        let parts = text.split { $0 == "," || $0 == ";" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for part in parts {
            if let separator = part.lastIndex(where: { $0 == ":" || $0 == "=" }) {
                let name = part[..<separator].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let points = Self.points(part[part.index(after: separator)...]) else { return nil }
                bySquad[name] = points
            } else {
                guard everySquad == nil, let points = Self.points(Substring(part)) else { return nil }
                everySquad = points
            }
        }
        self.bySquad = bySquad
        self.everySquad = everySquad
    }

    /// Returns a squad's points: its own, else the bare number; the name's case doesn't count.
    public func points(of squad: String) -> Int? {
        bySquad[squad] ?? bySquad.first { $0.key.caseInsensitiveCompare(squad) == .orderedSame }?.value ?? everySquad
    }

    private static func points(_ text: Substring) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text) else { return nil }
        return value
    }
}

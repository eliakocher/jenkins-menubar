import Foundation

/// A quick filter of the Slots section, built in for now (SLOT-07): my items, everyone's, one squad's, or the three
/// the team's slot planning web tool has.
public enum SlotChip: Hashable, Sendable, Identifiable {
    /// the items assigned to me
    case me
    /// every item of the slot group
    case all
    /// the items with the squad's label, by its value after the squad prefix
    case squad(String)
    /// the items whose status is Triage or MaintainerTriage
    case triage
    /// the open committed items that aren't Verified
    case remainingWork
    /// the open items of type Bug
    case openBugs

    public var id: String {
        switch self {
        case .me: "me"
        case .all: "all"
        case .squad(let name): "squad:\(name)"
        case .triage: "triage"
        case .remainingWork: "remaining"
        case .openBugs: "bugs"
        }
    }

    public var title: String {
        switch self {
        case .me: "Me"
        case .all: "Everyone"
        case .squad(let name): name
        case .triage: "Triage"
        case .remainingWork: "Remaining Work"
        case .openBugs: "Open Bugs"
        }
    }

    /// Returns the chips in their order: Me, Everyone, one per squad by name, then Triage, Remaining Work and Open Bugs.
    ///
    /// - Parameter squads: the squad names, as ``squads(of:prefix:)`` finds them
    /// - Returns: the chips
    public static func chips(squads: [String]) -> [SlotChip] {
        [.me, .all] + squads.map(SlotChip.squad) + [.triage, .remainingWork, .openBugs]
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

    /// Returns whether a work item shows under the chip.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values: the committed label and the squad, status and type prefixes
    ///   - me: my GitLab username; `nil` when unknown, and then Me matches nothing
    /// - Returns: whether it matches
    public func matches(_ item: WorkItem, team: TeamValues, me: String?) -> Bool {
        let titles = Set(item.labels.map(\.title))
        let isOpen = item.state != .closed
        let status = team.statusLabelPrefix
        switch self {
        case .me:
            guard let me else { return false }
            return item.assignees?.contains { $0.username == me } ?? false
        case .all:
            return true
        case .squad(let name):
            return !team.squadLabelPrefix.isEmpty && titles.contains(team.squadLabelPrefix + name)
        case .triage:
            return !status.isEmpty && (titles.contains(status + "Triage") || titles.contains(status + "MaintainerTriage"))
        case .remainingWork:
            let isCommitted = team.committedLabel.isEmpty || titles.contains(team.committedLabel)
            return isOpen && isCommitted && !(status.isEmpty ? false : titles.contains(status + "Verified"))
        case .openBugs:
            return isOpen && !team.typeLabelPrefix.isEmpty && titles.contains(team.typeLabelPrefix + "Bug")
        }
    }

    /// Returns the points a slot can take under the chip: a squad's capacity, the sum over the squads for Everyone, and
    /// none for the other chips.
    ///
    /// - Parameters:
    ///   - capacity: the squads' capacity from Team; `nil` when it has none
    ///   - squads: the squads there are
    /// - Returns: the points; `nil` when there is no load to show
    public func capacity(_ capacity: SquadCapacity?, squads: [String]) -> Int? {
        guard let capacity else { return nil }
        switch self {
        case .squad(let name):
            return capacity.points(of: name)
        case .all:
            let points = squads.compactMap { capacity.points(of: $0) }
            return points.isEmpty ? nil : points.reduce(0, +)
        case .me, .triage, .remainingWork, .openBugs:
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

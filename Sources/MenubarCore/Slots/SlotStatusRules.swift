import Foundation

extension TeamValues {
    /// the prefix of an item's slot in Slots: the scheduled slot label's, which the team's slot planning web tool groups
    /// by, else the slot label's when Team has no scheduled prefix (SLOT-06)
    public var slotPrefix: String {
        slotScheduledLabelPrefix.isEmpty ? slotLabelPrefix : slotScheduledLabelPrefix
    }

    /// the prefix of an item's due slot, the slot it is committed to; `nil` without a scheduled prefix, where the slot
    /// label is the slot itself (SLOT-06)
    public var dueSlotPrefix: String? {
        slotScheduledLabelPrefix.isEmpty || slotLabelPrefix.isEmpty ? nil : slotLabelPrefix
    }
}

/// How the team's statuses, priorities and sizes read, as the team's slot planning web tool reads them (SLOT-10 to
/// SLOT-12). The values after the prefixes are the tool's own words: `Todo`, `InProgress`, `Verified`, …
public enum SlotStatusRules {
    /// the statuses in the order an item goes through them; the rest follow, an item without a status last
    static let order = [
        "MaintainerTriage", "Triage", "Planning", "Todo", "InProgress", "InVerification", "Verified", "OnHold",
        "WaitingForReporter", "Answered", "Duplicate", "Rejected", "Withdrawn",
    ]

    /// the statuses whose item is finished: the tool closes an item with one of them
    static let terminal: Set<String> = ["Verified", "Answered", "Rejected", "Duplicate", "Withdrawn"]

    /// Returns the value of the item's label with the prefix, like `InProgress` for `status::InProgress`.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - prefix: the label prefix from Team; empty has none
    /// - Returns: the value; `nil` without a prefix or a label
    public static func value(of item: WorkItem, prefix: String) -> String? {
        guard !prefix.isEmpty, let label = item.labels.first(where: { $0.title.hasPrefix(prefix) }) else { return nil }
        let value = String(label.title.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// Returns where a status sorts: the order an item goes through them, unknown ones after, none last (SLOT-12).
    public static func rank(of status: String?) -> Int {
        guard let status else { return order.count + 1 }
        return order.firstIndex { $0.caseInsensitiveCompare(status) == .orderedSame } ?? order.count
    }

    /// Returns how far an item is, the tool's way: Verified 1, InVerification 0.75, any other status 0. Without a status
    /// prefix in Team, a closed item is 1 (SLOT-10).
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - statusPrefix: the status label prefix from Team
    public static func progress(of item: WorkItem, statusPrefix: String) -> Double {
        guard !statusPrefix.isEmpty else { return item.state == .closed ? 1 : 0 }
        switch value(of: item, prefix: statusPrefix)?.lowercased() {
        case "verified": return 1
        case "inverification": return 0.75
        default: return 0
        }
    }

    /// Returns whether an item is finished: closed in GitLab, or a status the tool closes it for (SLOT-12).
    public static func isDone(_ item: WorkItem, statusPrefix: String) -> Bool {
        if item.state == .closed { return true }
        guard let status = value(of: item, prefix: statusPrefix) else { return false }
        return terminal.contains { $0.caseInsensitiveCompare(status) == .orderedSame }
    }

    /// Returns a priority's weight for the sort, the higher the more urgent: Blocker 4, Critical 3, Major or High 2,
    /// Minor, Medium or Low 1; anything else 0 (SLOT-12).
    public static func priority(of item: WorkItem, prefix: String) -> Int {
        switch value(of: item, prefix: prefix)?.lowercased() {
        case "blocker": 4
        case "critical": 3
        case "major", "high": 2
        case "minor", "medium", "low": 1
        default: 0
        }
    }

    /// Returns whether an item waits for another one, the tool's way (SLOT-10): never an epic, whose prerequisite label
    /// says Blocked whenever its children are open; never a finished item. An issue is blocked with the team's blocked
    /// label, or without one in Team by GitLab's own flag (an open blocker).
    public static func isBlocked(_ item: WorkItem, team: TeamValues) -> Bool {
        guard !item.isEpic, !isDone(item, statusPrefix: team.statusLabelPrefix) else { return false }
        if !team.blockedLabel.isEmpty {
            return item.labels.contains { $0.title.caseInsensitiveCompare(team.blockedLabel) == .orderedSame }
        }
        return item.isBlocked == true
    }

    /// Returns the size an epic's weight stands for, the tool's T-shirt sizes: S 1–5, M 6–15, L 16–30, XL 31 and more
    /// (SLOT-11).
    ///
    /// - Parameter weight: the weight of everything under the epic; 0 or less has no size
    public static func size(ofWeight weight: Int) -> String? {
        switch weight {
        case ...0: nil
        case 1...5: "S"
        case 6...15: "M"
        case 16...30: "L"
        default: "XL"
        }
    }
}

/// A planning gap of a slot's item, the team's slot planning web tool's rules (SLOT-11). The merge request and build
/// problems are ``SlotFlag``s.
public struct SlotProblem: Hashable, Sendable, Identifiable {
    public var kind: Kind
    /// more words, like "Size M, weight 40 is XL"; `nil` when the kind says it all
    public var detail: String?

    public init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public var id: Kind { kind }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// open and in a slot, without a weight
        case weightMissing
        /// open and in a slot, assigned to nobody
        case assigneeMissing
        /// an epic whose size label doesn't fit the weight under it
        case sizeMismatch

        public var text: String {
            switch self {
            case .weightMissing: "No weight"
            case .assigneeMissing: "No assignee"
            case .sizeMismatch: "Size doesn't fit the weight"
            }
        }

        /// the SF Symbol
        public var symbol: String {
            switch self {
            case .weightMissing: "scalemass"
            case .assigneeMissing: "person.crop.circle.badge.questionmark"
            case .sizeMismatch: "tshirt"
            }
        }
    }

    /// Returns an item's planning gaps: no weight and no assignee, for an open issue of a slot (a slot means it is
    /// scheduled or committed). The weight counts only when the slot group's query loaded the item, the only one that
    /// asks for it.
    ///
    /// - Parameter item: the work item
    /// - Returns: the problems, weight first
    static func problems(of item: WorkItem) -> [SlotProblem] {
        guard item.state != .closed, !item.isEpic else { return [] }
        var problems: [SlotProblem] = []
        // The slots' query always answers the blocked flag; every other query leaves it and the weight out.
        if item.isBlocked != nil, (item.weight ?? 0) <= 0 {
            problems.append(SlotProblem(kind: .weightMissing))
        }
        if let assignees = item.assignees, assignees.isEmpty {
            problems.append(SlotProblem(kind: .assigneeMissing))
        }
        return problems
    }

    /// Returns an epic's size problem: its size label's value isn't the size of the weight under it (SLOT-11).
    ///
    /// - Parameters:
    ///   - epic: the epic
    ///   - weight: the weight of every issue under it, in any slot; `nil` when GitLab didn't say
    ///   - prefix: the size label prefix from Team; empty checks nothing
    /// - Returns: the problem; `nil` when it fits, or without a size, a weight or a prefix
    public static func sizeProblem(of epic: WorkItemEpic, weight: Int?, prefix: String) -> SlotProblem? {
        guard !prefix.isEmpty, let weight, let expected = SlotStatusRules.size(ofWeight: weight),
            let label = epic.labels.first(where: { $0.title.hasPrefix(prefix) })
        else { return nil }
        let size = String(label.title.dropFirst(prefix.count))
        guard !size.isEmpty, size.caseInsensitiveCompare(expected) != .orderedSame else { return nil }
        return SlotProblem(kind: .sizeMismatch, detail: "Size \(size.uppercased()), but a weight of \(weight) is \(expected)")
    }
}

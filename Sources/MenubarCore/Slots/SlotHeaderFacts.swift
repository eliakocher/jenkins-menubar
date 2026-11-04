import Foundation

/// The numbers and help texts a slot card's header shows (SLOT-15), made once with the plan, so that drawing the header
/// reads them and counts nothing: the header is drawn again and again while the page scrolls.
public struct SlotHeaderFacts: Hashable, Sendable {
    /// What a counter pill counts.
    public enum CounterKind: Hashable, Sendable {
        /// the done items over all of them
        case done
        /// the open items without a weight
        case weightMissing
        /// the other planning problems
        case problems
        /// the flagged items
        case flagged
        /// the items planned, not committed
        case planned
    }

    /// One small pill: its count and what it says when hovered.
    public struct Counter: Hashable, Sendable {
        public var kind: CounterKind
        /// like "3/8" or "2"
        public var text: String
        /// the tooltip
        public var help: String
    }

    /// the pills, in the header's order; none for a slot without items
    public var counters: [Counter]
    /// "1 member" or "3 members"; `nil` without members
    public var membersText: String?
    /// whether the slot has items, so the points show
    public var hasItems: Bool
    /// the weight of every item
    public var points: Int
    /// the tooltip of the points and of the load
    public var pointsHelp: String

    /// Reads the numbers of a slot.
    public init(_ slot: SlotSummary) {
        let all = slot.allItems
        hasItems = !all.isEmpty
        points = all.reduce(0) { $0 + $1.weight }
        let members = slot.members.count
        membersText = members == 0 ? nil : members == 1 ? "1 member" : "\(members) members"

        var counters: [Counter] = []
        if !all.isEmpty {
            let done = all.count { $0.isDone }
            let progress = Int((slot.progress * 100).rounded())
            let open = slot.state == .overdue ? "; \(slot.openItems.count) still open" : ""
            counters.append(
                Counter(
                    kind: .done, text: "\(done)/\(all.count)",
                    help: "\(slot.progressText), \(progress) % by weight\(open)"))
        }
        let weightMissing = slot.weightMissingCount
        if weightMissing > 0 {
            counters.append(
                Counter(
                    kind: .weightMissing, text: "\(weightMissing)",
                    help: "\(weightMissing) open items without a weight: the points and the load leave them out"))
        }
        let otherProblems = slot.problemCount - weightMissing
        if otherProblems > 0 {
            counters.append(
                Counter(
                    kind: .problems, text: "\(otherProblems)",
                    help: otherProblems == 1 ? "1 more planning problem" : "\(otherProblems) more planning problems"))
        }
        let flags = slot.flagCount
        if flags > 0 {
            counters.append(
                Counter(kind: .flagged, text: "\(flags)", help: flags == 1 ? "1 flagged item" : "\(flags) flagged items"))
        }
        let planned = slot.uncommittedCount
        if planned > 0 {
            counters.append(
                Counter(
                    kind: .planned, text: "\(planned)",
                    help: planned == 1
                        ? "1 item planned for this slot, not committed yet"
                        : "\(planned) items planned for this slot, not committed yet"))
        }
        self.counters = counters

        var parts = ["The weight of all \(all.count) items, done and planned ones too; \(slot.committedPoints) of it committed."]
        if let capacity = slot.capacity {
            let amount = capacity.formatted(.number.precision(.fractionLength(0...1)))
            if let people = slot.capacityPeople {
                parts.append(
                    "Capacity \(amount) person-days: \(people == 1 ? "1 person" : "\(people) people") with items here, their work days from the code freeze to the release, weekdays only, no time off.")
            } else {
                parts.append("Capacity \(amount) points, the squad capacity.")
            }
        }
        let unweighted = slot.unweightedCount
        if unweighted > 0 {
            parts.append("\(unweighted) have no weight and count 0.")
        }
        pointsHelp = parts.joined(separator: " ")
    }
}

/// The header facts a slot remembers, left out of what makes two slots equal: they are made from the slot's items, so
/// they never tell slots apart.
struct SlotHeaderFactsCache: Hashable, Sendable {
    var facts: SlotHeaderFacts?

    static func == (left: Self, right: Self) -> Bool { true }

    func hash(into hasher: inout Hasher) {}
}

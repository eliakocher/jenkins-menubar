import Foundation

/// The variables of the WorkItems query, from the work item filters and the committed label (WI-01, WI-02, WI-03).
public enum WorkItemQuery {
    /// The WorkItems query's variables, as the old tool's `work_items_variables()` made them.
    ///
    /// The label lists are plain text, never interpreted (WI-04). A `nil` list is sent as `null`.
    public struct Variables: Hashable, Sendable {
        /// `[me]` for "Assigned to me", otherwise `nil`
        public var assignee: [String]?
        /// me for "Created by me", otherwise `nil`
        public var author: String?
        /// the one type asked for; `nil` for all types
        public var types: [String]?
        /// GitLab's `IssuableState`: `opened`, `closed` or `all`
        public var state: String
        /// GitLab's `IssueSort`
        public var sort: String
        /// whether the committed list is asked for
        public var withCommitted: Bool
        /// the committed list's `labelName`: all of these
        public var committedLabels: [String]
        /// the committed list's `or: {labelNames}`: any of these
        public var committedOr: [String]?
        /// the committed list's `not: {labelName}`
        public var committedNot: [String]?
        /// whether the not-committed list (or the single list) is asked for
        public var withOthers: Bool
        /// the other list's `labelName`
        public var otherLabels: [String]?
        /// the other list's `or: {labelNames}`
        public var otherOr: [String]?
        /// the other list's `not: {labelName}`, which takes out the committed label
        public var otherNot: [String]?
        /// how many not-committed work items show at most; the committed list always asks for 50
        public var first: Int

        public init(
            assignee: [String]?,
            author: String?,
            types: [String]?,
            state: String,
            sort: String,
            withCommitted: Bool,
            committedLabels: [String],
            committedOr: [String]?,
            committedNot: [String]?,
            withOthers: Bool,
            otherLabels: [String]?,
            otherOr: [String]?,
            otherNot: [String]?,
            first: Int
        ) {
            self.assignee = assignee
            self.author = author
            self.types = types
            self.state = state
            self.sort = sort
            self.withCommitted = withCommitted
            self.committedLabels = committedLabels
            self.committedOr = committedOr
            self.committedNot = committedNot
            self.withOthers = withOthers
            self.otherLabels = otherLabels
            self.otherOr = otherOr
            self.otherNot = otherNot
            self.first = first
        }

        /// the variables in the old tool's order, with the label filters as GitLab's input objects
        var graphQLValue: GraphQLValue {
            func strings(_ values: [String]?) -> GraphQLValue {
                values.map { .list($0.map(GraphQLValue.string)) } ?? .null
            }
            func filter(_ key: String, _ values: [String]?) -> GraphQLValue {
                values.map { .object([(key, .list($0.map(GraphQLValue.string)))]) } ?? .null
            }
            return .object([
                ("assignee", strings(assignee)),
                ("author", author.map(GraphQLValue.string) ?? .null),
                ("types", strings(types)),
                ("state", .string(state)),
                ("sort", .string(sort)),
                ("withCommitted", .bool(withCommitted)),
                ("committedLabels", strings(committedLabels)),
                ("committedOr", filter("labelNames", committedOr)),
                ("committedNot", filter("labelName", committedNot)),
                ("withOthers", .bool(withOthers)),
                ("otherLabels", strings(otherLabels)),
                ("otherOr", filter("labelNames", otherOr)),
                ("otherNot", filter("labelName", otherNot)),
                ("first", .int(first)),
            ])
        }
    }

    /// Returns the variables of the WorkItems query.
    ///
    /// - With "all" must-have labels, both lists ask for all of them (`labelName`), and the committed list for the
    ///   committed label too. With "any", both lists ask for any of them (`or: {labelNames}`), and the committed list
    ///   for the committed label (WI-03).
    /// - The committed list isn't asked for without a committed label, or when it is a must-not-have label. The other
    ///   list isn't asked for when the committed label is a must-have label in "all" mode (WI-01).
    ///
    /// - Parameters:
    ///   - preferences: the preferences, whose work item filters count
    ///   - project: the project, whose committed label counts
    ///   - me: my GitLab username
    /// - Returns: the variables
    public static func variables(preferences: Preferences, project: Project, me: String) -> Variables {
        let filters = preferences.workItems
        let committed = project.team.committedLabel
        let with = filters.withLabels
        let without = filters.withoutLabels
        // With any of the must-have labels, labelName (all of them) only keeps the committed label.
        let any = filters.labelsMatch == .any && !with.isEmpty
        let otherNot = sortedUnique((without + [committed]).filter { !$0.isEmpty })
        return Variables(
            assignee: filters.scope == .authored ? nil : [me],
            author: filters.scope == .authored ? me : nil,
            types: filters.type == .all ? nil : [filters.type.rawValue],
            state: filters.state.rawValue,
            sort: filters.sort.rawValue,
            withCommitted: !committed.isEmpty && !without.contains(committed),
            committedLabels: any ? [committed] : sortedUnique(with + [committed]),
            committedOr: any ? with : nil,
            committedNot: without.isEmpty ? nil : without,
            withOthers: any || committed.isEmpty || !with.contains(committed),
            otherLabels: any || with.isEmpty ? nil : with,
            otherOr: any ? with : nil,
            otherNot: otherNot.isEmpty ? nil : otherNot,
            first: filters.limit)
    }

    /// jq's `unique`: sorted, each once.
    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

// MARK: - The label rules

extension WorkItemFilters {
    /// The two label lists of the work item filters (WI-03).
    public enum LabelList: String, Hashable, Sendable, CaseIterable {
        /// "Must have": all or any of these
        case with
        /// "Must have none of these"
        case without
    }

    /// Returns a label's scope: all before its last `::`, like `uStatus::Sub` for `uStatus::Sub::Deep`.
    ///
    /// - Parameter label: the label's title
    /// - Returns: the scope, or `nil` for a label without `::`
    public static func scope(of label: String) -> String? {
        Label.scopeAndValue(of: label)?.scope
    }

    /// Returns the list a label is in.
    ///
    /// - Parameter label: the label's title
    /// - Returns: the list, or `nil` when the label is in neither
    public func list(of label: String) -> LabelList? {
        if withLabels.contains(label) { .with } else if withoutLabels.contains(label) { .without } else { nil }
    }

    /// Puts a label in one of the lists, or in neither; a label is never in both (WI-03).
    ///
    /// In "all" mode a work item has one label per scope, so a new must-have label replaces the one of its scope.
    ///
    /// - Parameters:
    ///   - label: the label's title, kept as it is
    ///   - list: the list, or `nil` to take the label out of the filters
    public mutating func setLabel(_ label: String, in list: LabelList?) {
        if list == .with, labelsMatch == .all, let scope = Self.scope(of: label) {
            withLabels.removeAll { Self.scope(of: $0) == scope }
        }
        withLabels.removeAll { $0 == label }
        withoutLabels.removeAll { $0 == label }
        switch list {
        case .with: withLabels.append(label)
        case .without: withoutLabels.append(label)
        case nil: break
        }
    }

    /// Sets whether a work item needs all or any of the must-have labels. Switching to "all" keeps the last must-have
    /// label of each scope, since a work item never has two (WI-03).
    ///
    /// - Parameter match: all or any
    public mutating func setLabelsMatch(_ match: LabelsMatch) {
        labelsMatch = match
        guard match == .all else { return }
        for label in withLabels {
            setLabel(label, in: .with)
        }
    }

    /// Empties both label lists ("Clear All", WI-03).
    public mutating func clearLabels() {
        withLabels = []
        withoutLabels = []
    }

    /// Returns the log message of a label put in a list, or taken out (WI-03).
    ///
    /// - Parameters:
    ///   - label: the label's title
    ///   - list: the list it went to, or `nil` when it was taken out
    /// - Returns: the message, like "Work items must have the label X"
    public static func message(label: String, putIn list: LabelList?) -> String {
        switch list {
        case .with: "Work items must have the label \(label)"
        case .without: "Work items must not have the label \(label)"
        case nil: "The label \(label) is out of the work item filters"
        }
    }

    /// Returns the log message of a change of the labels match (WI-03).
    ///
    /// - Parameter match: the new match
    /// - Returns: "Work items need all of the must-have labels", or "any of" them
    public static func message(labelsMatch match: LabelsMatch) -> String {
        "Work items need \(match == .all ? "all" : "any") of the must-have labels"
    }

    /// the log message of "Clear All" (WI-03)
    public static let clearedLabelsMessage = "Cleared the work item label filters"

    /// The filters in one line, joined with " · ": the scope, the type when not all, the state, "+<value>" per
    /// must-have label ("+(bug or web)" for two or more in "any" mode), "−<value>" per must-not-have label (WI-02).
    public var summary: String {
        var parts = [scope == .assigned ? "Assigned to me" : "Created by me"]
        switch type {
        case .all: break
        case .issue: parts.append("Issues")
        case .task: parts.append("Tasks")
        case .epic: parts.append("Epics")
        case .incident: parts.append("Incidents")
        }
        switch state {
        case .opened: parts.append("Open")
        case .closed: parts.append("Closed")
        case .all: parts.append("Open and closed")
        }
        if labelsMatch == .any, withLabels.count > 1 {
            parts.append("+(" + withLabels.map(Self.value(of:)).joined(separator: " or ") + ")")
        } else {
            parts += withLabels.map { "+" + Self.value(of: $0) }
        }
        parts += withoutLabels.map { "−" + Self.value(of: $0) }
        return parts.joined(separator: " · ")
    }

    /// A label's value in the summary: all after its first `::`, or else after its first `:`, or else the label.
    static func value(of label: String) -> String {
        if let range = label.range(of: "::") ?? label.range(of: ":") {
            String(label[range.upperBound...])
        } else {
            label
        }
    }
}

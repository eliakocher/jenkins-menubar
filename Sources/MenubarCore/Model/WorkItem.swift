import Foundation

/// A GitLab work item (an issue, task, epic or incident) that the work item filters found (WI-01).
///
/// Taken from the WorkItems query: `title webUrl reference(full: true) updatedAt type state
/// labels(first: 30) { nodes { title color } }`. Its related merge requests load apart from it (OD-03), as
/// ``RelatedMergeRequest`` values.
public struct WorkItem: Codable, Hashable, Identifiable, Sendable {
    /// the full reference, like `group/project#12`, or `group&3` for an epic
    public var reference: String
    public var title: String
    public var webURL: URL
    public var type: WorkItemType
    public var state: WorkItemState
    /// the labels in GitLab's order; their titles are plain text, never interpreted (WI-04)
    public var labels: [Label]
    public var updatedAt: Date
    /// who opened it; `nil` for a deleted user, and in a cache written before the field was asked for
    public var author: MergeRequest.Person?
    /// who it is assigned to, in GitLab's order; `nil` in a cache written before the field was asked for
    public var assignees: [MergeRequest.Person]?
    /// the issue's weight; `nil` when it has none, and from every query but the slots' (SLOT-06)
    public var weight: Int?
    /// the epic it belongs to; `nil` without one, and from every query but the slots' (SLOT-06)
    public var epic: WorkItemEpic?
    /// whether an open item blocks it, by GitLab's links; `nil` from every query but the slots' (SLOT-06)
    public var isBlocked: Bool?
    /// the due date as GitLab sends it, `2026-11-02`; `nil` without one (SLOT-06)
    public var dueDate: String?

    public init(
        reference: String,
        title: String,
        webURL: URL,
        type: WorkItemType = .issue,
        state: WorkItemState = .opened,
        labels: [Label] = [],
        updatedAt: Date,
        author: MergeRequest.Person? = nil,
        assignees: [MergeRequest.Person]? = nil,
        weight: Int? = nil,
        epic: WorkItemEpic? = nil,
        isBlocked: Bool? = nil,
        dueDate: String? = nil
    ) {
        self.reference = reference
        self.title = title
        self.webURL = webURL
        self.type = type
        self.state = state
        self.labels = labels
        self.updatedAt = updatedAt
        self.author = author
        self.assignees = assignees
        self.weight = weight
        self.epic = epic
        self.isBlocked = isBlocked
        self.dueDate = dueDate
    }

    public var id: String { reference }

    /// whether the reference is an epic's (`&N`), whose related MRs aren't asked for (WI-05)
    public var isEpic: Bool { reference.contains("&") }

    /// the iid after the reference's last `#` or `&`, as the RelatedMergeRequests query takes it
    public var iid: String? {
        guard let sign = reference.lastIndex(where: { $0 == "#" || $0 == "&" }) else { return nil }
        let iid = reference[reference.index(after: sign)...]
        return iid.isEmpty || !iid.allSatisfy(\.isASCII) || !iid.allSatisfy(\.isNumber) ? nil : String(iid)
    }

    /// the title as the rows, the pane and the detail show it: without a leading `[KEY-<iid>]` of an old tracker that kept
    /// the item's number; see ``displayTitle(of:iid:)``. Tooltips, copied links and search keep ``title``.
    public var displayTitle: String { Self.displayTitle(of: title, iid: iid) }

    /// Returns a title without its own key: a leading `[<KEY>-<digits>]` (KEY is letters and digits, starting with a
    /// letter, in any case; spaces, a `:` or a `-` may follow) is dropped only when the digits are the item's number,
    /// since a key with another number is a real reference. A title that is nothing but the key stays whole.
    ///
    /// - Parameters:
    ///   - title: the item's title
    ///   - iid: the item's number, as ``iid`` has it
    /// - Returns: the title to show
    public static func displayTitle(of title: String, iid: String?) -> String {
        guard let iid, let number = Int(iid), title.hasPrefix("["), let close = title.firstIndex(of: "]") else {
            return title
        }
        let key = title[title.index(after: title.startIndex)..<close]
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first, first.isASCII, first.isLetter,
            parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
            !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), Int(parts[1]) == number
        else {
            return title
        }
        var rest = title[title.index(after: close)...].drop { $0 == " " }
        if let separator = rest.first, separator == ":" || separator == "-" {
            rest = rest.dropFirst().drop { $0 == " " }
        }
        return rest.isEmpty ? title : String(rest)
    }

    /// Returns the slot: the value of the first label that starts with the slot prefix (WI-04).
    ///
    /// - Parameter prefix: the slot label prefix from Team; empty means no slot
    /// - Returns: the label's title after the prefix, or `nil`
    public func slot(prefix: String) -> String? {
        guard !prefix.isEmpty, let label = labels.first(where: { $0.title.hasPrefix(prefix) }) else { return nil }
        return String(label.title.dropFirst(prefix.count))
    }
}

/// The epic of a slot's issue, as the slots' query takes it from `issue.epic` (SLOT-06).
public struct WorkItemEpic: Codable, Hashable, Identifiable, Sendable {
    /// the full reference, like `group&3`
    public var reference: String
    public var title: String
    public var webURL: URL
    public var state: WorkItemState
    public var labels: [Label]

    public init(reference: String, title: String, webURL: URL, state: WorkItemState = .opened, labels: [Label] = []) {
        self.reference = reference
        self.title = title
        self.webURL = webURL
        self.state = state
        self.labels = labels
    }

    public var id: String { reference }
}

/// GitLab's `IssueType`. Others are kept as they come.
public struct WorkItemType: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// GitLab's enum value, like `TASK`
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let issue = WorkItemType(rawValue: "ISSUE")
    public static let task = WorkItemType(rawValue: "TASK")
    public static let epic = WorkItemType(rawValue: "EPIC")
    public static let incident = WorkItemType(rawValue: "INCIDENT")

    public var description: String { rawValue }
}

/// GitLab's `IssueState`. Others are kept as they come.
public struct WorkItemState: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// GitLab's enum value, like `opened`
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let opened = WorkItemState(rawValue: "opened")
    public static let closed = WorkItemState(rawValue: "closed")

    public var description: String { rawValue }
}

/// A merge request that mentions a work item, from the RelatedMergeRequests query (WI-05):
/// `iid state title webUrl reference(full: true)`.
public struct RelatedMergeRequest: Codable, Hashable, Identifiable, Sendable {
    public var iid: Int
    public var state: State
    public var title: String
    public var webURL: URL
    /// the full reference, like `group/project!12`
    public var reference: String

    public init(iid: Int, state: State, title: String, webURL: URL, reference: String) {
        self.iid = iid
        self.state = state
        self.title = title
        self.webURL = webURL
        self.reference = reference
    }

    public var id: URL { webURL }

    /// GitLab's `MergeRequestState`. Others are kept as they come.
    public struct State: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        /// GitLab's enum value, like `merged`
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let opened = State(rawValue: "opened")
        public static let merged = State(rawValue: "merged")
        public static let closed = State(rawValue: "closed")

        public var description: String { rawValue }
    }
}

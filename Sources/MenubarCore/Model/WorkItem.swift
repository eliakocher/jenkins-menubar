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
/// `iid state title webUrl reference(full: true) sourceBranch`.
public struct RelatedMergeRequest: Codable, Hashable, Identifiable, Sendable {
    public var iid: Int
    public var state: State
    public var title: String
    public var webURL: URL
    /// the full reference, like `group/project!12`
    public var reference: String
    /// the source branch; `nil` in a cache written before the field was asked for
    public var sourceBranch: String?
    /// whether GitLab says the MR closes the work item when merged; `false` while the query doesn't ask for it (the
    /// issue type has no list of closing MRs, only the development widget of a work item has one)
    public var closesWorkItem: Bool

    public init(
        iid: Int, state: State, title: String, webURL: URL, reference: String, sourceBranch: String? = nil,
        closesWorkItem: Bool = false
    ) {
        self.iid = iid
        self.state = state
        self.title = title
        self.webURL = webURL
        self.reference = reference
        self.sourceBranch = sourceBranch
        self.closesWorkItem = closesWorkItem
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        iid = try values.decode(Int.self, forKey: .iid)
        state = try values.decode(State.self, forKey: .state)
        title = try values.decode(String.self, forKey: .title)
        webURL = try values.decode(URL.self, forKey: .webURL)
        reference = try values.decode(String.self, forKey: .reference)
        sourceBranch = try values.decodeIfPresent(String.self, forKey: .sourceBranch)
        closesWorkItem = try values.decodeIfPresent(Bool.self, forKey: .closesWorkItem) ?? false
    }

    public var id: URL { webURL }

    /// the project path of the reference, `group/project` of `group/project!12`
    var projectPath: String {
        reference.lastIndex(of: "!").map { String(reference[..<$0]) } ?? ""
    }

    /// Returns whether this is the work item's own MR, not one that only mentions it: it closes the item, or, in the
    /// item's project, its source branch starts with `<iid>-` (the team's branch rule, see ``WorkItem/branchName``) or
    /// its title starts with `#<iid>` (after a `Draft:` marker, and not followed by another digit). The branch and
    /// title rules need the same project, since another project has its own numbers.
    ///
    /// - Parameter workItem: the work item
    /// - Returns: whether the MR is the item's own
    public func isOwn(of workItem: WorkItem) -> Bool {
        if closesWorkItem {
            return true
        }
        guard let iid = workItem.iid, let sign = workItem.reference.lastIndex(of: "#"),
            String(workItem.reference[..<sign]) == projectPath
        else {
            return false
        }
        if let sourceBranch, sourceBranch.hasPrefix("\(iid)-") {
            return true
        }
        var text = Substring(title)
        for marker in ["draft:", "[draft]", "(draft)", "wip:"] where text.lowercased().hasPrefix(marker) {
            text = text.dropFirst(marker.count).drop { $0 == " " }
            break
        }
        guard text.hasPrefix("#\(iid)") else { return false }
        let next = text.dropFirst(iid.count + 1).first
        return next.map { !($0.isASCII && $0.isNumber) } ?? true
    }

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

extension WorkItem {
    /// Returns the MRs of the work item that count for its chips, its marker and the slots: its own MRs (see
    /// ``RelatedMergeRequest/isOwn(of:)``), or all of them when none is its own.
    ///
    /// - Parameter mergeRequests: every MR that mentions the item
    /// - Returns: the own MRs, else all, in the given order
    public func shownMergeRequests(from mergeRequests: [RelatedMergeRequest]) -> [RelatedMergeRequest] {
        let own = mergeRequests.filter { $0.isOwn(of: self) }
        return own.isEmpty ? mergeRequests : own
    }

    /// The branch name the team gives the item's branch: the number, `-`, then the title in lowercase kebab case.
    /// Accents are dropped (`é` becomes `e`), every run of characters other than `a-z` and `0-9` becomes one `-`, none
    /// stays at the ends, and the length is not capped. A `Draft:` prefix stays as words. An empty title gives the
    /// number alone.
    public var branchName: String {
        Self.branchName(iid: iid ?? "", title: title)
    }

    /// Returns a branch name, see ``branchName``.
    ///
    /// - Parameters:
    ///   - iid: the item's number
    ///   - title: the item's title
    /// - Returns: the name, like `18874-fix-closing-the-dialog`
    public static func branchName(iid: String, title: String) -> String {
        var words: [String] = []
        var word = ""
        for character in title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) {
            if character.isASCII, character.isLetter || character.isNumber {
                word.append(character.lowercased())
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty {
            words.append(word)
        }
        return ([iid].filter { !$0.isEmpty } + words).joined(separator: "-")
    }
}

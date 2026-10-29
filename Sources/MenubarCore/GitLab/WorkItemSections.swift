import Foundation

/// The work items in the sections of WI-01: "Committed" and "Not Committed" with a committed label, otherwise a
/// single "Work Items" list.
public struct WorkItemSections: Hashable, Sendable {
    /// the sections that have work items, committed first
    public var sections: [Section]
    /// "Work Items · 3 committed" when committed ones exist, otherwise "Work Items (count)" of the other list
    public var header: String

    /// the text when no list has a work item
    public static let emptyText = "No work items match the filter"

    /// - Parameters:
    ///   - lists: the loaded lists
    ///   - committedLabel: the committed label from Team; empty means a single list
    public init(_ lists: WorkItemLists, committedLabel: String) {
        var sections: [Section] = []
        if let committed = lists.committed, !committed.items.isEmpty {
            sections.append(Section(kind: .committed, list: committed))
        }
        if let others = lists.others, !others.items.isEmpty {
            sections.append(Section(kind: committedLabel.isEmpty ? .all : .notCommitted, list: others))
        }
        self.sections = sections
        if let committed = lists.committed, committed.count > 0 {
            header = "Work Items · \(committed.count) committed"
        } else {
            header = "Work Items (\(Section.countText(of: lists.others ?? WorkItemList(count: 0, items: []))))"
        }
    }

    /// whether no list has a work item, which shows ``emptyText``
    public var isEmpty: Bool { sections.isEmpty }

    /// One list of work items, with its title.
    public struct Section: Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var list: WorkItemList

        public init(kind: Kind, list: WorkItemList) {
            self.kind = kind
            self.list = list
        }

        public var id: Kind { kind }

        /// like "Committed (2)" or "Not Committed (20 of 29)"
        public var title: String { "\(kind.title) (\(countText))" }

        /// "N", or "N of M" when M exist and N show
        public var countText: String { Self.countText(of: list) }

        static func countText(of list: WorkItemList) -> String {
            list.count > list.items.count ? "\(list.items.count) of \(list.count)" : "\(list.count)"
        }
    }

    /// The kinds of lists.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case committed
        case notCommitted
        /// the single list, without a committed label
        case all

        public var title: String {
            switch self {
            case .committed: "Committed"
            case .notCommitted: "Not Committed"
            case .all: "Work Items"
            }
        }
    }
}

extension WorkItem {
    /// Returns the short reference: "#12" (or "&12" for an epic) in the project, with the last path segment in
    /// another one (WI-04).
    ///
    /// - Parameter project: the team's project path
    /// - Returns: the short reference
    public func shortReference(project: String) -> String {
        GitLabText.shortReference(reference, project: project)
    }
}

/// The marker of a work item with related merge requests (WI-05): the old 🔀 and 🏁.
public enum RelatedMergeRequestMarker: String, Hashable, Sendable, CaseIterable {
    /// one of its related MRs is open
    case open
    /// none is open, and one is merged
    case merged

    /// the SF Symbol's name
    public var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .merged: "flag.checkered"
        }
    }

    /// the accessibility label and tooltip
    public var text: String {
        switch self {
        case .open: "Open merge request"
        case .merged: "Merged merge request"
        }
    }

    /// Returns the marker of a work item: open when one of its counted MRs is open, otherwise merged when one is
    /// merged. MRs whose title starts with the ignored prefix (Team), like automatic cascade MRs, only mention the
    /// work item and don't count.
    ///
    /// - Parameters:
    ///   - mergeRequests: the MRs that mention the work item
    ///   - ignoredPrefix: the ignored MR prefix from Team; empty counts every MR
    /// - Returns: the marker, or `nil` for none
    public static func of(_ mergeRequests: [RelatedMergeRequest], ignoredPrefix: String) -> RelatedMergeRequestMarker? {
        let counted = mergeRequests.filter { ignoredPrefix.isEmpty || !$0.title.hasPrefix(ignoredPrefix) }
        return if counted.contains(where: { $0.state == .opened }) {
            .open
        } else if counted.contains(where: { $0.state == .merged }) {
            .merged
        } else {
            nil
        }
    }
}

/// The related merge requests of the work items, by reference (WI-05, OD-03).
///
/// An entry that doesn't decode is left out when the cache is read, so a broken entry costs only its own marker.
public struct RelatedMergeRequestsCache: Codable, Hashable, Sendable {
    /// the answers by the work item's full reference
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The answer for one work item.
    public struct Entry: Codable, Hashable, Sendable {
        /// the work item's `updatedAt` when it was asked; a newer one asks again (OD-03)
        public var workItemUpdatedAt: Date
        /// when GitLab answered
        public var fetchedAt: Date
        public var mergeRequests: [RelatedMergeRequest]

        public init(workItemUpdatedAt: Date, fetchedAt: Date, mergeRequests: [RelatedMergeRequest]) {
            self.workItemUpdatedAt = workItemUpdatedAt
            self.fetchedAt = fetchedAt
            self.mergeRequests = mergeRequests
        }
    }

    /// Returns the marker of a work item from its cached answer (WI-05).
    ///
    /// - Parameters:
    ///   - workItem: the work item
    ///   - ignoredPrefix: the ignored MR prefix from Team
    /// - Returns: the marker, or `nil` without one or without an answer
    public func marker(of workItem: WorkItem, ignoredPrefix: String) -> RelatedMergeRequestMarker? {
        entries[workItem.reference].flatMap { RelatedMergeRequestMarker.of($0.mergeRequests, ignoredPrefix: ignoredPrefix) }
    }

    private enum Key: String, CodingKey {
        case entries
    }

    private struct Lossy: Decodable {
        var entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let lossy = try decoder.container(keyedBy: Key.self).decode([String: Lossy].self, forKey: .entries)
        entries = lossy.compactMapValues(\.entry)
    }
}

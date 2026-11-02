import Foundation

/// A commitment of the team: an epic of the commitment group (Team) with its own due date, blocked by the items that are
/// committed to it (SLOT-14). The team's slot planning web tool puts commitments at the top of a slot's tree. The bot
/// writes the slot labels on them too, so a commitment has a slot like any item.
public struct SlotCommitment: Codable, Hashable, Sendable, Identifiable {
    /// the full reference, like `group/commitments&12`
    public var reference: String
    public var title: String
    public var webURL: URL
    public var state: WorkItemState
    public var labels: [Label]
    /// the due date a person typed, `2026-11-30`; `nil` without one
    public var dueDate: String?
    public var assignees: [MergeRequest.Person]
    /// the items it is blocked by, the committed ones: their references and web pages
    public var committed: [Linked]

    /// An item a commitment is blocked by.
    public struct Linked: Codable, Hashable, Sendable {
        public var reference: String
        public var webURL: URL?

        public init(reference: String, webURL: URL? = nil) {
            self.reference = reference
            self.webURL = webURL
        }

        /// whether it is the item with the reference or the web page
        func names(reference: String, webURL: URL?) -> Bool {
            if self.reference == reference { return true }
            guard let left = self.webURL.map(SlotCommitment.itemPath), let right = webURL.map(SlotCommitment.itemPath) else {
                return false
            }
            return left == right
        }
    }

    public init(
        reference: String, title: String, webURL: URL, state: WorkItemState = .opened, labels: [Label] = [],
        dueDate: String? = nil, assignees: [MergeRequest.Person] = [], committed: [Linked] = []
    ) {
        self.reference = reference
        self.title = title
        self.webURL = webURL
        self.state = state
        self.labels = labels
        self.dueDate = dueDate
        self.assignees = assignees
        self.committed = committed
    }

    public var id: String { reference }

    /// Returns whether an item, or its epic, is one the commitment is blocked by: by its reference, else by its web
    /// page's path, since GitLab writes an issue's page as `/-/issues/N` or `/-/work_items/N`.
    func covers(reference: String, webURL: URL?) -> Bool {
        committed.contains { $0.names(reference: reference, webURL: webURL) }
    }

    /// the page's path with the kind of item dropped: `group/project/N` for `/group/project/-/issues/N`
    static func itemPath(_ url: URL) -> String {
        var parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if let dash = parts.firstIndex(of: "-"), dash + 1 < parts.count {
            parts.removeSubrange(dash...(dash + 1))
        }
        if parts.first == "groups" { parts.removeFirst() }
        return parts.joined(separator: "/").lowercased()
    }
}

/// A commitment of a slot with the slot's items that are committed to it, grouped by epic (SLOT-14).
public struct SlotCommitmentGroup: Hashable, Sendable, Identifiable {
    public var commitment: SlotCommitment
    /// the slot's items under it: committed to it themselves, or through their epic
    public var groups: [SlotEpicGroup]
    /// how many of its committed items aren't in this slot: in other slots, or not loaded
    public var elsewhere: Int

    public var id: String { commitment.id }

    /// every item of the slot under it
    public var items: [SlotItem] { groups.flatMap(\.items) }

    /// this slot's share of its progress (SLOT-10)
    public var progress: Double { SlotSummary.progress(of: items) }

    /// Returns the slot's commitments with their items: the commitments with items here, by due date, then by title.
    ///
    /// - Parameters:
    ///   - commitments: the slot's commitments
    ///   - groups: the slot's items by epic
    /// - Returns: the commitments; an epic or an item under two shows under both
    static func groups(of commitments: [SlotCommitment], in groups: [SlotEpicGroup]) -> [SlotCommitmentGroup] {
        commitments.compactMap { commitment -> SlotCommitmentGroup? in
            var under: [SlotEpicGroup] = []
            for group in groups {
                if let epic = group.epic, commitment.covers(reference: epic.reference, webURL: epic.webURL) {
                    under.append(group)
                    continue
                }
                var part = group
                part.items = group.items.filter {
                    commitment.covers(reference: $0.workItem.reference, webURL: $0.workItem.webURL)
                }
                if !part.items.isEmpty { under.append(part) }
            }
            guard !under.isEmpty else { return nil }
            var here: [(reference: String, webURL: URL)] = []
            for group in under {
                if let epic = group.epic { here.append((epic.reference, epic.webURL)) }
                here += group.items.map { ($0.workItem.reference, $0.workItem.webURL) }
            }
            let elsewhere = commitment.committed.count { linked in
                !here.contains { linked.names(reference: $0.reference, webURL: $0.webURL) }
            }
            return SlotCommitmentGroup(commitment: commitment, groups: under, elsewhere: elsewhere)
        }
        .sorted { ($0.commitment.dueDate ?? "9999", $0.commitment.title) < ($1.commitment.dueDate ?? "9999", $1.commitment.title) }
    }
}

extension GitLabOperation where Value == SlotCommitmentsPage {
    /// One page of the commitments of a slot: the epics of the commitment group with any of the labels, open and closed,
    /// with their labels, due date, assignees and the items they are blocked by (SLOT-14). Taken from GitLab's docs on
    /// work items (`workItems(types: [EPIC])` and its widgets), not yet run against the team's GitLab.
    ///
    /// - Parameters:
    ///   - group: the commitment group's full path
    ///   - labels: the labels, like the slot's scheduled slot label
    ///   - after: the cursor of the page before; `nil` for the first page
    /// - Returns: the operation
    public static func slotCommitments(group: String, labels: [String], after: String? = nil) -> GitLabOperation {
        GitLabOperation(
            name: "SlotCommitments",
            query: """
                query SlotCommitments($group: ID!, $labels: [String!], $after: String) {
                  group(fullPath: $group) {
                    workItems(types: [EPIC], labelName: $labels, state: all, first: 50, after: $after) {
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        reference(full: true)
                        title
                        webUrl
                        state
                        widgets {
                          ... on WorkItemWidgetLabels { labels(first: 40) { nodes { title color } } }
                          ... on WorkItemWidgetStartAndDueDate { dueDate }
                          ... on WorkItemWidgetAssignees { assignees(first: 10) { nodes { username name } } }
                          ... on WorkItemWidgetLinkedItems {
                            linkedItems(first: 100) { nodes { linkType workItem { reference(full: true) webUrl } } }
                          }
                        }
                      }
                    }
                  }
                }
                """,
            variables: .object([
                ("group", .string(group)), ("labels", .list(labels.map(GraphQLValue.string))),
                ("after", after.map(GraphQLValue.string) ?? .null),
            ]),
            decode: { body in
                let answer = try GraphQLAnswer<SlotCommitmentsShape>.decode(body)
                if let errors = answer.errors, !errors.isEmpty {
                    throw GitLabError(.graphQLErrors(messages: errors.map(\.message)))
                }
                guard let items = answer.data?.group?.workItems else {
                    throw GitLabError(.graphQLErrors(messages: ["GitLab has no group \(group)"]))
                }
                return SlotCommitmentsPage(
                    commitments: items.nodes.nodes.map(\.commitment),
                    nextCursor: items.pageInfo.hasNextPage ? items.pageInfo.endCursor : nil)
            })
    }
}

/// One page of a slot's commitments (SLOT-14).
public struct SlotCommitmentsPage: Hashable, Sendable {
    public var commitments: [SlotCommitment]
    /// the cursor of the next page; `nil` on the last one
    public var nextCursor: String?

    public init(commitments: [SlotCommitment], nextCursor: String? = nil) {
        self.commitments = commitments
        self.nextCursor = nextCursor
    }
}

private struct SlotCommitmentsShape: Decodable {
    var group: Group?

    struct Group: Decodable {
        var workItems: WorkItems
    }

    struct WorkItems: Decodable {
        var pageInfo: PageInfo
        var nodes: Nodes<Node>

        private enum Key: String, CodingKey {
            case pageInfo, nodes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)
            nodes = try Nodes(from: decoder)
        }
    }

    struct PageInfo: Decodable {
        var hasNextPage: Bool
        var endCursor: String?
    }

    struct Person: Decodable {
        var username: String
        var name: String?
    }

    struct Linked: Decodable {
        var linkType: String?
        var workItem: Target?
    }

    struct Target: Decodable {
        var reference: String
        var webUrl: URL?
    }

    /// any widget: each kind fills only its own fields
    struct Widget: Decodable {
        var labels: Nodes<LabelNode>?
        var dueDate: String?
        var assignees: Nodes<Person>?
        var linkedItems: Nodes<Linked>?
    }

    struct Node: Decodable {
        var reference: String
        var title: String
        var webUrl: URL
        var state: String?
        var widgets: [Widget]?

        var commitment: SlotCommitment {
            let widgets = widgets ?? []
            let linked = widgets.compactMap(\.linkedItems).flatMap(\.nodes)
            return SlotCommitment(
                reference: reference, title: title, webURL: webUrl,
                state: state?.lowercased() == "closed" ? .closed : .opened,
                labels: widgets.compactMap(\.labels).flatMap(\.nodes).map(\.label),
                dueDate: widgets.lazy.compactMap(\.dueDate).first,
                assignees: widgets.compactMap(\.assignees).flatMap(\.nodes).map {
                    MergeRequest.Person(username: $0.username, name: $0.name ?? "")
                },
                committed: linked.filter { $0.linkType?.lowercased() == "is_blocked_by" }.compactMap(\.workItem).map {
                    SlotCommitment.Linked(reference: $0.reference, webURL: $0.webUrl)
                })
        }
    }
}

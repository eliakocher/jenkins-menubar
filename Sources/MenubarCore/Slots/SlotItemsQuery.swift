import Foundation

/// One page of a slot's issues from the slot group (SLOT-06).
public struct SlotItemsPage: Hashable, Sendable {
    public var items: [WorkItem]
    /// how many issues GitLab has for the slot, all pages together
    public var count: Int
    /// the cursor of the next page; `nil` on the last one
    public var nextCursor: String?

    public init(items: [WorkItem], count: Int, nextCursor: String? = nil) {
        self.items = items
        self.count = count
        self.nextCursor = nextCursor
    }
}

extension GitLabOperation where Value == SlotItemsPage {
    /// One page of the issues of a group and its subgroups that carry any of the labels, open and closed: a slot's
    /// committed ones (the slot label) and its planned ones (the scheduled slot label) (SLOT-06). Each comes with its
    /// weight, assignees, epic, blocked flag and due date. A group GitLab doesn't know is an error.
    ///
    /// - Parameters:
    ///   - group: the group's full path
    ///   - labels: the labels, any of which an issue has
    ///   - after: the cursor of the page before; `nil` for the first page
    /// - Returns: the operation
    public static func slotItems(group: String, labels: [String], after: String? = nil) -> GitLabOperation {
        GitLabOperation(
            name: "SlotItems",
            query: """
                query SlotItems($group: ID!, $labels: [String!], $after: String) {
                  group(fullPath: $group) {
                    issues(includeSubgroups: true, or: {labelNames: $labels}, state: all, first: 100, after: $after) {
                      count
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        title
                        webUrl
                        reference(full: true)
                        updatedAt
                        type
                        state
                        weight
                        dueDate
                        blocked
                        labels(first: 40) { nodes { title color } }
                        assignees(first: 10) { nodes { username name } }
                        epic { reference(full: true) title webUrl state labels(first: 30) { nodes { title color } } }
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
                let answer = try GraphQLAnswer<SlotItemsShape>.decode(body)
                if let errors = answer.errors, !errors.isEmpty {
                    throw GitLabError(.graphQLErrors(messages: errors.map(\.message)))
                }
                guard let issues = answer.data?.group?.issues else {
                    throw GitLabError(.graphQLErrors(messages: ["GitLab has no group \(group)"]))
                }
                return SlotItemsPage(
                    items: issues.nodes.nodes.map(\.workItem), count: issues.count,
                    nextCursor: issues.pageInfo.hasNextPage ? issues.pageInfo.endCursor : nil)
            })
    }
}

private struct SlotItemsShape: Decodable {
    var group: Group?

    struct Group: Decodable {
        var issues: Issues
    }

    struct Issues: Decodable {
        var count: Int
        var pageInfo: PageInfo
        var nodes: Nodes<Node>

        private enum Key: String, CodingKey {
            case count, pageInfo, nodes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            count = try container.decode(Int.self, forKey: .count)
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

    struct Epic: Decodable {
        var reference: String
        var title: String
        var webUrl: URL
        var state: String?
        var labels: Nodes<LabelNode>?
    }

    struct Node: Decodable {
        var title: String
        var webUrl: URL
        var reference: String
        var updatedAt: Date
        var type: String?
        var state: String?
        var weight: Int?
        var dueDate: String?
        var blocked: Bool?
        var labels: Nodes<LabelNode>?
        var assignees: Nodes<Person>?
        var epic: Epic?

        var workItem: WorkItem {
            WorkItem(
                reference: reference,
                title: title,
                webURL: webUrl,
                type: type.map(WorkItemType.init(rawValue:)) ?? .issue,
                state: state.map(WorkItemState.init(rawValue:)) ?? .opened,
                labels: (labels?.nodes ?? []).map(\.label),
                updatedAt: updatedAt,
                assignees: (assignees?.nodes ?? []).map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") },
                weight: weight,
                epic: epic.map {
                    WorkItemEpic(
                        reference: $0.reference, title: $0.title, webURL: $0.webUrl,
                        state: $0.state.map(WorkItemState.init(rawValue:)) ?? .opened, labels: ($0.labels?.nodes ?? []).map(\.label))
                },
                isBlocked: blocked,
                dueDate: dueDate)
        }
    }
}

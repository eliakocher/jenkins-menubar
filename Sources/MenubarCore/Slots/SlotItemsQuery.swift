import Foundation

/// One page of a slot's issues from the slot group (SLOT-06).
public struct SlotItemsPage: Hashable, Sendable {
    public var items: [WorkItem]
    /// how many issues GitLab has for the slot, all pages together
    public var count: Int
    /// the cursor of the next page; `nil` on the last one
    public var nextCursor: String?
    /// the weight of every issue under each epic of the page, open and closed, in any slot, by the epic's reference;
    /// empty when not asked for (SLOT-11)
    public var epicWeights: [String: Int]

    public init(items: [WorkItem], count: Int, nextCursor: String? = nil, epicWeights: [String: Int] = [:]) {
        self.items = items
        self.count = count
        self.nextCursor = nextCursor
        self.epicWeights = epicWeights
    }
}

extension GitLabOperation where Value == SlotItemsPage {
    /// One page of the issues of a group and its subgroups that carry any of the labels, open and closed: a slot's
    /// issues, by its scheduled slot label (SLOT-06). Each comes with its weight, assignees, epic, blocked flag and due
    /// date, and the epic with the weight under it. A group GitLab doesn't know is an error.
    ///
    /// - Parameters:
    ///   - group: the group's full path
    ///   - labels: the labels, any of which an issue has
    ///   - after: the cursor of the page before; `nil` for the first page
    ///   - epicWeights: whether to ask for the weight under each epic (`descendantWeightSum`, taken from GitLab's
    ///     docs); a GitLab that refuses it is asked again without
    /// - Returns: the operation
    public static func slotItems(
        group: String, labels: [String], after: String? = nil, epicWeights: Bool = true
    ) -> GitLabOperation {
        let weights = epicWeights ? " descendantWeightSum { openedIssues closedIssues }" : ""
        return GitLabOperation(
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
                        epic { reference(full: true) title webUrl state labels(first: 30) { nodes { title color } }\(weights) }
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
                var weights: [String: Int] = [:]
                for epic in issues.nodes.nodes.compactMap(\.epic) {
                    if let sum = epic.descendantWeightSum {
                        weights[epic.reference] = (sum.openedIssues ?? 0) + (sum.closedIssues ?? 0)
                    }
                }
                return SlotItemsPage(
                    items: issues.nodes.nodes.map(\.workItem), count: issues.count,
                    nextCursor: issues.pageInfo.hasNextPage ? issues.pageInfo.endCursor : nil, epicWeights: weights)
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
        var descendantWeightSum: Weights?
    }

    struct Weights: Decodable {
        var openedIssues: Int?
        var closedIssues: Int?
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

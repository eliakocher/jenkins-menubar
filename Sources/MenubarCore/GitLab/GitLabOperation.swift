import Foundation

/// A typed GraphQL operation: its name, its query, its variables, and how its answer becomes a value.
///
/// The queries are the old tool's (`plugins/jenkins.30s.sh`), so the requests stay the ones GitLab already answers.
/// Send one with ``GitLabClient/send(_:)``:
///
/// ```swift
/// let merged = try await client.send(.mergedMergeRequests(project: "group/project", iids: [12, 14]))
/// ```
public struct GitLabOperation<Value: Sendable>: Sendable {
    /// the operation name, as the query names it and the logs show it, like `WorkItems`
    public let name: String
    /// the GraphQL document
    public let query: String
    /// the variables as JSON text, keys in the order written here
    public let variables: String
    /// the value of an answer with HTTP 2xx; throws ``GitLabError`` for a known problem, any other error when the
    /// answer has no value
    let decode: @Sendable (Data) throws -> Value
    /// the problem of an answer without a value, from its HTTP status and GraphQL error messages
    let failure: @Sendable (_ status: Int, _ errors: [String]) -> Problem

    init(
        name: String,
        query: String,
        variables: GraphQLValue = .object([]),
        decode: @escaping @Sendable (Data) throws -> Value,
        failure: @escaping @Sendable (_ status: Int, _ errors: [String]) -> Problem = { status, _ in .httpStatus(.gitLab, status: status) }
    ) {
        self.name = name
        self.query = query
        self.variables = variables.json
        self.decode = decode
        self.failure = failure
    }

    /// the request body, `{"query": …, "variables": …}`
    var body: String {
        "{\"query\":\(GraphQLValue.string(query).json),\"variables\":\(variables)}"
    }
}

// MARK: - The operations

extension GitLabOperation where Value == String {
    /// My GitLab username, which finds my Jenkins jobs (PIPE-01) and checks the token. A 200 without `currentUser`
    /// is a rejected token (MR-05).
    public static var currentUser: GitLabOperation {
        GitLabOperation(
            name: "CurrentUser",
            query: "query CurrentUser { currentUser { username } }",
            decode: { body in
                guard let username = try GraphQLAnswer<CurrentUserShape>.decode(body).data?.currentUser?.username else {
                    throw GitLabError(.rejectedToken(.gitLab))
                }
                return username
            },
            failure: signedInFailure)
    }

    /// The GitLab version, like `19.3.6-ee`. GitLab answers without `metadata` when it doesn't take the token, so that
    /// is a rejected token too.
    public static var metadata: GitLabOperation {
        GitLabOperation(
            name: "Metadata",
            query: "query Metadata { metadata { version } }",
            decode: { body in
                guard let version = try GraphQLAnswer<MetadataShape>.decode(body).data?.metadata?.version else {
                    throw GitLabError(.rejectedToken(.gitLab))
                }
                return version
            },
            failure: signedInFailure)
    }
}

extension GitLabOperation where Value == [Int] {
    /// Which of these MRs are merged, for hiding their builds (HIDE-03).
    ///
    /// - Parameters:
    ///   - project: the project's full path, like `group/project`
    ///   - iids: the iids of the MR jobs; the caller asks nothing without any
    /// - Returns: the operation, whose value is the merged iids, ascending
    public static func mergedMergeRequests(project: String, iids: [Int]) -> GitLabOperation {
        GitLabOperation(
            name: "MergedMergeRequests",
            query: """
                query MergedMergeRequests($path: ID!, $iids: [String!]) {
                  project(fullPath: $path) { mergeRequests(iids: $iids, state: merged) { nodes { iid } } }
                }
                """,
            variables: .object([("path", .string(project)), ("iids", .list(iids.map { .string(String($0)) }))]),
            decode: { body in
                try GraphQLAnswer<MergedShape>.value(of: body).project.mergeRequests.nodes.compactMap { Int($0.iid) }.sorted()
            })
    }
}

extension GitLabOperation where Value == MergeRequestList {
    /// My open MRs, 50 per list: authored, assigned, and those whose review is asked of me (MR-01). A 200 without
    /// `currentUser` is a rejected token (MR-05).
    public static var mergeRequests: GitLabOperation {
        GitLabOperation(
            name: "MergeRequests",
            query: """
                fragment item on MergeRequest {
                  iid
                  title
                  webUrl
                  draft
                  reference(full: true)
                  updatedAt
                  detailedMergeStatus
                  sourceBranch
                  author { username name }
                  headPipeline { status }
                  diffStatsSummary { additions deletions fileCount }
                  reviewers { nodes { username name mergeRequestInteraction { reviewState approved } } }
                }

                query MergeRequests {
                  currentUser {
                    username
                    authored: authoredMergeRequests(state: opened, first: 50) { nodes { ...item } }
                    assigned: assignedMergeRequests(state: opened, first: 50) { nodes { ...item } }
                    reviewing: reviewRequestedMergeRequests(state: opened, first: 50) { nodes { ...item } }
                  }
                }
                """,
            decode: { body in
                guard let user = try GraphQLAnswer<MergeRequestsShape>.decode(body).data?.currentUser else {
                    throw GitLabError(.rejectedToken(.gitLab))
                }
                return user.list
            },
            failure: signedInFailure)
    }
}

extension GitLabOperation where Value == WorkItemLists {
    /// The work items of the filters: the committed ones apart from the others, so the sort and the limit never push
    /// them out (WI-01). Any GraphQL error fails it, with the first message; another failure is "Work items request
    /// failed (HTTP N)" (MR-05).
    ///
    /// - Parameter variables: the variables, from ``WorkItemQuery/variables(preferences:project:me:)``
    /// - Returns: the operation
    public static func workItems(_ variables: WorkItemQuery.Variables) -> GitLabOperation {
        GitLabOperation(
            name: "WorkItems",
            query: """
                fragment item on Issue {
                  title
                  webUrl
                  reference(full: true)
                  updatedAt
                  type
                  state
                  labels(first: 30) { nodes { title color } }
                  author { username name }
                  assignees(first: 10) { nodes { username name } }
                }

                query WorkItems($assignee: [String!], $author: String, $types: [IssueType!], $state: IssuableState, $sort: IssueSort,
                      $withCommitted: Boolean!, $committedLabels: [String], $committedOr: UnionedIssueFilterInput,
                      $committedNot: NegatedIssueFilterInput, $withOthers: Boolean!, $otherLabels: [String],
                      $otherOr: UnionedIssueFilterInput, $otherNot: NegatedIssueFilterInput, $first: Int) {
                  committed: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
                      labelName: $committedLabels, or: $committedOr, not: $committedNot, sort: $sort, first: 50) @include(if: $withCommitted) {
                    count
                    nodes { ...item }
                  }
                  others: issues(assigneeUsernames: $assignee, authorUsername: $author, types: $types, state: $state,
                      labelName: $otherLabels, or: $otherOr, not: $otherNot, sort: $sort, first: $first) @include(if: $withOthers) {
                    count
                    nodes { ...item }
                  }
                }
                """,
            variables: variables.graphQLValue,
            decode: { body in
                let answer = try GraphQLAnswer<WorkItemsShape>.decode(body)
                if let errors = answer.errors, !errors.isEmpty {
                    throw GitLabError(.graphQLErrors(messages: errors.map(\.message)))
                }
                guard let data = answer.data else { throw GitLabError(.workItemsFailed(status: 200)) }
                return WorkItemLists(committed: data.committed?.list, others: data.others?.list)
            },
            failure: { status, errors in
                errors.isEmpty ? .workItemsFailed(status: status) : .graphQLErrors(messages: errors)
            })
    }
}

extension GitLabOperation where Value == [Label] {
    /// GitLab's labels of the project and its groups whose title, or description, contains the text (WI-06).
    ///
    /// - Parameters:
    ///   - project: the project's full path
    ///   - searchTerm: the text
    /// - Returns: the operation, whose value is at most 100 labels with their colors
    public static func labels(project: String, searchTerm: String) -> GitLabOperation {
        GitLabOperation(
            name: "Labels",
            query: """
                query Labels($path: ID!, $term: String!) {
                  project(fullPath: $path) { labels(searchTerm: $term, includeAncestorGroups: true, first: 100) { nodes { title color } } }
                }
                """,
            variables: .object([("path", .string(project)), ("term", .string(searchTerm))]),
            decode: { body in
                try GraphQLAnswer<LabelsShape>.value(of: body).project.labels.nodes.map(\.label)
            })
    }
}

extension GitLabOperation where Value == [RelatedMergeRequest] {
    /// The MRs that mention a work item, 10 at most (WI-05). GitLab resolves them for one work item per request.
    ///
    /// - Parameter workItem: the work item
    /// - Returns: the operation, or `nil` for an epic or a reference without an iid, which aren't asked
    public static func relatedMergeRequests(of workItem: WorkItem) -> GitLabOperation? {
        guard !workItem.isEpic, let sign = workItem.reference.lastIndex(of: "#"), let iid = workItem.iid else { return nil }
        let path = String(workItem.reference[..<sign])
        return GitLabOperation(
            name: "RelatedMergeRequests",
            query: """
                query RelatedMergeRequests($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    issue(iid: $iid) {
                      relatedMergeRequests(first: 10) { nodes { iid state title webUrl reference(full: true) } }
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                try GraphQLAnswer<RelatedShape>.value(of: body).project.issue.relatedMergeRequests.nodes.compactMap { node in
                    Int(node.iid).map {
                        RelatedMergeRequest(iid: $0, state: .init(rawValue: node.state), title: node.title, webURL: node.webUrl,
                                            reference: node.reference)
                    }
                }
            })
    }
}

/// A 200 without the signed-in user's data is a rejected token (MR-05), whatever else the answer says.
private let signedInFailure: @Sendable (Int, [String]) -> Problem = { status, _ in
    (200..<300).contains(status) ? .rejectedToken(.gitLab) : .httpStatus(.gitLab, status: status)
}

// MARK: - Results

/// The answer of ``GitLabOperation/mergeRequests``: my username and my open MRs, each once.
public struct MergeRequestList: Codable, Hashable, Sendable {
    /// my GitLab username, as the answer names it
    public var username: String
    /// the MRs of the three lists, each once by its URL with all its roles, in the order GitLab sent them
    public var mergeRequests: [MergeRequest]

    public init(username: String, mergeRequests: [MergeRequest]) {
        self.username = username
        self.mergeRequests = mergeRequests
    }
}

/// The answer of ``GitLabOperation/workItems(_:)``.
public struct WorkItemLists: Codable, Hashable, Sendable {
    /// the work items with the committed label; `nil` when they weren't asked for (WI-01)
    public var committed: WorkItemList?
    /// the other work items; `nil` when they weren't asked for (WI-01)
    public var others: WorkItemList?

    public init(committed: WorkItemList? = nil, others: WorkItemList? = nil) {
        self.committed = committed
        self.others = others
    }

    /// the work items of both lists, committed first
    public var all: [WorkItem] {
        (committed?.items ?? []) + (others?.items ?? [])
    }
}

/// One list of work items, with how many GitLab has.
public struct WorkItemList: Codable, Hashable, Sendable {
    /// how many work items match, which can be more than `items` holds
    public var count: Int
    public var items: [WorkItem]

    public init(count: Int, items: [WorkItem]) {
        self.count = count
        self.items = items
    }
}

// MARK: - Decoding

/// A GraphQL answer, `{"data": …, "errors": […]}`.
struct GraphQLAnswer<Shape: Decodable>: Decodable {
    var data: Shape?
    var errors: [Message]?

    struct Message: Decodable {
        var message: String
    }

    /// Decodes an answer. GitLab's times are ISO 8601, with or without fractions of a second.
    static func decode(_ body: Data) throws -> GraphQLAnswer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle().parse(text))
                ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return try decoder.decode(GraphQLAnswer.self, from: body)
    }

    /// Decodes an answer's data, which must be there.
    static func value(of body: Data) throws -> Shape {
        guard let data = try decode(body).data else {
            throw DecodingError.valueNotFound(Shape.self, .init(codingPath: [], debugDescription: "no data"))
        }
        return data
    }
}

/// A GraphQL connection's `nodes`. A node that doesn't decode is left out, so one odd item doesn't hide the others.
struct Nodes<Node: Decodable>: Decodable {
    var nodes: [Node]

    private enum Key: String, CodingKey {
        case nodes
    }

    private struct Skip: Decodable {}

    init(from decoder: any Decoder) throws {
        var list = try decoder.container(keyedBy: Key.self).nestedUnkeyedContainer(forKey: .nodes)
        var nodes: [Node] = []
        while !list.isAtEnd {
            if let node = try? list.decode(Node.self) {
                nodes.append(node)
            } else {
                _ = try list.decode(Skip.self)
            }
        }
        self.nodes = nodes
    }
}

struct LabelNode: Decodable {
    var title: String
    var color: String?

    var label: Label { Label(title: title, color: color) }
}

private struct CurrentUserShape: Decodable {
    var currentUser: User?

    struct User: Decodable {
        var username: String
    }
}

private struct MetadataShape: Decodable {
    var metadata: Metadata?

    struct Metadata: Decodable {
        var version: String
    }
}

private struct MergedShape: Decodable {
    var project: Project

    struct Project: Decodable {
        var mergeRequests: Nodes<Node>
    }

    struct Node: Decodable {
        var iid: String
    }
}

private struct LabelsShape: Decodable {
    var project: Project

    struct Project: Decodable {
        var labels: Nodes<LabelNode>
    }
}

private struct RelatedShape: Decodable {
    var project: Project

    struct Project: Decodable {
        var issue: Issue
    }

    struct Issue: Decodable {
        var relatedMergeRequests: Nodes<Node>
    }

    struct Node: Decodable {
        var iid: String
        var state: String
        var title: String
        var webUrl: URL
        var reference: String
    }
}

struct MergeRequestsShape: Decodable {
    var currentUser: User?

    struct User: Decodable {
        var username: String
        var authored: Nodes<Node>
        var assigned: Nodes<Node>
        var reviewing: Nodes<Node>

        /// One MR per URL, with the roles of every list it is in.
        var list: MergeRequestList {
            var mergeRequests: [MergeRequest] = []
            var index: [URL: Int] = [:]
            for (role, nodes) in [(MergeRequest.Role.authored, authored), (.assigned, assigned), (.reviewRequested, reviewing)] {
                for node in nodes.nodes {
                    guard let mergeRequest = node.mergeRequest(role: role) else { continue }
                    if let at = index[mergeRequest.webURL] {
                        mergeRequests[at].roles.insert(role)
                    } else {
                        index[mergeRequest.webURL] = mergeRequests.count
                        mergeRequests.append(mergeRequest)
                    }
                }
            }
            return MergeRequestList(username: username, mergeRequests: mergeRequests)
        }
    }

    struct Node: Decodable {
        var iid: String
        var title: String
        var webUrl: URL
        var draft: Bool?
        var reference: String
        var updatedAt: Date
        var detailedMergeStatus: String?
        var sourceBranch: String?
        var author: Author?
        var headPipeline: Pipeline?
        var diffStatsSummary: MergeRequest.DiffStats?
        var reviewers: Nodes<Reviewer>?

        struct Author: Decodable {
            var username: String
            var name: String
        }

        struct Pipeline: Decodable {
            var status: String?
        }

        struct Reviewer: Decodable {
            var username: String
            var name: String?
            var mergeRequestInteraction: Interaction?

            struct Interaction: Decodable {
                var reviewState: String?
                var approved: Bool?
            }
        }

        func mergeRequest(role: MergeRequest.Role) -> MergeRequest? {
            guard let iid = Int(iid) else { return nil }
            return MergeRequest(
                iid: iid,
                title: title,
                webURL: webUrl,
                reference: reference,
                isDraft: draft ?? false,
                mergeStatus: detailedMergeStatus.map(MergeRequest.MergeStatus.init(rawValue:)),
                // GitLab sends no author for a deleted user.
                author: MergeRequest.Person(username: author?.username ?? "", name: author?.name ?? ""),
                reviewers: (reviewers?.nodes ?? []).map {
                    MergeRequest.Reviewer(
                        username: $0.username,
                        name: $0.name ?? "",
                        reviewState: .init(rawValue: $0.mergeRequestInteraction?.reviewState ?? MergeRequest.ReviewState.unreviewed.rawValue),
                        approved: $0.mergeRequestInteraction?.approved ?? false)
                },
                pipelineStatus: headPipeline?.status.map(MergeRequest.PipelineStatus.init(rawValue:)),
                diffStats: diffStatsSummary,
                updatedAt: updatedAt,
                roles: [role],
                sourceBranch: sourceBranch)
        }
    }
}

struct WorkItemsShape: Decodable {
    var committed: List?
    var others: List?

    struct List: Decodable {
        var count: Int
        var nodes: Nodes<Node>

        private enum Key: String, CodingKey {
            case count, nodes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            count = try container.decode(Int.self, forKey: .count)
            nodes = try Nodes(from: decoder)
        }

        var list: WorkItemList {
            WorkItemList(count: count, items: nodes.nodes.map(\.workItem))
        }
    }

    struct Node: Decodable {
        var title: String
        var webUrl: URL
        var reference: String
        var updatedAt: Date
        /// `nil` from GitLab for some items, and from the old tool's answers, which didn't ask for it
        var type: String?
        var state: String?
        var labels: Nodes<LabelNode>?
        /// `nil` for a deleted user, and in the old tool's answers, as are the assignees
        var author: Person?
        var assignees: Nodes<Person>?

        struct Person: Decodable {
            var username: String
            var name: String?

            var person: MergeRequest.Person { MergeRequest.Person(username: username, name: name ?? "") }
        }

        var workItem: WorkItem {
            WorkItem(
                reference: reference,
                title: title,
                webURL: webUrl,
                type: type.map(WorkItemType.init(rawValue:)) ?? .issue,
                state: state.map(WorkItemState.init(rawValue:)) ?? .opened,
                labels: (labels?.nodes ?? []).map(\.label),
                updatedAt: updatedAt,
                author: author?.person,
                assignees: assignees.map { $0.nodes.map(\.person) })
        }
    }
}

// MARK: - Variables

/// A GraphQL variable value that keeps its keys in the order written, so a request logs the same way every time
/// (`JSONEncoder` changes the order of keys from one run to the next).
enum GraphQLValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case list([GraphQLValue])
    case object([(String, GraphQLValue)])

    /// the value as compact JSON text
    var json: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .string(let value): Self.quoted(value)
        case .list(let values): "[" + values.map(\.json).joined(separator: ",") + "]"
        case .object(let fields): "{" + fields.map { Self.quoted($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a String can't fail.
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}

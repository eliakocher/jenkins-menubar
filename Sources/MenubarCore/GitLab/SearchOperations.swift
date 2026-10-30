import Foundation

// The queries behind the window's "In GitLab" search (WIN-07): merge requests and work items beyond my lists, found by
// their title in the team's groups and projects. Written from GitLab's GraphQL documentation (`Group.mergeRequests`,
// `Group.issues`, `Project.mergeRequests`, `Project.issues`, each with `search`, `state` and `sort`); never run against a
// real GitLab.

/// What a search of GitLab looks for.
public enum GitLabSearchKind: Hashable, Sendable {
    case mergeRequest
    case workItem
}

/// A merge request or work item that GitLab found, with what a row shows. It isn't loaded: opening it under "Opened"
/// loads the item itself (WIN-06).
public struct GitLabSearchHit: Hashable, Identifiable, Sendable {
    public var kind: GitLabSearchKind
    /// the project's full path, like `group/project`
    public var project: String
    public var iid: Int
    /// the full reference, like `group/project!12` or `group/project#7`
    public var reference: String
    public var title: String
    public var webURL: URL
    /// GitLab's state in lowercase: `opened`, `merged`, `closed` or `locked`
    public var state: String
    public var isDraft: Bool
    /// a work item's type as GitLab names it, like `TASK`; `nil` for a merge request
    public var type: String?
    /// the author's name, else `@username`; empty for a deleted user
    public var author: String
    public var updatedAt: Date

    public init(
        kind: GitLabSearchKind, reference: String, title: String, webURL: URL, state: String, isDraft: Bool = false,
        type: String? = nil, author: String = "", updatedAt: Date
    ) {
        self.kind = kind
        self.reference = reference
        self.title = title
        self.webURL = webURL
        self.state = state.lowercased()
        self.isDraft = isDraft
        self.type = type
        self.author = author
        self.updatedAt = updatedAt
        let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" })
        project = sign.map { String(reference[..<$0]) } ?? ""
        iid = sign.flatMap { Int(reference[reference.index(after: $0)...]) } ?? 0
    }

    /// the reference in lowercase, which is what the lists' rows are compared by
    public var id: String { reference.lowercased() }

    /// the short form a row starts with: `!12` or `#7`
    public var shortReference: String { "\(kind == .mergeRequest ? "!" : "#")\(String(iid))" }

    public var isOpen: Bool { state == "opened" }

    /// "Open", "Merged", "Closed"
    public var stateText: String { isOpen ? "Open" : state.capitalized }
}

extension GitLabOperation where Value == [GitLabSearchHit] {
    /// Merge requests whose title or description contains the text, in the given groups (with their subgroups) and
    /// projects, whoever's they are and in any state: the 20 open ones that changed last, and the 20 that changed last of
    /// any state, merged by the caller.
    ///
    /// A path that isn't a group, or isn't a project, or that the token can't see, answers `null` and is left out.
    ///
    /// - Parameters:
    ///   - text: the text to find
    ///   - groups: full paths of groups
    ///   - projects: full paths of projects
    /// - Returns: the operation, whose value is the merge requests of all scopes, each once, in no particular order
    public static func searchMergeRequests(text: String, groups: [String], projects: [String]) -> GitLabOperation {
        search(
            name: "SearchMergeRequests", text: text, groups: groups, projects: projects, connection: "mergeRequests",
            type: "MergeRequest", fields: "draft", states: ("opened", "all"), kind: .mergeRequest)
    }

    /// Issues and tasks whose title or description contains the text, in the given groups (with their subgroups) and
    /// projects, in any state and whoever's they are. Epics live in groups and aren't searched.
    ///
    /// - Parameters:
    ///   - text: the text to find
    ///   - groups: full paths of groups
    ///   - projects: full paths of projects
    /// - Returns: the operation, whose value is the work items of all scopes, each once, in no particular order
    public static func searchWorkItems(text: String, groups: [String], projects: [String]) -> GitLabOperation {
        search(
            name: "SearchWorkItems", text: text, groups: groups, projects: projects, connection: "issues", type: "Issue",
            fields: "type", states: ("opened", "all"), kind: .workItem)
    }

    private static func search(
        name: String, text: String, groups: [String], projects: [String], connection: String, type: String, fields: String,
        states: (String, String), kind: GitLabSearchKind
    ) -> GitLabOperation {
        var declarations = ["$search: String!"]
        var variables: [(String, GraphQLValue)] = [("search", .string(text))]
        var scopes: [String] = []
        for (prefix, field, paths) in [("g", "group", groups), ("p", "project", projects)] {
            for (index, path) in paths.enumerated() {
                let variable = "\(prefix)\(index)"
                declarations.append("$\(variable): ID!")
                variables.append((variable, .string(path)))
                // Only a group takes `includeSubgroups`.
                let extra = field == "group" ? "includeSubgroups: true, " : ""
                let arguments = "search: $search, \(extra)sort: UPDATED_DESC, first: 20"
                scopes.append(
                    """
                      \(variable): \(field)(fullPath: $\(variable)) {
                        opened: \(connection)(\(arguments), state: \(states.0)) { nodes { ...hit } }
                        recent: \(connection)(\(arguments), state: \(states.1)) { nodes { ...hit } }
                      }
                    """)
            }
        }
        let query = """
            fragment hit on \(type) {
              iid
              title
              webUrl
              reference(full: true)
              state
              \(fields)
              updatedAt
              author { username name }
            }

            query \(name)(\(declarations.joined(separator: ", "))) {
            \(scopes.joined(separator: "\n"))
            }
            """
        return GitLabOperation(
            name: name,
            query: query,
            variables: .object(variables),
            decode: { body in
                let answer = try GraphQLAnswer<[String: SearchScope?]>.decode(body)
                guard let data = answer.data else {
                    throw GitLabError(.graphQLErrors(messages: (answer.errors ?? []).map(\.message)))
                }
                // Errors next to some data (a scope the token can't read) don't spoil the scopes that answered.
                var seen = Set<URL>()
                return data.values.compactMap { $0 }.flatMap { ($0.opened?.nodes ?? []) + ($0.recent?.nodes ?? []) }
                    .compactMap { $0.hit(kind: kind) }.filter { seen.insert($0.webURL).inserted }
            },
            failure: { status, errors in
                errors.isEmpty ? .httpStatus(.gitLab, status: status) : .graphQLErrors(messages: errors)
            })
    }
}

private struct SearchScope: Decodable {
    var opened: Nodes<SearchNode>?
    var recent: Nodes<SearchNode>?
}

private struct SearchNode: Decodable {
    var iid: String
    var title: String
    var webUrl: URL
    var reference: String
    var state: String?
    var draft: Bool?
    var type: String?
    var updatedAt: Date
    var author: Author?

    struct Author: Decodable {
        var username: String
        var name: String?
    }

    func hit(kind: GitLabSearchKind) -> GitLabSearchHit? {
        guard Int(iid) != nil else { return nil }
        let name = author.map { $0.name.flatMap { $0.isEmpty ? nil : $0 } ?? "@\($0.username)" } ?? ""
        return GitLabSearchHit(
            kind: kind, reference: reference, title: title, webURL: webUrl, state: state ?? "opened", isDraft: draft ?? false,
            type: type, author: name, updatedAt: updatedAt)
    }
}

import Foundation

// The queries that load one merge request or work item on demand, for the "Opened" items (WIN-06). They ask for the
// fields of the list queries (`MergeRequests` and `WorkItems`), so the answers become the same `MergeRequest` and
// `WorkItem` values and the detail views work unchanged. Written from GitLab's GraphQL documentation (`Project.mergeRequest`,
// `Project.issue`); never run against a real GitLab.

extension GitLabOperation where Value == MergeRequest {
    /// One merge request of a project, by its iid, whatever its state and whoever's it is.
    ///
    /// The value has no roles: it isn't mine by any list. An answer without the merge request (it doesn't exist, or
    /// the token can't see it) is a failure with a message of its own.
    ///
    /// - Parameters:
    ///   - project: the project's full path, like `group/project`
    ///   - iid: the merge request's number in the project
    /// - Returns: the operation
    public static func mergeRequest(project: String, iid: Int) -> GitLabOperation {
        GitLabOperation(
            name: "OpenedMergeRequest",
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

                query OpenedMergeRequest($path: ID!, $iid: String!) {
                  project(fullPath: $path) { mergeRequest(iid: $iid) { ...item } }
                }
                """,
            variables: .object([("path", .string(project)), ("iid", .string(String(iid)))]),
            decode: { body in
                guard let node = try GraphQLAnswer<OpenedMergeRequestShape>.value(of: body).project?.mergeRequest,
                    var mergeRequest = node.mergeRequest(role: .authored)
                else {
                    throw GitLabError(.graphQLErrors(messages: [OpenedItemMessages.notFound]))
                }
                mergeRequest.roles = []
                return mergeRequest
            },
            failure: OpenedItemMessages.failure)
    }
}

extension GitLabOperation where Value == WorkItem {
    /// One issue or task of a project, by its iid, whatever its state.
    ///
    /// Epics live in groups and aren't asked for. An answer without the item is a failure with a message of its own.
    ///
    /// - Parameters:
    ///   - project: the project's full path, like `group/project`
    ///   - iid: the work item's number in the project
    /// - Returns: the operation
    public static func workItem(project: String, iid: Int) -> GitLabOperation {
        GitLabOperation(
            name: "OpenedWorkItem",
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

                query OpenedWorkItem($path: ID!, $iid: String!) {
                  project(fullPath: $path) { issue(iid: $iid) { ...item } }
                }
                """,
            variables: .object([("path", .string(project)), ("iid", .string(String(iid)))]),
            decode: { body in
                guard let node = try GraphQLAnswer<OpenedWorkItemShape>.value(of: body).project?.issue else {
                    throw GitLabError(.graphQLErrors(messages: [OpenedItemMessages.notFound]))
                }
                return node.workItem
            },
            failure: OpenedItemMessages.failure)
    }
}

private enum OpenedItemMessages {
    static let notFound = "Not found, or your token can't see it"

    /// a 2xx answer that held no item says so; another status is the usual one
    static let failure: @Sendable (Int, [String]) -> Problem = { status, errors in
        if !errors.isEmpty {
            return .graphQLErrors(messages: errors)
        }
        return (200..<300).contains(status) ? .graphQLErrors(messages: [notFound]) : .httpStatus(.gitLab, status: status)
    }
}

private struct OpenedMergeRequestShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: MergeRequestsShape.Node?
    }
}

private struct OpenedWorkItemShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var issue: WorkItemsShape.Node?
    }
}

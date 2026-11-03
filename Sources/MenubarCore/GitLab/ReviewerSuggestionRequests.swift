import Foundation
import Observation

// MARK: - The operations

/// How much of the facts to ask for: `approvalState` belongs to a paid GitLab, and a GitLab without it answers a query
/// that names it with a GraphQL error and no data.
enum ReviewerSuggestionFactsLevel: Sendable {
    case full
    /// without the approval rules
    case basic
}

extension GitLabOperation where Value == ReviewerSuggestionFacts {
    /// What decides the reviewers of a merge request, in one request (MR-15).
    ///
    /// Fields from GitLab's GraphQL reference (checked there, not run against a GitLab by the author):
    /// `MergeRequest.targetBranch`, `author`, `reviewers`, `approvedBy`, `diffStats { path }` and
    /// `approvalState { rules { name type section approvalsRequired approved eligibleApprovers approvedBy } }` with
    /// `ApprovalRule.type` (`REGULAR`, `CODE_OWNER`, `ANY_APPROVER`, `REPORT_APPROVER`) and `UserCore.state`.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - level: how much to ask for
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func reviewerSuggestionFacts(of source: DescriptionSource, level: ReviewerSuggestionFactsLevel = .full) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let rules =
            switch level {
            case .full:
                """
                approvalState {
                        rules {
                          name type section approvalsRequired approved
                          eligibleApprovers { username name state }
                          approvedBy { nodes { username } }
                        }
                      }
                """
            case .basic:
                ""
            }
        return GitLabOperation(
            name: "ReviewerSuggestionFacts",
            query: """
                query ReviewerSuggestionFacts($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequest(iid: $iid) {
                      targetBranch
                      author { username }
                      reviewers { nodes { username } }
                      approvedBy { nodes { username } }
                      diffStats { path }
                      \(rules)
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                guard let node = try GraphQLAnswer<ReviewerSuggestionFactsShape>.value(of: body).project?.mergeRequest else {
                    throw DecodingError.valueNotFound(
                        ReviewerSuggestionFacts.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return node.facts
            })
    }
}

extension GitLabOperation where Value == [ReviewerSuggestionFacts.Person] {
    /// Asks GitLab for users by username, for their names and whether their account is active (MR-15): the owners of
    /// a `CODEOWNERS` file and a squad's members come as usernames only. A name GitLab doesn't know isn't in the answer.
    ///
    /// `Query.users(usernames:)` and `User.state` are from GitLab's GraphQL reference (not run against a GitLab).
    ///
    /// - Parameter usernames: up to 100 usernames; the caller asks nothing without any
    static func users(named usernames: [String]) -> GitLabOperation {
        GitLabOperation(
            name: "ReviewerSuggestionUsers",
            query: """
                query ReviewerSuggestionUsers($usernames: [String!]) {
                  users(usernames: $usernames, first: 100) { nodes { username name state } }
                }
                """,
            variables: .object([("usernames", .list(usernames.map { .string($0) }))]),
            decode: { body in
                try GraphQLAnswer<ReviewerSuggestionUsersShape>.value(of: body).users?.nodes.map(\.person) ?? []
            })
    }
}

extension GitLabOperation where Value == [String] {
    /// Adds reviewers to a merge request without touching the ones it has: GraphQL's `mergeRequestSetReviewers` with
    /// `operationMode: APPEND` (MR-15), the write of the Reviewers card's "Add" on the user's click.
    ///
    /// The input is GitLab's `MergeRequestSetReviewersInput`: `projectPath`, `iid`, `reviewerUsernames` and
    /// `operationMode` (`APPEND`, `REMOVE`, `REPLACE`). Checked in GitLab's reference, never sent to a GitLab by the
    /// author. REST's `PUT /projects/:id/merge_requests/:iid` with `reviewer_ids` replaces the reviewers instead, which
    /// is why GraphQL is used. An answer with `errors` is a failure with GitLab's message.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - usernames: who to add, without `@`
    /// - Returns: the operation, whose value is the merge request's reviewers' usernames afterwards; `nil` for a
    ///   reference without a path or an iid, or without usernames
    static func addReviewers(of source: DescriptionSource, usernames: [String]) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID, !usernames.isEmpty else {
            return nil
        }
        return GitLabOperation(
            name: "MergeRequestAddReviewers",
            query: """
                mutation MergeRequestAddReviewers($input: MergeRequestSetReviewersInput!) {
                  mergeRequestSetReviewers(input: $input) { errors mergeRequest { reviewers { nodes { username } } } }
                }
                """,
            variables: .object([
                (
                    "input",
                    .object([
                        ("projectPath", .string(path)), ("iid", .string(iid)),
                        ("reviewerUsernames", .list(usernames.map { .string($0) })), ("operationMode", .string("APPEND")),
                    ])
                )
            ]),
            decode: { body in
                guard let payload = try GraphQLAnswer<AddReviewersShape>.value(of: body).mergeRequestSetReviewers else {
                    throw DecodingError.valueNotFound(
                        AddReviewersShape.self, .init(codingPath: [], debugDescription: "no payload"))
                }
                if let errors = payload.errors, !errors.isEmpty {
                    throw GitLabError(.graphQLErrors(messages: errors))
                }
                return payload.mergeRequest?.reviewers?.nodes.map(\.username) ?? []
            })
    }
}

struct AddReviewersShape: Decodable {
    var mergeRequestSetReviewers: Payload?

    struct Payload: Decodable {
        var errors: [String]?
        var mergeRequest: Node?
    }

    struct Node: Decodable {
        var reviewers: Nodes<User>?
    }

    struct User: Decodable {
        var username: String
    }
}

struct ReviewerSuggestionUsersShape: Decodable {
    var users: Nodes<User>?

    struct User: Decodable {
        var username: String
        var name: String?
        var state: String?

        var person: ReviewerSuggestionFacts.Person {
            ReviewerSuggestionFacts.Person(username: username, name: name ?? "", isActive: state == nil || state?.lowercased() == "active")
        }
    }
}

/// The shape of the facts answer, and the step from it to the values.
struct ReviewerSuggestionFactsShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: Node?
    }

    struct User: Decodable {
        var username: String
        var name: String?
        var state: String?

        var person: ReviewerSuggestionFacts.Person {
            ReviewerSuggestionFacts.Person(username: username, name: name ?? "", isActive: state == nil || state?.lowercased() == "active")
        }
    }

    struct Node: Decodable {
        var targetBranch: String?
        var author: User?
        var reviewers: Nodes<User>?
        var approvedBy: Nodes<User>?
        var diffStats: [Stat]?
        var approvalState: ApprovalState?

        struct Stat: Decodable {
            var path: String
        }

        struct ApprovalState: Decodable {
            var rules: [Rule]?
        }

        struct Rule: Decodable {
            var name: String?
            var type: String?
            var section: String?
            var approvalsRequired: Int?
            var approved: Bool?
            var eligibleApprovers: [User]?
            var approvedBy: Nodes<User>?
        }

        var facts: ReviewerSuggestionFacts {
            ReviewerSuggestionFacts(
                author: author?.username ?? "", reviewers: (reviewers?.nodes ?? []).map(\.username),
                approvedBy: (approvedBy?.nodes ?? []).map(\.username), targetBranch: targetBranch,
                changedPaths: (diffStats ?? []).map(\.path),
                rules: (approvalState?.rules ?? []).map { rule in
                    ReviewerSuggestionFacts.Rule(
                        name: rule.name ?? "", type: .init(graphQL: rule.type), section: rule.section,
                        approvalsRequired: rule.approvalsRequired ?? 0, isApproved: rule.approved ?? false,
                        approvedBy: (rule.approvedBy?.nodes ?? []).map(\.username),
                        eligible: (rule.eligibleApprovers ?? []).map(\.person))
                })
        }
    }
}

// MARK: - The requests

extension GitLabClient {
    /// The places GitLab looks for a `CODEOWNERS` file, in its order: the root, `docs/`, `.gitlab/` (from GitLab's
    /// Code Owners documentation; the first one found counts).
    static let codeOwnersPaths = ["CODEOWNERS", "docs/CODEOWNERS", ".gitlab/CODEOWNERS"]

    /// Asks which commit a branch is at, which `CODEOWNERS` is cached by: `GET /projects/:path/repository/branches/:name`
    /// (GitLab's REST reference).
    ///
    /// - Parameters:
    ///   - project: the project's full path
    ///   - branch: the branch's name
    /// - Returns: the commit's SHA
    /// - Throws: ``GitLabError`` when GitLab didn't answer, didn't take the request, or sent no commit
    public func branchHead(project: String, branch: String) async throws -> String {
        struct Answer: Decodable {
            var commit: Commit?
            struct Commit: Decodable {
                var id: String
            }
        }
        let url = try repositoryURL(project: project, tail: "branches/\(Self.encode(branch))", query: [])
        let response = try await get(url, operation: "TargetBranchHead")
        guard response.status == 200 else {
            throw GitLabError(.httpStatus(.gitLab, status: response.status))
        }
        guard let sha = (try? JSONDecoder().decode(Answer.self, from: response.body))?.commit?.id else {
            throw GitLabError(.httpStatus(.gitLab, status: 502))
        }
        return sha
    }

    /// Reads a project's `CODEOWNERS` at a commit: `GET /projects/:path/repository/files/:file/raw?ref=` for each of
    /// the places in turn (GitLab's REST reference), the first that exists.
    ///
    /// - Parameters:
    ///   - project: the project's full path
    ///   - ref: a commit's SHA or a branch's name
    /// - Returns: the file's text; `nil` when the project has none
    /// - Throws: ``GitLabError`` when GitLab didn't answer or refused (a 404 only means the file isn't there)
    public func codeOwnersText(project: String, ref: String) async throws -> String? {
        for file in Self.codeOwnersPaths {
            let url = try repositoryURL(
                project: project, tail: "files/\(Self.encode(file))/raw", query: [URLQueryItem(name: "ref", value: ref)])
            let response = try await get(url, operation: "CodeOwnersFile")
            switch response.status {
            case 200: return String(decoding: response.body, as: UTF8.self)
            case 404: continue
            default: throw GitLabError(.httpStatus(.gitLab, status: response.status))
            }
        }
        return nil
    }

    /// Adds reviewers on the user's click (MR-15). See ``GitLabOperation/addReviewers(of:usernames:)``.
    ///
    /// - Parameters:
    ///   - usernames: who to add
    ///   - source: the merge request
    /// - Returns: the reviewers' usernames afterwards
    /// - Throws: ``GitLabError``
    public func addReviewers(_ usernames: [String], to source: DescriptionSource) async throws -> [String] {
        guard let operation = GitLabOperation<[String]>.addReviewers(of: source, usernames: usernames) else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        return try await send(operation)
    }

    private static func encode(_ text: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// `<gitlab>/api/v4/projects/<path>/repository/<tail>`; the project's path is one segment, its slashes encoded
    private func repositoryURL(project: String, tail: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false) else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        components.percentEncodedPath += "/projects/\(Self.encode(project))/repository/\(tail)"
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        return url
    }

    private func get(_ url: URL, operation: String) async throws -> HTTPResponse {
        do {
            return try await transport.send(
                HTTPRequest(
                    method: "GET", url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "*/*"], timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: operation, variables: "{}")))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
    }
}

// MARK: - The store

/// What the Reviewers card knows of the suggestions for a merge request.
public enum ReviewerSuggestionState: Hashable, Sendable {
    /// asked, no answer yet
    case loading
    case loaded(ReviewerSuggestionList)
    /// the message to show with Try Again
    case failed(String)
}

/// Who was added, and why not the others.
public struct AddReviewersOutcome: Hashable, Sendable {
    /// the reviewers the merge request has afterwards; empty on failure
    public var reviewers: [String]
    /// GitLab's message when it refused
    public var failure: String?
    /// whether the token lacks the `api` scope, or GitLab rejected it
    public var needsToken: Bool

    public init(reviewers: [String] = [], failure: String? = nil, needsToken: Bool = false) {
        self.reviewers = reviewers
        self.failure = failure
        self.needsToken = needsToken
    }

    public var succeeded: Bool { failure == nil }
}

/// The suggested reviewers of the merge requests the detail shows, loaded when the Reviewers card asks, never with the
/// list (MR-15). Kept in memory per merge request for its last update; the target branch's `CODEOWNERS` is kept per
/// commit of the branch, so it is read again only after the branch moved.
@Observable @MainActor
public final class ReviewerSuggestionStore {
    private struct Entry {
        var list: ReviewerSuggestionList?
        var updatedAt: Date?
        var isLoading = false
        var failure: String?
    }

    /// a `CODEOWNERS` kept for a commit; `nil` file: the project has none
    private struct KeptOwners: Sendable {
        var file: CodeOwnersFile?
    }

    private let entries = ObservedEntries<String, Entry>()
    @ObservationIgnored private var owners: [String: KeptOwners] = [:]
    @ObservationIgnored private let services: GitLabServices
    /// the facts level this GitLab answers: after one failure for the approval rules, the basic one is asked first
    @ObservationIgnored private var level: ReviewerSuggestionFactsLevel = .full

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what is known of a merge request's suggestions.
    ///
    /// - Parameter mergeRequest: the merge request
    public func state(of mergeRequest: MergeRequest) -> ReviewerSuggestionState? {
        guard let entry = entries[mergeRequest.reference] else {
            return nil
        }
        if entry.isLoading, entry.list == nil {
            return .loading
        }
        if let list = entry.list {
            return .loaded(list)
        }
        return entry.failure.map(ReviewerSuggestionState.failed)
    }

    /// Loads the suggestions of a merge request: unless they are loading, or belong to its last update.
    ///
    /// Without a GitLab token or the team values it asks nothing and fails with the setup message. A failed read of
    /// `CODEOWNERS` or of the users doesn't fail the list: it comes with a note. Cancelling the calling task doesn't
    /// cancel the requests.
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - force: loads again although the suggestions belong to the merge request's last update, as after an add
    public func load(_ mergeRequest: MergeRequest, force: Bool = false) async {
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        if entry.isLoading || (!force && entry.list != nil && (entry.updatedAt.map { $0 >= mergeRequest.updatedAt } ?? false)) {
            return
        }
        entry.isLoading = true
        entry.failure = nil
        entries[key] = entry
        let source = DescriptionSource(mergeRequest)
        let services = services
        let kept = owners
        let level = level
        let computation = await Task { await Self.compute(source, services: services, kept: kept, level: level) }.value
        var finished = entries[key] ?? Entry()
        finished.isLoading = false
        switch computation.result {
        case .success(let list):
            finished.list = list
            finished.updatedAt = mergeRequest.updatedAt
            finished.failure = nil
        case .failure(let message):
            finished.failure = message
        }
        if let (ownersKey, file) = computation.keptOwners {
            owners[ownersKey] = KeptOwners(file: file)
        }
        self.level = computation.level
        entries[key] = finished
    }

    /// Adds reviewers after a click and a confirmation, then loads the suggestions again. The caller loads the merge
    /// request's details again so the Reviewers card shows them.
    ///
    /// - Parameters:
    ///   - usernames: who to add
    ///   - mergeRequest: the merge request
    /// - Returns: the outcome; a failure without a token or the team values
    public func add(_ usernames: [String], to mergeRequest: MergeRequest) async -> AddReviewersOutcome {
        let services = services
        let source = DescriptionSource(mergeRequest)
        let outcome = await Task { () -> AddReviewersOutcome in
            switch await services.session() {
            case .success(let session):
                do {
                    return AddReviewersOutcome(reviewers: try await session.client.addReviewers(usernames, to: source))
                } catch let error as GitLabError {
                    return AddReviewersOutcome(failure: error.description, needsToken: error.looksLikeMissingScope)
                } catch {
                    return AddReviewersOutcome(failure: error.localizedDescription)
                }
            case .failure(let error):
                return AddReviewersOutcome(failure: error.description, needsToken: error.problem == .noToken(.gitLab))
            }
        }.value
        if outcome.succeeded {
            await load(mergeRequest, force: true)
        }
        return outcome
    }

    private struct Computation: Sendable {
        enum Result: Sendable {
            case success(ReviewerSuggestionList)
            case failure(String)
        }

        var result: Result
        var keptOwners: (String, CodeOwnersFile?)?
        var level: ReviewerSuggestionFactsLevel
    }

    private nonisolated static func compute(
        _ source: DescriptionSource, services: GitLabServices, kept: [String: KeptOwners], level: ReviewerSuggestionFactsLevel
    ) async -> Computation {
        let session: GitLabSession
        switch await services.session() {
        case .success(let value): session = value
        case .failure(let error): return Computation(result: .failure(error.description), level: level)
        }
        guard let (project, _) = source.pathAndIID else {
            return Computation(result: .failure("The merge request has no reference"), level: level)
        }
        let client = session.client
        // 1. The facts, and again without the approval rules when this GitLab doesn't know them.
        var usedLevel = level
        var facts: ReviewerSuggestionFacts?
        var failure: GitLabError?
        for attempt in level == .full ? [ReviewerSuggestionFactsLevel.full, .basic] : [.basic] {
            guard let operation = GitLabOperation<ReviewerSuggestionFacts>.reviewerSuggestionFacts(of: source, level: attempt) else {
                break
            }
            do {
                facts = try await client.send(operation)
                usedLevel = attempt
                break
            } catch let error as GitLabError {
                failure = error
                // A rejected token or an unreachable GitLab fails the same without the rules.
                if case .graphQLErrors = error.problem { continue }
                if case .httpStatus = error.problem { continue }
                break
            } catch {
                break
            }
        }
        guard let facts else {
            return Computation(result: .failure(failure?.description ?? "GitLab sent no merge request"), level: level)
        }

        var notes: [String] = []
        var keptOwners: (String, CodeOwnersFile?)?
        // 2. CODEOWNERS, only when GitLab's rules hold no code owner rule.
        var codeOwners: CodeOwnersFile?
        if !facts.rules.contains(where: { $0.type == .codeOwner }), let branch = facts.targetBranch, !facts.changedPaths.isEmpty {
            do {
                let sha = try await client.branchHead(project: project, branch: branch)
                let ownersKey = "\(project)@\(sha)"
                if let hit = kept[ownersKey] {
                    codeOwners = hit.file
                } else {
                    codeOwners = try await client.codeOwnersText(project: project, ref: sha).map(CodeOwnersFile.init(parsing:))
                    keptOwners = (ownersKey, codeOwners)
                }
            } catch let error as GitLabError {
                notes.append("CODEOWNERS couldn't be read: \(error.description)")
            } catch {
                notes.append("CODEOWNERS couldn't be read")
            }
        }

        // 3. The users the owners and the squad name: names and whether their accounts are active.
        let squads = SlotTeams(session.project.team.slotTeams)
        var wanted: [String] = []
        for match in codeOwners?.matches(for: facts.changedPaths) ?? [] {
            for case .user(let username) in match.owners {
                wanted.append(username)
            }
        }
        wanted += (squads?.teams.filter { SlotTeams.contains($0.members, facts.author) } ?? []).flatMap(\.members)
        var seen: Set<String> = []
        let usernames = wanted.filter { seen.insert($0.lowercased()).inserted }
        var people: [ReviewerSuggestionFacts.Person] = []
        var complete = false
        if !usernames.isEmpty {
            do {
                for chunk in stride(from: 0, to: usernames.count, by: 100).map({ Array(usernames[$0..<min($0 + 100, usernames.count)]) }) {
                    people += try await client.send(.users(named: chunk))
                }
                complete = true
            } catch {
                notes.append("The users' names couldn't be read")
            }
        }

        var list = ReviewerSuggester.suggest(
            facts: facts, codeOwners: codeOwners, people: people, peopleAreComplete: complete, squads: squads)
        list.notes = notes
        return Computation(result: .success(list), keptOwners: keptOwners, level: usedLevel)
    }
}

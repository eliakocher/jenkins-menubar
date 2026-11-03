import Foundation
import Observation

/// How the user wants it merged: the Merge card's options (MR-16).
public struct MergeOptions: Hashable, Sendable {
    public var squash: Bool
    public var removeSourceBranch: Bool
    /// the merge commit's message; `nil` takes GitLab's default
    public var commitMessage: String?
    /// the squashed commit's message, when squashing; `nil` takes GitLab's default
    public var squashMessage: String?

    public init(squash: Bool, removeSourceBranch: Bool, commitMessage: String? = nil, squashMessage: String? = nil) {
        self.squash = squash
        self.removeSourceBranch = removeSourceBranch
        self.commitMessage = commitMessage
        self.squashMessage = squashMessage
    }

    /// Returns the options GitLab would take: the project's squash and the merge request's branch choice.
    ///
    /// - Parameter state: the merge state
    public init(defaultsOf state: MergeState) {
        self.init(squash: state.squash.isOn, removeSourceBranch: state.removesSourceBranch)
    }
}

// MARK: - The writes

extension GitLabOperation where Value == Void {
    /// Merges a merge request now, or sets it to auto-merge with a strategy: GraphQL's `mergeRequestAccept` (MR-16).
    ///
    /// The input is GitLab's `MergeRequestAcceptInput`, checked in GitLab's schema: `projectPath`, `iid`, `sha` (the
    /// head the user saw, required), `strategy` (`MergeStrategyEnum`, like `MERGE_WHEN_CHECKS_PASS`; none merges now),
    /// `squash`, `shouldRemoveSourceBranch`, `commitMessage` and `squashCommitMessage` (only when given). An answer with
    /// `errors` is a failure with GitLab's words.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - sha: the head commit the user saw
    ///   - options: the user's options
    ///   - strategy: the auto-merge strategy; `nil` merges now
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func accept(
        _ source: DescriptionSource, sha: String, options: MergeOptions, strategy: String? = nil
    ) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        var input: [(String, GraphQLValue)] = [
            ("projectPath", .string(path)), ("iid", .string(iid)), ("sha", .string(sha)),
            ("squash", .bool(options.squash)), ("shouldRemoveSourceBranch", .bool(options.removeSourceBranch)),
        ]
        if let strategy {
            input.append(("strategy", .string(strategy)))
        }
        if let message = options.commitMessage {
            input.append(("commitMessage", .string(message)))
        }
        if options.squash, let message = options.squashMessage {
            input.append(("squashCommitMessage", .string(message)))
        }
        return GitLabOperation(
            name: strategy == nil ? "MergeRequestAccept" : "MergeRequestAutoMerge",
            query: """
                mutation MergeRequestAccept($input: MergeRequestAcceptInput!) {
                  mergeRequestAccept(input: $input) { errors mergeRequest { state autoMergeEnabled } }
                }
                """,
            variables: .object([("input", .object(input))]),
            decode: { body in try MutationPayloadShape.check(body, field: "mergeRequestAccept") })
    }

    /// Marks a merge request ready, or a draft: GraphQL's `mergeRequestSetDraft` (`projectPath`, `iid`, `draft`).
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - draft: `false` marks it ready
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func setDraft(_ source: DescriptionSource, draft: Bool) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        return GitLabOperation(
            name: "MergeRequestSetDraft",
            query: """
                mutation MergeRequestSetDraft($input: MergeRequestSetDraftInput!) {
                  mergeRequestSetDraft(input: $input) { errors }
                }
                """,
            variables: .object([
                ("input", .object([("projectPath", .string(path)), ("iid", .string(iid)), ("draft", .bool(draft))]))
            ]),
            decode: { body in try MutationPayloadShape.check(body, field: "mergeRequestSetDraft") })
    }
}

/// The `errors` of a mutation's payload, under its field's name.
enum MutationPayloadShape {
    private struct Payload: Decodable {
        var errors: [String]?
    }

    /// Throws GitLab's errors of a payload, or a decoding error without the payload.
    static func check(_ body: Data, field: String) throws {
        let data = try GraphQLAnswer<[String: Payload?]>.value(of: body)
        guard let payload = data[field] ?? nil else {
            throw DecodingError.valueNotFound(Payload.self, .init(codingPath: [], debugDescription: "no \(field)"))
        }
        if let errors = payload.errors, !errors.isEmpty {
            throw GitLabError(.graphQLErrors(messages: errors))
        }
    }
}

extension GitLabClient {
    /// Cancels an auto-merge: `POST …/cancel_merge_when_pipeline_succeeds`, which every 19.x GitLab knows (deprecated in
    /// 19.5), else `POST …/cancel_auto_merge`, its successor since 19.5 (GitLab's REST documentation; GraphQL has no
    /// cancel). The successor is asked only when the old one is gone (HTTP 404 or 405).
    ///
    /// - Parameter source: the merge request
    /// - Throws: ``GitLabError`` with GitLab's words
    public func cancelAutoMerge(_ source: DescriptionSource) async throws {
        do {
            _ = try await mergeREST("POST", "cancel_merge_when_pipeline_succeeds", of: source, operation: "MergeRequestCancelAutoMerge")
        } catch let error as GitLabError {
            guard case .httpStatus(.gitLab, let status) = error.problem, status == 404 || status == 405 else {
                throw error
            }
            _ = try await mergeREST("POST", "cancel_auto_merge", of: source, operation: "MergeRequestCancelAutoMerge")
        }
    }

    /// How many commits the source branch is behind the target: `GET …/merge_requests/:iid` with
    /// `include_diverged_commits_count=true` (REST; GraphQL only says whether it is behind).
    ///
    /// - Parameter source: the merge request
    /// - Returns: the count; `nil` when GitLab doesn't say
    /// - Throws: ``GitLabError``
    func behindCount(of source: DescriptionSource) async throws -> Int? {
        struct Answer: Decodable {
            var divergedCommitsCount: Int?

            private enum CodingKeys: String, CodingKey {
                case divergedCommitsCount = "diverged_commits_count"
            }
        }
        let response = try await mergeREST(
            "GET", nil, query: [URLQueryItem(name: "include_diverged_commits_count", value: "true")], of: source,
            operation: "MergeRequestBehindCount")
        return try? JSONDecoder().decode(Answer.self, from: response.body).divergedCommitsCount
    }

    /// Sends one REST request about a merge request: `<gitlab>/api/v4/projects/<path>/merge_requests/<iid>[/<tail>]`,
    /// the project's path one segment with its slashes encoded. The token is in the header only, and the logs get the
    /// operation's name and no variables.
    private func mergeREST(
        _ method: String, _ tail: String?, query: [URLQueryItem] = [], of source: DescriptionSource, operation: String
    ) async throws -> HTTPResponse {
        guard let (path, iid) = source.pathAndIID, var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false)
        else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let project = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        components.percentEncodedPath += "/projects/\(project)/merge_requests/\(iid)" + (tail.map { "/\($0)" } ?? "")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(
                    method: method, url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                    timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: operation, variables: "{}")))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        guard (200..<300).contains(response.status) else {
            throw GitLabError(Self.restProblem(response))
        }
        return response
    }
}

// MARK: - The store

/// What the Merge card knows of a merge request's merge state, and what its last write did (MR-16).
public struct MergeStateLoad: Hashable, Sendable {
    /// as last loaded; `nil` before an answer
    public var state: MergeState?
    /// whether the last request failed
    public var failed: Bool

    public init(state: MergeState?, failed: Bool = false) {
        self.state = state
        self.failed = failed
    }

    /// asked, with no answer yet
    public static let loading = MergeStateLoad(state: nil)
}

/// What the Merge card's last write is doing, or did (MR-16).
public enum MergeActivity: Hashable, Sendable {
    case idle
    /// on its way; a merge stays here while GitLab merges in the background
    case running(MergeAction)
    case succeeded(MergeAction)
    /// GitLab's words, with whether the token looks like it can't write
    case failed(MergeAction, message: String, needsToken: Bool)

    /// the action on its way, if any
    public var running: MergeAction? {
        if case .running(let action) = self { action } else { nil }
    }
}

/// The merge state of the merge requests the user selected, loaded on selection once per update, and the Merge card's
/// writes (MR-16). Every write runs on the user's click only; after it the state and the details are loaded again.
@Observable @MainActor
public final class MergeRequestMergeStore {
    /// called when a merge started from the app went through, for the fun layer's celebration; ``AppModel`` sets it
    @ObservationIgnored public var onMerged: (@MainActor (MergeRequest) -> Void)?
    private struct Entry {
        var state: MergeState?
        var updatedAt: Date?
        var isLoading = false
        var failed = false
        var activity: MergeActivity = .idle
    }

    private let entries = ObservedEntries<String, Entry>()
    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private var level = MergeStateLevel.full
    /// what else a write refreshes: the details, whose approvals and threads the checks name
    @ObservationIgnored var afterWrite: (@MainActor (MergeRequest) async -> Void)?
    /// how long between two looks at a merge GitLab runs in the background, and how many looks at most
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored var pollLimit = 30

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what is known of a merge request's merge state.
    public func load(of mergeRequest: MergeRequest) -> MergeStateLoad {
        guard let entry = entries[mergeRequest.reference] else {
            return .loading
        }
        return MergeStateLoad(state: entry.state, failed: entry.failed && !entry.isLoading)
    }

    /// Returns what the last write for a merge request is doing, or did.
    public func activity(of mergeRequest: MergeRequest) -> MergeActivity {
        entries[mergeRequest.reference]?.activity ?? .idle
    }

    /// Forgets the outcome of the last write, as the card's close button does.
    public func dismiss(_ mergeRequest: MergeRequest) {
        guard var entry = entries[mergeRequest.reference], entry.activity.running == nil else {
            return
        }
        entry.activity = .idle
        entries[mergeRequest.reference] = entry
    }

    /// Loads the merge state when a merge request is selected: unless it is loading, or was loaded for its last update.
    ///
    /// A GitLab that refuses `mergeabilityChecks` is asked again without them, and from then on without them. When the
    /// branch is behind, GitLab's REST answer adds by how many commits. Cancelling the calling task doesn't cancel the
    /// request.
    ///
    /// - Parameters:
    ///   - mergeRequest: the merge request
    ///   - force: loads again although the state belongs to the last update, as after a write
    public func load(_ mergeRequest: MergeRequest, force: Bool = false) async {
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        if entry.isLoading || (!force && entry.state != nil && (entry.updatedAt.map { $0 >= mergeRequest.updatedAt } ?? false)) {
            return
        }
        entry.isLoading = true
        entries[key] = entry
        let services = services
        let start = level
        let source = DescriptionSource(mergeRequest)
        let answer = await Task { () -> (MergeState, MergeStateLevel)? in
            guard let client = try? await services.session().get().client,
                let full = GitLabOperation<MergeState>.mergeState(of: source, level: start),
                let basic = GitLabOperation<MergeState>.mergeState(of: source, level: .basic)
            else {
                return nil
            }
            var answer: (MergeState, MergeStateLevel)
            do {
                answer = (try await client.send(full), start)
            } catch let error as GitLabError {
                guard start == .full, case .graphQLErrors = error.problem, let state = try? await client.send(basic) else {
                    return nil
                }
                answer = (state, .basic)
            } catch {
                return nil
            }
            if answer.0.isBehind {
                answer.0.behindCount = (try? await client.behindCount(of: source)) ?? nil
            }
            return answer
        }.value
        entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let (state, answered) = answer {
            level = answered
            entry.state = state
            entry.updatedAt = mergeRequest.updatedAt
            entry.failed = false
        } else {
            entry.failed = true
        }
        entries[key] = entry
    }

    /// Runs one of the card's writes, on the user's click: merge, set or cancel auto-merge, mark ready. Then loads the
    /// merge state and the details again; a merge GitLab runs in the background is looked at
    /// until it ends. Nothing runs while another write for the merge request is on its way.
    ///
    /// A merge sends the head commit the card showed, so it never takes commits the user didn't see; without one
    /// nothing is sent.
    ///
    /// - Parameters:
    ///   - action: the write
    ///   - mergeRequest: the merge request
    ///   - options: the user's options, for a merge and an auto-merge
    public func perform(_ action: MergeAction, on mergeRequest: MergeRequest, options: MergeOptions? = nil) async {
        let key = mergeRequest.reference
        var entry = entries[key] ?? Entry()
        guard entry.activity.running == nil else {
            return
        }
        let state = entry.state
        entry.activity = .running(action)
        entries[key] = entry
        let services = services
        let source = DescriptionSource(mergeRequest)
        let options = options ?? state.map(MergeOptions.init(defaultsOf:)) ?? MergeOptions(squash: false, removeSourceBranch: false)
        let failure = await Task { () -> (String, Bool)? in
            let client: GitLabClient
            switch await services.session() {
            case .success(let session): client = session.client
            case .failure(let error): return (error.description, error.problem == .noToken(.gitLab))
            }
            do {
                try await Self.send(action, client: client, source: source, state: state, options: options)
                return nil
            } catch let error as GitLabError {
                // A refusal that can be a token without the `api` scope asks GitLab for the scopes, once per token.
                if await services.tokenIsToBlame(for: error) {
                    return (Problem.readOnlyToken(action: action.title).message, true)
                }
                return (error.description, error.looksLikeMissingScope)
            } catch {
                return (error.localizedDescription, false)
            }
        }.value
        // The state after the write, or after its refusal: a new push, a merge by someone else.
        await load(mergeRequest, force: true)
        if failure == nil {
            await waitForBackgroundWork(mergeRequest)
        }
        await afterWrite?(mergeRequest)
        entry = entries[key] ?? Entry()
        if let (message, needsToken) = failure {
            entry.activity = .failed(action, message: message, needsToken: needsToken)
        } else if action == .merge, entry.state?.lifecycle == .opened, entry.state?.isMerging == false,
            let error = entry.state?.mergeError
        {
            // GitLab took the merge, then failed it in the background.
            entry.activity = .failed(action, message: error, needsToken: false)
        } else {
            entry.activity = .succeeded(action)
            if action == .merge {
                onMerged?(mergeRequest)
            }
        }
        entries[key] = entry
    }

    /// Looks at the merge state until GitLab's merge in the background ends, at most ``pollLimit`` times.
    private func waitForBackgroundWork(_ mergeRequest: MergeRequest) async {
        var looks = 0
        while looks < pollLimit, let state = entries[mergeRequest.reference]?.state, state.isMerging {
            looks += 1
            try? await services.clock.sleep(for: pollInterval)
            await load(mergeRequest, force: true)
        }
    }

    /// Sends one write.
    private nonisolated static func send(
        _ action: MergeAction, client: GitLabClient, source: DescriptionSource, state: MergeState?, options: MergeOptions
    ) async throws {
        switch action {
        case .merge, .setAutoMerge:
            guard let sha = state?.headSHA else {
                throw GitLabError(.graphQLErrors(messages: ["GitLab didn't say which commit is the head: reload, then try again"]))
            }
            let strategy = action == .setAutoMerge ? state?.autoMergeStrategy : nil
            if action == .setAutoMerge, strategy == nil {
                throw GitLabError(.graphQLErrors(messages: ["GitLab offers no auto-merge for this merge request"]))
            }
            guard let operation = GitLabOperation<Void>.accept(source, sha: sha, options: options, strategy: strategy) else {
                throw GitLabError(.httpStatus(.gitLab, status: 404))
            }
            try await client.send(operation)
        case .cancelAutoMerge:
            try await client.cancelAutoMerge(source)
        case .markReady:
            guard let operation = GitLabOperation<Void>.setDraft(source, draft: false) else {
                throw GitLabError(.httpStatus(.gitLab, status: 404))
            }
            try await client.send(operation)
        }
    }
}

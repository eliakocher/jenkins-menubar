import Foundation

// MARK: - The reviews

/// Who reviewed a merge request, when, and when the code last changed: what "Re-request Review" works from (MR-09,
/// MR-10).
///
/// GitLab doesn't say "this review is out of date", so the app compares two times: when the reviewer's state last
/// changed (`mergeRequestInteraction.updatedAt`, the review) and when the merge request last got new code (its newest
/// diff version, and its commits' dates). Without the review's time, nothing is compared and ``Freshness/unknown``
/// stands.
public struct MergeRequestReviews: Hashable, Sendable {
    public var reviewers: [Reviewer]
    /// when the newest diff version was made, which is the last push; `nil` when GitLab sent none
    public var lastPushedAt: Date?
    /// the commit dates of the first commits GitLab sent, to count the commits since a review
    public var commitDates: [Date]

    public init(reviewers: [Reviewer], lastPushedAt: Date? = nil, commitDates: [Date] = []) {
        self.reviewers = reviewers
        self.lastPushedAt = lastPushedAt
        self.commitDates = commitDates
    }

    /// A reviewer, with the review GitLab knows of.
    public struct Reviewer: Hashable, Sendable, Identifiable {
        /// GitLab's global id of the user, like `gid://gitlab/User/42`, which the re-request names
        public var id: String
        public var username: String
        /// the full name; empty when GitLab sent none
        public var name: String
        public var reviewState: MergeRequest.ReviewState
        /// `mergeRequestInteraction.reviewed`
        public var reviewed: Bool
        public var approved: Bool
        /// when the reviewer's state last changed, which for a reviewer who reviewed is the review; `nil` when GitLab
        /// doesn't say (older GitLab, or a review from before it kept the time)
        public var reviewedAt: Date?

        public init(
            id: String, username: String, name: String = "", reviewState: MergeRequest.ReviewState = .unreviewed,
            reviewed: Bool = false, approved: Bool = false, reviewedAt: Date? = nil
        ) {
            self.id = id
            self.username = username
            self.name = name
            self.reviewState = reviewState
            self.reviewed = reviewed
            self.approved = approved
            self.reviewedAt = reviewedAt
        }

        /// whether the reviewer has given a review, which GitLab's own "Re-request review" button needs too
        public var hasReviewed: Bool {
            reviewed || approved || reviewState == .reviewed || reviewState == .approved || reviewState == .requestedChanges
        }

        /// the first name, else "@username": what a sentence about the review calls them
        public var firstName: String {
            name.split(separator: " ").first.map(String.init) ?? "@\(username)"
        }

        /// the name, else "@username"
        public var displayName: String {
            name.isEmpty ? "@\(username)" : name
        }
    }

    /// How a reviewer's review stands against the code.
    public enum Freshness: Hashable, Sendable {
        /// no review yet, or it was asked for again
        case notReviewed
        /// reviewed after the last push
        case current
        /// the code changed after the review: the commits made since (0 when the push added none, like a rebase)
        case stale(newCommits: Int)
        /// reviewed, but GitLab doesn't say when
        case unknown
    }

    /// Returns how a reviewer's review stands.
    ///
    /// The rule: a review is stale when the last push is later than it, or a commit is dated later than it. Equal
    /// times count as current: a push in the same second as the review is more likely the code that was reviewed.
    ///
    /// - Parameter reviewer: the reviewer
    /// - Returns: the freshness
    public func freshness(of reviewer: Reviewer) -> Freshness {
        guard reviewer.hasReviewed else {
            return .notReviewed
        }
        guard let reviewedAt = reviewer.reviewedAt else {
            return .unknown
        }
        let newCommits = commitDates.filter { $0 > reviewedAt }.count
        if newCommits > 0 || (lastPushedAt.map { $0 > reviewedAt } ?? false) {
            return .stale(newCommits: newCommits)
        }
        return .current
    }

    /// The reviewers "Re-request Reviews (N)" asks again: those whose review is stale, and those who reviewed at a time
    /// GitLab doesn't tell, because then nobody can say it is current.
    public var reviewersToAsk: [Reviewer] {
        reviewers.filter {
            switch freshness(of: $0) {
            case .stale, .unknown: true
            case .notReviewed, .current: false
            }
        }
    }

    /// Returns the nudge under a reviewer: "2 new commits since Sam's review", "Updated since Sam's review".
    ///
    /// - Parameter reviewer: the reviewer
    /// - Returns: the sentence; `nil` unless the review is stale
    public func nudge(for reviewer: Reviewer) -> String? {
        guard case .stale(let commits) = freshness(of: reviewer) else {
            return nil
        }
        let possessive = reviewer.firstName.hasSuffix("s") ? "\(reviewer.firstName)'" : "\(reviewer.firstName)'s"
        return commits > 0
            ? "\(commits) new \(commits == 1 ? "commit" : "commits") since \(possessive) review"
            : "Updated since \(possessive) review"
    }

    /// Returns the question the bulk action asks once: "Re-request review from Sam, Kim and 5 others?".
    ///
    /// Up to three names are listed; with more, two names and the count of the others.
    ///
    /// - Parameter reviewers: who would be asked again
    /// - Returns: the question
    public static func confirmation(for reviewers: [Reviewer]) -> String {
        let names = reviewers.map(\.firstName)
        // Joined by hand: a list format puts a comma before the last "and" in some languages.
        let listed: String
        switch names.count {
        case 0, 1: listed = names.first ?? ""
        case 2, 3: listed = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: listed = "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
        return "Re-request review from \(listed)?"
    }
}

// MARK: - What a token may do

/// Whether the stored GitLab token can write, as far as GitLab says: the first write of the app, a re-request, needs the
/// `api` scope, and a token that only has `read_api` reads.
public enum WriteAccess: Hashable, Sendable {
    /// not asked, or GitLab didn't say (an older GitLab, a token that doesn't list its scopes)
    case unknown
    case allowed
    /// the token reads, and can't write
    case readOnly

    /// Returns what a token's scopes say.
    ///
    /// - Parameter scopes: the scopes of `GET /api/v4/personal_access_tokens/self`, like `["read_api"]`
    /// - Returns: ``allowed`` with `api`, ``readOnly`` with other scopes, ``unknown`` with none (a token with granular
    ///   scopes lists none of the classic ones)
    public init(scopes: [String]) {
        if scopes.contains("api") {
            self = .allowed
        } else if scopes.isEmpty {
            self = .unknown
        } else {
            self = .readOnly
        }
    }

    /// "Re-requesting a review needs a GitLab token with the api scope."
    public static let explanation = "Re-requesting a review needs a GitLab token with the api scope."
}

extension GitLabClient {
    /// Asks GitLab which scopes the token has: `GET <gitlab>/api/v4/personal_access_tokens/self`, answered for a token
    /// of any scope (inferred from GitLab's docs; a refusal is an error and counts as not known).
    ///
    /// - Returns: the scopes, like `["read_api"]`
    /// - Throws: ``GitLabError`` when GitLab didn't answer or didn't take the request
    public func tokenScopes() async throws -> [String] {
        struct Answer: Decodable {
            var scopes: [String]?
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(
                    method: "GET", url: restBase.appending(path: "personal_access_tokens/self"),
                    headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"], timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: "TokenScopes", variables: "{}")))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        guard response.status == 200, let scopes = try? JSONDecoder().decode(Answer.self, from: response.body).scopes else {
            throw GitLabError(.httpStatus(.gitLab, status: response.status))
        }
        return scopes
    }
}

// MARK: - The operations

/// How much of the reviews to ask for: `updatedAt` of the interaction and the diff versions are newer fields, and a
/// GitLab without them answers a query that names them with a GraphQL error and no data.
enum MergeRequestReviewsLevel: Sendable {
    case full
    /// the reviewers and their states only; no review is compared with the code
    case basic
}

extension GitLabOperation where Value == MergeRequestReviews {
    /// The reviewers of a merge request with the time of their reviews, the time of the last push and the commit dates
    /// (MR-09).
    ///
    /// Fields from GitLab's GraphQL reference (checked there, not run against a GitLab by the author):
    /// `MergeRequestReviewer.id` and `mergeRequestInteraction { reviewState reviewed approved approvedAt updatedAt }`,
    /// `MergeRequest.mergeRequestDiffs { nodes { createdAt } }` and `commits { nodes { committedDate } }`.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - level: how much to ask for
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func reviews(of source: DescriptionSource, level: MergeRequestReviewsLevel = .full) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let interaction: String
        let code: String
        switch level {
        case .full:
            interaction = "reviewState reviewed approved approvedAt updatedAt"
            code = """
                mergeRequestDiffs(first: 20) { nodes { createdAt } }
                      commits(first: 100) { nodes { committedDate } }
                """
        case .basic:
            interaction = "reviewState reviewed approved"
            code = ""
        }
        return GitLabOperation(
            name: "MergeRequestReviews",
            query: """
                query MergeRequestReviews($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequest(iid: $iid) {
                      reviewers { nodes { id username name mergeRequestInteraction { \(interaction) } } }
                      \(code)
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                guard let node = try GraphQLAnswer<MergeRequestReviewsShape>.value(of: body).project?.mergeRequest else {
                    throw DecodingError.valueNotFound(
                        MergeRequestReviews.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return node.reviews
            })
    }
}

extension GitLabOperation where Value == Void {
    /// Asks a reviewer for a new review: GraphQL's `mergeRequestReviewerRereview`, the first write of the app (MR-09).
    ///
    /// The input is GitLab's `MergeRequestReviewerRereviewInput` (checked in GitLab's reference, not run against a
    /// GitLab by the author): `projectPath`, `iid` and `userId`, the user's global id. An answer with `errors` is a
    /// failure with GitLab's message.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - userID: the reviewer's global id, like `gid://gitlab/User/42`
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func rereview(of source: DescriptionSource, userID: String) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        return GitLabOperation(
            name: "ReviewerRereview",
            query: """
                mutation ReviewerRereview($input: MergeRequestReviewerRereviewInput!) {
                  mergeRequestReviewerRereview(input: $input) { errors }
                }
                """,
            variables: .object([
                ("input", .object([("projectPath", .string(path)), ("iid", .string(iid)), ("userId", .string(userID))]))
            ]),
            decode: { body in
                let answer = try GraphQLAnswer<ReviewerRereviewShape>.value(of: body)
                guard let payload = answer.mergeRequestReviewerRereview else {
                    throw DecodingError.valueNotFound(
                        ReviewerRereviewShape.self, .init(codingPath: [], debugDescription: "no payload"))
                }
                if let errors = payload.errors, !errors.isEmpty {
                    throw GitLabError(.graphQLErrors(messages: errors))
                }
            })
    }
}

struct ReviewerRereviewShape: Decodable {
    var mergeRequestReviewerRereview: Payload?

    struct Payload: Decodable {
        var errors: [String]?
    }
}

/// The shape of the reviews answer, and the step from it to the values.
struct MergeRequestReviewsShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: Node?
    }

    struct Node: Decodable {
        var reviewers: Nodes<Reviewer>?
        var mergeRequestDiffs: Nodes<Diff>?
        var commits: Nodes<Commit>?

        var reviews: MergeRequestReviews {
            MergeRequestReviews(
                reviewers: (reviewers?.nodes ?? []).map(\.reviewer),
                lastPushedAt: mergeRequestDiffs?.nodes.compactMap(\.createdAt).max(),
                commitDates: (commits?.nodes ?? []).compactMap(\.committedDate))
        }
    }

    struct Reviewer: Decodable {
        var id: String
        var username: String
        var name: String?
        var mergeRequestInteraction: Interaction?

        struct Interaction: Decodable {
            var reviewState: String?
            var reviewed: Bool?
            var approved: Bool?
            var approvedAt: Date?
            var updatedAt: Date?
        }

        var reviewer: MergeRequestReviews.Reviewer {
            .init(
                id: id, username: username, name: name ?? "",
                reviewState: .init(rawValue: mergeRequestInteraction?.reviewState ?? MergeRequest.ReviewState.unreviewed.rawValue),
                reviewed: mergeRequestInteraction?.reviewed ?? false, approved: mergeRequestInteraction?.approved ?? false,
                reviewedAt: mergeRequestInteraction?.updatedAt ?? mergeRequestInteraction?.approvedAt)
        }
    }

    struct Diff: Decodable {
        var createdAt: Date?
    }

    struct Commit: Decodable {
        var committedDate: Date?
    }
}

// MARK: - The re-request

/// What a run of re-requests did: who was asked, who couldn't be, and whether the token was the reason (MR-09, MR-10).
public struct ReReviewOutcome: Hashable, Sendable {
    /// the reviewers GitLab took the request for
    public var sent: [MergeRequestReviews.Reviewer]
    /// the reviewers it failed for, with GitLab's words
    public var failures: [Failure]
    /// whether a failure looks like a token without the `api` scope; the rest of the reviewers weren't tried then
    public var needsToken: Bool

    public init(sent: [MergeRequestReviews.Reviewer] = [], failures: [Failure] = [], needsToken: Bool = false) {
        self.sent = sent
        self.failures = failures
        self.needsToken = needsToken
    }

    public struct Failure: Hashable, Sendable {
        public var reviewer: MergeRequestReviews.Reviewer
        public var message: String

        public init(reviewer: MergeRequestReviews.Reviewer, message: String) {
            self.reviewer = reviewer
            self.message = message
        }
    }

    /// whether everyone was asked
    public var isComplete: Bool { failures.isEmpty }
}

extension GitLabError {
    /// Whether a refusal looks like a token that can't write: GitLab's `insufficient_scope`, a rejected token, or an
    /// answer that names the scope (the exact answer to a mutation with a `read_api` token isn't verified).
    var looksLikeMissingScope: Bool {
        switch problem {
        case .missingScope, .rejectedToken(.gitLab): true
        case .graphQLErrors(let messages): messages.contains { $0.localizedCaseInsensitiveContains("scope") }
        default: false
        }
    }
}

extension GitLabClient {
    /// Asks each reviewer for a new review, one request after the other, never again after a failure.
    ///
    /// A failure that looks like a token without the `api` scope stops the run, because every other request would get
    /// the same answer: the reviewers after it aren't tried and aren't listed as failed.
    ///
    /// - Parameters:
    ///   - reviewers: who to ask
    ///   - source: the merge request
    /// - Returns: who was asked and who failed
    public func reRequest(_ reviewers: [MergeRequestReviews.Reviewer], of source: DescriptionSource) async -> ReReviewOutcome {
        var outcome = ReReviewOutcome()
        for reviewer in reviewers {
            guard !Task.isCancelled else {
                break
            }
            guard let operation = GitLabOperation<Void>.rereview(of: source, userID: reviewer.id) else {
                outcome.failures.append(.init(reviewer: reviewer, message: "The merge request has no reference"))
                continue
            }
            do {
                try await send(operation)
                outcome.sent.append(reviewer)
            } catch let error as GitLabError {
                outcome.failures.append(.init(reviewer: reviewer, message: error.description))
                if error.looksLikeMissingScope {
                    outcome.needsToken = true
                    break
                }
            } catch {
                outcome.failures.append(.init(reviewer: reviewer, message: error.localizedDescription))
            }
        }
        return outcome
    }

    /// Asks for the reviews of a merge request; the reviewers alone when GitLab doesn't know the newer fields.
    ///
    /// - Parameter source: the merge request
    /// - Returns: the reviews; `nil` when GitLab answered neither
    func reviews(of source: DescriptionSource) async -> MergeRequestReviews? {
        guard let full = GitLabOperation<MergeRequestReviews>.reviews(of: source),
            let basic = GitLabOperation<MergeRequestReviews>.reviews(of: source, level: .basic)
        else {
            return nil
        }
        do {
            return try await send(full)
        } catch let error as GitLabError {
            guard case .graphQLErrors = error.problem else {
                return nil
            }
            return try? await send(basic)
        } catch {
            return nil
        }
    }
}

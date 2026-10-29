import Foundation
import Testing

@testable import MenubarCore

/// Re-requesting a review, the app's first GitLab write (MR-09, MR-10): which reviews are stale, the scope the token
/// needs, the mutation's request and a run of requests that reports the ones that failed.
@Suite("Re-request review")
@MainActor
struct ReviewerRereviewTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)

    private nonisolated static var mergeRequest: MergeRequest {
        MergeRequest(
            iid: 16, title: "Add a retry", webURL: source.webURL, reference: source.reference,
            author: .init(username: "me", name: "Jane Doe"), updatedAt: updatedAt, roles: [.authored])
    }

    private nonisolated static func client(_ stub: StubTransport) -> GitLabClient {
        GitLabClient(transport: stub, gitLab: gitLab, token: "glpat-test")
    }

    private nonisolated static func reviewer(_ number: Int, _ username: String, name: String = "", reviewedAt: Date? = nil,
                                             state: MergeRequest.ReviewState = .reviewed) -> MergeRequestReviews.Reviewer {
        .init(id: "gid://gitlab/User/\(number)", username: username, name: name, reviewState: state,
              reviewed: state != .unreviewed, reviewedAt: reviewedAt)
    }

    private nonisolated static func time(_ hour: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(hour) * 3600)
    }

    // MARK: - The stale rule

    @Test("MR-09 a review is stale when the code changed after it", arguments: [
        // (reviewed at, last push, commit hours, expected)
        (4, 3 as Int?, [1, 2], MergeRequestReviews.Freshness.current),
        (4, 5 as Int?, [1, 5], .stale(newCommits: 1)),
        (4, 5 as Int?, [1, 5, 6], .stale(newCommits: 2)),
        // a push without a new commit, like a rebase
        (4, 6 as Int?, [1, 2], .stale(newCommits: 0)),
        // the same second counts as seen
        (4, 4 as Int?, [4], .current),
        // GitLab sent no diff versions: only the commits tell
        (4, nil, [1, 2], .current),
        (4, nil, [7], .stale(newCommits: 1)),
    ])
    func staleRule(reviewedAt: Int, lastPush: Int?, commits: [Int], expected: MergeRequestReviews.Freshness) {
        let reviews = MergeRequestReviews(
            reviewers: [], lastPushedAt: lastPush.map(Self.time), commitDates: commits.map(Self.time))

        #expect(reviews.freshness(of: Self.reviewer(1, "slee", reviewedAt: Self.time(reviewedAt))) == expected)
    }

    @Test("MR-09 a review without a time is unknown, and who didn't review is not reviewed")
    func unknownAndNotReviewed() {
        let reviews = MergeRequestReviews(reviewers: [], lastPushedAt: Self.time(9), commitDates: [Self.time(9)])

        #expect(reviews.freshness(of: Self.reviewer(1, "slee")) == .unknown)
        #expect(reviews.freshness(of: Self.reviewer(2, "akim", reviewedAt: Self.time(1), state: .unreviewed)) == .notReviewed)
        // An approval counts as a review even when GitLab's `reviewed` says false.
        let approved = MergeRequestReviews.Reviewer(id: "gid://gitlab/User/3", username: "rmeyer", reviewState: .approved, reviewed: false)
        #expect(approved.hasReviewed)
    }

    @Test("MR-10 the bulk action asks the stale reviews, and those whose time is unknown, not the current or the missing")
    func reviewersToAsk() {
        let slee = Self.reviewer(1, "slee", reviewedAt: Self.time(1))
        let current = Self.reviewer(2, "akim", reviewedAt: Self.time(8))
        let unknown = Self.reviewer(3, "rmeyer")
        let missing = Self.reviewer(4, "cnovak", state: .unreviewed)
        let reviews = MergeRequestReviews(reviewers: [slee, current, unknown, missing], lastPushedAt: Self.time(5))

        #expect(reviews.reviewersToAsk.map(\.username) == ["slee", "rmeyer"])
    }

    @Test("MR-09 the nudge counts the commits since the review")
    func nudge() {
        let reviews = MergeRequestReviews(reviewers: [], lastPushedAt: Self.time(7), commitDates: [Self.time(6), Self.time(7)])
        let sam = Self.reviewer(1, "slee", name: "Sam Lee", reviewedAt: Self.time(4))
        let chris = Self.reviewer(2, "cnovak", name: "Chris Novak", reviewedAt: Self.time(6))
        let alex = Self.reviewer(3, "akim", name: "Alex Kim", reviewedAt: Self.time(8))
        let rebase = MergeRequestReviews(reviewers: [], lastPushedAt: Self.time(7))

        #expect(reviews.nudge(for: sam) == "2 new commits since Sam's review")
        #expect(reviews.nudge(for: chris) == "1 new commit since Chris' review")
        #expect(reviews.nudge(for: alex) == nil)
        #expect(rebase.nudge(for: sam) == "Updated since Sam's review")
        #expect(reviews.nudge(for: Self.reviewer(4, "rmeyer", state: .unreviewed)) == nil)
    }

    @Test("MR-10 the confirmation names the reviewers and counts the others", arguments: [
        (["Sam Lee", "Kim Ito"], "Re-request review from Sam and Kim?"),
        (["Sam Lee", "Kim Ito", "Lee Wong"], "Re-request review from Sam, Kim and Lee?"),
        (["Sam Lee", "Kim Ito", "Lee Wong", "Ana Silva", "Bo Chen", "Cy Young", "Di Prince"], "Re-request review from Sam, Kim and 5 others?"),
    ])
    func confirmation(names: [String], expected: String) {
        let reviewers = names.enumerated().map { Self.reviewer($0.offset, "user\($0.offset)", name: $0.element) }

        #expect(MergeRequestReviews.confirmation(for: reviewers) == expected)
    }

    // MARK: - Reading the reviews

    @Test("MR-09 reads the reviewers' ids and times, the last push and the commit dates")
    func readsReviews() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestReviews", body: try FixtureFiles.string("GitLab/merge-request-reviews.json"))

        let reviews = try #require(await Self.client(stub).reviews(of: Self.source))

        #expect(reviews.reviewers.map(\.id) == ["gid://gitlab/User/11", "gid://gitlab/User/12", "gid://gitlab/User/13"])
        #expect(reviews.reviewers.map(\.hasReviewed) == [true, true, false])
        // The review of someone who approved has the approval's time, which has fractions of a second.
        #expect(reviews.reviewers[1].reviewedAt != nil)
        #expect(reviews.reviewers[2].reviewedAt == nil)
        // The newest of the diff versions, whatever their order.
        #expect(reviews.lastPushedAt == ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        #expect(reviews.commitDates.count == 3)
        #expect(reviews.nudge(for: reviews.reviewers[0]) == "2 new commits since Sam's review")
        #expect(reviews.freshness(of: reviews.reviewers[1]) == .current)
        #expect(reviews.reviewersToAsk.map(\.username) == ["slee"])
    }

    @Test("MR-09 a GitLab without the newer fields is asked again for the reviewers alone, and nobody's review is dated")
    func readsReviewsWithoutTheNewFields() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestReviews", body: """
            {"data":{"project":{"mergeRequest":{"reviewers":{"nodes":[
              {"id":"gid://gitlab/User/11","username":"slee","name":"Sam Lee",
               "mergeRequestInteraction":{"reviewState":"REVIEWED","reviewed":true,"approved":false}}]}}}}}
            """)
        // The newest route that matches answers first: the validation error once, then the reviewers alone.
        stub.answer(operation: "MergeRequestReviews", times: 1, body: try FixtureFiles.string("GitLab/merge-request-details-unknown-field.json"))

        let reviews = try #require(await Self.client(stub).reviews(of: Self.source))

        let queries = stub.requests(operation: "MergeRequestReviews").map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(queries.count == 2)
        #expect(queries[0].contains("mergeRequestDiffs") && !queries[1].contains("mergeRequestDiffs"))
        // Nobody can say it is current, so everyone who reviewed is asked.
        #expect(reviews.freshness(of: reviews.reviewers[0]) == .unknown)
        #expect(reviews.reviewersToAsk.map(\.username) == ["slee"])
    }

    // MARK: - The token

    @Test("ACC-07 a token with api can write, with read_api only it can't, without scopes GitLab doesn't say", arguments: [
        (["api"], WriteAccess.allowed),
        (["read_user", "api"], .allowed),
        (["read_api"], .readOnly),
        (["read_api", "read_repository"], .readOnly),
        ([], .unknown),
    ])
    func writeAccess(scopes: [String], expected: WriteAccess) {
        #expect(WriteAccess(scopes: scopes) == expected)
    }

    @Test("MR-09 asks GitLab for the token's scopes with the token as a Bearer, and reads them")
    func tokenScopes() async throws {
        let stub = StubTransport()
        stub.answer("GET", path: "/api/v4/personal_access_tokens/self", body: #"{"id":7,"name":"menubar-monitor","scopes":["read_api"],"active":true}"#)

        let scopes = try await Self.client(stub).tokenScopes()

        #expect(scopes == ["read_api"])
        #expect(WriteAccess(scopes: scopes) == .readOnly)
        let request = try #require(stub.requests(path: "/api/v4/personal_access_tokens/self").first)
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer glpat-test")
        #expect(request.url.query == nil)
    }

    @Test("MR-09 a refusal of the scope check isn't known, and the check never throws the write away")
    func tokenScopesRefused() async throws {
        let stub = StubTransport()
        stub.answer("GET", path: "/api/v4/personal_access_tokens/self", status: 401, body: #"{"message":"401 Unauthorized"}"#)

        await #expect(throws: GitLabError.self) { try await Self.client(stub).tokenScopes() }
    }

    // MARK: - The mutation

    @Test("MR-09 the mutation names the project, the iid and the user's global id, and the token only in the header")
    func mutationRequest() async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerRereview", body: #"{"data":{"mergeRequestReviewerRereview":{"errors":[]}}}"#)
        let sam = Self.reviewer(11, "slee", name: "Sam Lee")

        let outcome = await Self.client(stub).reRequest([sam], of: Self.source)

        #expect(outcome.sent == [sam] && outcome.failures.isEmpty && outcome.isComplete)
        let request = try #require(stub.requests(operation: "ReviewerRereview").first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gitlab.example.com/api/graphql")
        #expect(request.headers["Authorization"] == "Bearer glpat-test")
        let data = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["query"] as? String)?.contains("mergeRequestReviewerRereview(input: $input)") == true)
        let input = try #require((body["variables"] as? [String: Any])?["input"] as? [String: String])
        #expect(input == ["projectPath": "group/project", "iid": "16", "userId": "gid://gitlab/User/11"])
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("glpat-test") == false)
    }

    @Test("MR-09 an answer with errors is a failure with GitLab's words, and nothing is sent again")
    func mutationErrors() async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerRereview", body: #"{"data":{"mergeRequestReviewerRereview":{"errors":["Reviewer is not a reviewer of the merge request"]}}}"#)
        let sam = Self.reviewer(11, "slee", name: "Sam Lee")

        let outcome = await Self.client(stub).reRequest([sam], of: Self.source)

        #expect(outcome.sent.isEmpty)
        #expect(outcome.failures.map(\.message) == ["Reviewer is not a reviewer of the merge request"])
        #expect(outcome.needsToken == false)
        #expect(stub.requests(operation: "ReviewerRereview").count == 1)
    }

    // MARK: - Many at once

    @Test("MR-10 sends one request per reviewer and reports the ones that failed")
    func bulkReportsFailures() async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerRereview", body: #"{"data":{"mergeRequestReviewerRereview":{"errors":[]}}}"#)
        // The newest route that matches answers: Kim's request fails, and so does Lee's, at the transport.
        stub.add(.init(matches: { $0.graphQL?.variables.contains("User/2") == true }) {
            _ in .success(HTTPResponse(status: 200, body: Data(#"{"data":{"mergeRequestReviewerRereview":{"errors":["Not allowed"]}}}"#.utf8)))
        })
        stub.add(.init(matches: { $0.graphQL?.variables.contains("User/3") == true }) { _ in .failure(.noAnswer(within: .seconds(10))) })
        let people = [Self.reviewer(1, "slee", name: "Sam Lee"), Self.reviewer(2, "akim", name: "Kim Ito"), Self.reviewer(3, "cnovak", name: "Lee Wong"),
                      Self.reviewer(4, "rmeyer", name: "Robin Meyer")]

        let outcome = await Self.client(stub).reRequest(people, of: Self.source)

        #expect(outcome.sent.map(\.username) == ["slee", "rmeyer"])
        #expect(outcome.failures.map(\.reviewer.username) == ["akim", "cnovak"])
        #expect(outcome.failures[0].message == "Not allowed")
        #expect(outcome.failures[1].message == Problem.unreachable(.gitLab).message)
        #expect(outcome.needsToken == false)
        // One request each: nothing was tried again.
        #expect(stub.requests(operation: "ReviewerRereview").count == 4)
    }

    @Test("MR-10 a refusal for the scope ends the run: the other reviewers aren't tried", arguments: [
        (403, #"{"error":"insufficient_scope"}"#),
        (200, #"{"errors":[{"message":"The mutation requires a token with the api scope"}]}"#),
    ])
    func scopeEndsTheRun(status: Int, body: String) async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerRereview", status: status, body: body)
        let people = [Self.reviewer(1, "slee"), Self.reviewer(2, "akim"), Self.reviewer(3, "cnovak")]

        let outcome = await Self.client(stub).reRequest(people, of: Self.source)

        #expect(outcome.needsToken)
        #expect(outcome.sent.isEmpty)
        #expect(outcome.failures.map(\.reviewer.username) == ["slee"])
        #expect(stub.requests(operation: "ReviewerRereview").count == 1)
    }

    // MARK: - Through the store

    @Test("MR-09 a re-request loads the merge request's details again, and reports nothing without a token")
    func storeReloadsAfterTheRequest() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        stub.answer(operation: "ReviewerRereview", body: #"{"data":{"mergeRequestReviewerRereview":{"errors":[]}}}"#)
        stub.answer(operation: "MergeRequestDetails", body: try FixtureFiles.string("GitLab/merge-request-details.json"))
        stub.answer(operation: "MergeRequestReviews", body: try FixtureFiles.string("GitLab/merge-request-reviews.json"))
        stub.answer("GET", path: "/api/v4/personal_access_tokens/self", body: #"{"scopes":["read_api"]}"#)
        let store = MergeRequestDetailsStore(services: try Self.services(stub: stub, folder: folder, token: "glpat-test"))
        await store.load(Self.mergeRequest)
        #expect(stub.requests(operation: "MergeRequestDetails").count == 1)

        await store.checkWriteAccess()
        #expect(store.writeAccess == .readOnly)

        let sam = try #require(store.state(of: Self.mergeRequest).details?.reviews?.reviewers.first)
        let outcome = await store.reRequest([sam], of: Self.mergeRequest)

        #expect(outcome.isComplete)
        #expect(stub.requests(operation: "ReviewerRereview").count == 1)
        // The details belong to the last update already, and are loaded again anyway.
        #expect(stub.requests(operation: "MergeRequestDetails").count == 2)

        let none = try TemporaryFolder()
        let noToken = MergeRequestDetailsStore(services: try Self.services(stub: StubTransport(), folder: none, token: nil))
        let failed = await noToken.reRequest([sam], of: Self.mergeRequest)
        #expect(failed.sent.isEmpty && failed.needsToken && failed.failures.count == 1)
    }

    private static func services(stub: StubTransport, folder: TemporaryFolder, token: String?) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        let values = token.map { [TokenAccount.gitlab.rawValue: $0] } ?? [:]
        return GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: values)), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
    }
}

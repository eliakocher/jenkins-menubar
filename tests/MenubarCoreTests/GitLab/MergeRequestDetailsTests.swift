import Foundation
import Testing

@testable import MenubarCore

/// The approvals, the unresolved threads and the GitLab pipeline of a selected merge request (MR-06 to MR-08).
@Suite("Merge request details")
@MainActor
struct MergeRequestDetailsTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)

    private nonisolated static var mergeRequest: MergeRequest {
        MergeRequest(
            iid: 16, title: "Add a retry", webURL: source.webURL, reference: source.reference,
            author: .init(username: "slee", name: "Sam Lee"), updatedAt: updatedAt, roles: [.authored])
    }

    /// Decodes a fixture through the client, the way the store does.
    private static func details(_ fixture: String, level: MergeRequestDetailsLevel = .full) async throws -> MergeRequestDetails {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestDetails", body: try FixtureFiles.string("GitLab/\(fixture)"))
        let operation = try #require(GitLabOperation.details(of: source, level: level))
        return try await GitLabClient(transport: stub, gitLab: gitLab, token: "t").send(operation)
    }

    @Test("MR-06 reads who approved and the approval rules")
    func approvalsWithRules() async throws {
        let approvals = try await Self.details("merge-request-details.json").approvals

        #expect(approvals.approvedBy.map(\.username) == ["akim"])
        #expect(approvals.required == 2)
        #expect(approvals.summary == "1 of 2 approvals")
        #expect(approvals.isSatisfied == false)
        #expect(approvals.rules.map(\.name) == ["Code Owners", "Backend Review", "Optional Docs"])
        #expect(approvals.rules.map(\.isSatisfied) == [true, false, true])
        #expect(approvals.rules[0].approvedBy.map(\.name) == ["Alex Kim"])
    }

    @Test("MR-06 without approval rules it falls back to who approved")
    func approvalsWithoutRules() async throws {
        let approvals = try await Self.details("merge-request-details-basic.json", level: .basic).approvals

        #expect(approvals.rules.isEmpty)
        #expect(approvals.required == nil)
        #expect(approvals.approvedBy.map(\.name) == ["Sam Lee", "Alex Kim"])
        #expect(approvals.summary == "2 approvals")
        #expect(approvals.isSatisfied == nil)
    }

    @Test("MR-06 says what the approvals are when nobody approved", arguments: [
        (MergeRequestDetails.Approvals(required: 1), "0 of 1 approval"),
        (MergeRequestDetails.Approvals(required: 0), "No approvals required"),
        (MergeRequestDetails.Approvals(), "No approvals yet"),
        (MergeRequestDetails.Approvals(approvedBy: [.init(username: "a", name: "A")], required: 1), "1 of 1 approval"),
    ])
    func approvalsSummary(approvals: MergeRequestDetails.Approvals, expected: String) {
        #expect(approvals.summary == expected)
    }

    @Test("MR-07 lists the resolvable threads that aren't resolved, with the first note's author, place and page")
    func unresolvedThreads() async throws {
        let details = try await Self.details("merge-request-details.json")

        // The resolved thread and the one that can't be resolved are left out.
        #expect(details.threads.map(\.id) == ["gid://gitlab/Discussion/a1", "gid://gitlab/Discussion/a4"])
        #expect(details.resolvedThreadCount == 1)
        #expect(details.hasMoreDiscussions == false)

        let diffNote = details.threads[0]
        #expect(diffNote.author?.name == "Sam Lee")
        #expect(diffNote.location == "Sources/Export/ExportJob.swift:42")
        #expect(diffNote.url?.absoluteString == "https://gitlab.example.com/group/project/-/merge_requests/16#note_501")

        // A note without a `url` jumps to its number on the merge request's page; a comment has no place.
        let comment = details.threads[1]
        #expect(comment.location == nil)
        #expect(comment.url?.absoluteString == "https://gitlab.example.com/group/project/-/merge_requests/16#note_504")
        #expect(comment.author?.username == "cnovak")
    }

    @Test("MR-07 more discussions than asked for are noted")
    func moreDiscussions() async throws {
        let details = try await Self.details("merge-request-details-basic.json", level: .basic)

        #expect(details.hasMoreDiscussions)
        #expect(details.threads.isEmpty)
    }

    @Test("MR-07 the excerpt is plain text: no code, quotes, links or emphasis marks, and it is cut at a word")
    func excerpt() async throws {
        let details = try await Self.details("merge-request-details.json")

        #expect(details.threads[0].excerpt == "Question Why not retry on the caller's side? See the docs and RetryPolicy.")
        #expect(details.threads[1].excerpt == "quoted The description says three attempts, the code makes five.")
        let long = String(repeating: "word ", count: 100)
        let cut = PlainText.excerpt(of: long, limit: 50)
        #expect(cut.count <= 51 && cut.hasSuffix("word…"))
        // HTML stays text: nothing renders it.
        #expect(PlainText.excerpt(of: "<img src=x onerror=alert(1)> hi") == "<img src=x onerror=alert(1)> hi")
    }

    @Test("MR-08 reads the head pipeline's jobs by stage, failed and running first, with their pages")
    func pipelineJobs() async throws {
        let pipeline = try #require(try await Self.details("merge-request-details.json").pipeline)

        #expect(pipeline.status == .failed)
        #expect(pipeline.url?.absoluteString == "https://gitlab.example.com/group/project/-/pipelines/9001")
        #expect(pipeline.stages.map(\.name) == ["build", "test", "deploy"])
        #expect(pipeline.stages.map(\.state) == [.passed, .failed, .waiting])
        #expect(pipeline.needAttention.map(\.name) == ["ui-tests", "snapshot-tests"])
        #expect(pipeline.needAttention[0].url?.absoluteString == "https://gitlab.example.com/group/project/-/jobs/3")
        // A job without a page keeps its row, without a link.
        #expect(pipeline.jobs.last?.url == nil)
        #expect(pipeline.jobs.count == 5)
    }

    @Test("MR-08 a merge request without a pipeline has none")
    func noPipeline() async throws {
        #expect(try await Self.details("merge-request-details-basic.json", level: .basic).pipeline == nil)
    }

    @Test("MR-06 loads the details when the merge request is selected, once per update")
    func loadsOnSelection() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = MergeRequestDetailsStore(services: try Self.services(stub: stub, folder: folder))
        let mergeRequest = Self.mergeRequest
        stub.answer(operation: "MergeRequestDetails", times: 1, body: try FixtureFiles.string("GitLab/merge-request-details.json"))

        #expect(store.state(of: mergeRequest) == .loading)
        await store.load(mergeRequest)
        #expect(store.state(of: mergeRequest).isCurrent)
        #expect(store.state(of: mergeRequest).details?.threads.count == 2)
        #expect(stub.requests(operation: "MergeRequestDetails").map(\.graphQL?.variables) == [#"{"path":"group/project","iid":"16"}"#])

        // Selected again, unchanged: nothing is asked.
        await store.load(mergeRequest)
        #expect(stub.requests(operation: "MergeRequestDetails").count == 1)

        // The merge request changed: the old details stay while the new ones load, and when that fails.
        var changed = mergeRequest
        changed.updatedAt += 60
        #expect(store.state(of: changed).isCurrent == false)
        #expect(store.state(of: changed).details != nil)
        stub.answer(operation: "MergeRequestDetails", times: 1, body: #"{"data": {"project": {"mergeRequest": null}}}"#)
        await store.load(changed)
        #expect(store.state(of: changed).failed)
        #expect(store.state(of: changed).details != nil)

        // Selected again after the failure: asked again.
        stub.answer(operation: "MergeRequestDetails", times: 1, body: try FixtureFiles.string("GitLab/merge-request-details-basic.json"))
        await store.load(changed)
        #expect(store.state(of: changed).isCurrent)
        #expect(stub.requests(operation: "MergeRequestDetails").count == 3)
    }

    @Test("MR-06 a GitLab that doesn't know the approval fields is asked again without them")
    func fallsBackWithoutRules() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = MergeRequestDetailsStore(services: try Self.services(stub: stub, folder: folder))
        // The newest route answers first.
        stub.answer(operation: "MergeRequestDetails", times: 1, body: try FixtureFiles.string("GitLab/merge-request-details-basic.json"))
        stub.answer(operation: "MergeRequestDetails", times: 1, body: try FixtureFiles.string("GitLab/merge-request-details-unknown-field.json"))

        await store.load(Self.mergeRequest)

        let state = store.state(of: Self.mergeRequest)
        #expect(state.failed == false)
        #expect(state.details?.approvals.approvedBy.count == 2)
        let queries = stub.requests(operation: "MergeRequestDetails").map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(queries.count == 2)
        #expect(queries[0].contains("approvalState") && !queries[1].contains("approvalState"))
    }

    @Test("MR-06 asks nothing without a GitLab token and fails quietly")
    func withoutToken() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let services = GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: [:])),
            team: TeamStore(folder: folder.file("support"), report: { _ in }),
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
        let store = MergeRequestDetailsStore(services: services)

        await store.load(Self.mergeRequest)

        #expect(stub.requests.isEmpty)
        #expect(store.state(of: Self.mergeRequest).failed)
    }

    /// GitLab on the stub, a token in a fake keychain, and the team values of `group/project`.
    private static func services(stub: StubTransport, folder: TemporaryFolder) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        let log = ActivityLog(folder: folder.file("logs"))
        return GitLabServices(
            transport: stub, clock: ContinuousClock(),
            tokens: TokenStore(keychain: InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: log)
    }
}

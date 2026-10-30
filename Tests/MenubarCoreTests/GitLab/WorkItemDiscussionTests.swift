import Foundation
import Testing

@testable import MenubarCore

/// The comments of a selected work item (WIN-02).
@Suite("Work item discussion")
@MainActor
struct WorkItemDiscussionTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .workItem, reference: "group/project#31", webURL: gitLab.appending(path: "group/project/-/work_items/31"),
        updatedAt: updatedAt)

    @Test("WIN-02 reads a work item's comment threads and their replies, system notes left out, oldest thread first")
    func threadsAndReplies() async throws {
        let stub = StubTransport()
        stub.answer(operation: "WorkItemDiscussion", body: try FixtureFiles.string("GitLab/work-item-discussion.json"))
        let operation = try #require(GitLabOperation.discussion(of: Self.source))
        let discussion = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t").send(operation)

        // The thread of system notes only has nothing to show; the older thread comes first.
        #expect(discussion.threads.map(\.id) == ["gid://gitlab/Discussion/w1", "gid://gitlab/Discussion/w2"])
        #expect(discussion.hasMore)
        let thread = discussion.threads[0]
        #expect(thread.first.author?.name == "Sam Lee")
        #expect(thread.replies.map(\.body) == ["Both, I think.", "Agreed."])
        #expect(thread.replies[1].author == nil)
        #expect(thread.first.url?.absoluteString == "https://gitlab.example.com/group/project/-/work_items/31#note_901")
        #expect(discussion.threads[1].first.author?.username == "cnovak")
        #expect(discussion.commentCount == 4)
        // Comments only: the server leaves the activity out, and the query says so.
        #expect(operation.query.contains("ONLY_COMMENTS"))
        #expect(operation.variables == #"{"path":"group/project","iid":"31"}"#)
    }

    @Test("WIN-02 loads the discussion when the item is selected, once per update")
    func loadsOnSelection() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = ItemDiscussionsStore(services: try Self.services(stub: stub, folder: folder))
        let body = try FixtureFiles.string("GitLab/work-item-discussion.json")
        stub.answer(operation: "WorkItemDiscussion", times: 1, body: body)

        #expect(store.state(of: Self.source) == .loading)
        await store.load(Self.source)
        #expect(store.state(of: Self.source).isCurrent)
        #expect(store.state(of: Self.source).discussion?.threads.count == 2)

        // Selected again, unchanged: nothing is asked.
        await store.load(Self.source)
        #expect(stub.requests(operation: "WorkItemDiscussion").count == 1)

        // The item changed: the old discussion stays while the new one loads, and when that fails.
        var changed = Self.source
        changed.updatedAt += 60
        #expect(store.state(of: changed).isCurrent == false)
        stub.answer(operation: "WorkItemDiscussion", times: 1, body: #"{"data": {"namespace": {"workItem": null}}}"#)
        await store.load(changed)
        #expect(store.state(of: changed).failed)
        #expect(store.state(of: changed).discussion != nil)

        // Selected again after the failure: asked again.
        stub.answer(operation: "WorkItemDiscussion", times: 1, body: body)
        await store.load(changed)
        #expect(store.state(of: changed).isCurrent)
        #expect(stub.requests(operation: "WorkItemDiscussion").count == 3)
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

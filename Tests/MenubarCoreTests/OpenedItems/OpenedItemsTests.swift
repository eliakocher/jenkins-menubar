import Foundation
import Testing

@testable import MenubarCore

/// The merge requests and work items opened outside my lists (WIN-06).
@Suite("OpenedItems")
@MainActor
struct OpenedItemsTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let day: TimeInterval = 86400

    /// a clock the test moves
    private final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var date = OpenedItemsTests.start
        var value: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private func store(_ defaults: TemporaryDefaults, now: Now, services: GitLabServices? = nil) -> OpenedItemsStore {
        OpenedItemsStore(defaults: defaults.defaults, services: services, now: { now.value })
    }

    private func add(_ store: OpenedItemsStore, _ iid: Int, _ kind: OpenedItem.Kind = .mergeRequest, in project: String = "group/other") -> String {
        store.open(kind: kind, project: project, iid: iid, webURL: Self.gitLab.appending(path: "\(project)/-/x/\(iid)"))
    }

    @Test("WIN-06 an item opens once, and opening it again moves it to the top")
    func opensOnce() {
        let now = Now()
        let store = store(TemporaryDefaults(), now: now)
        let first = add(store, 1)
        now.advance(10)
        let second = add(store, 2, .workItem)
        #expect(store.items.map(\.id) == [second, first])

        now.advance(10)
        // The same merge request, its path in another case.
        _ = store.open(kind: .mergeRequest, project: "Group/Other", iid: 1, webURL: Self.gitLab.appending(path: "x"))
        #expect(store.items.map(\.id) == [first, second])
        #expect(store.items.first?.openedAt == now.value)
        // A merge request and a work item with the same number are two items.
        _ = add(store, 1, .workItem)
        #expect(store.items.count == 3)
    }

    @Test("WIN-06 closing an item, and Close All, keep what is pinned")
    func closing() {
        let store = store(TemporaryDefaults(), now: Now())
        let a = add(store, 1), b = add(store, 2), c = add(store, 3)
        store.setPinned(b, true)
        store.close(c)
        #expect(store.items.map(\.id) == [b, a])
        store.closeAll()
        #expect(store.items.map(\.id) == [b])
        store.close(b)
        #expect(store.items.isEmpty)
    }

    @Test("WIN-06 an item not viewed for 7 days drops out at launch, a pinned one never")
    func expiry() {
        let defaults = TemporaryDefaults()
        let now = Now()
        let first = store(defaults, now: now)
        let old = add(first, 1), pinned = add(first, 2), viewed = add(first, 3), fresh = add(first, 4)
        first.setPinned(pinned, true)
        now.advance(6 * Self.day)
        first.markViewed(viewed)
        now.advance(Self.day + 60)

        // Launch: the old one is 7 days and a minute unviewed; the viewed one only one day and a minute.
        let launched = store(defaults, now: now)
        #expect(!launched.items.map(\.id).contains(old))
        #expect(launched.items.map(\.id).contains(pinned))
        #expect(launched.items.map(\.id).contains(viewed))
        // `fresh` was opened with the old one, so it expired with it.
        #expect(!launched.items.map(\.id).contains(fresh))
    }

    @Test("WIN-06 the items, their titles and pins are kept across a restart, without any body")
    func persistence() throws {
        let defaults = TemporaryDefaults()
        let now = Now()
        let first = store(defaults, now: now)
        let id = add(first, 7, .workItem, in: "group/project")
        first.setPinned(id, true)
        _ = add(first, 8)

        let second = store(defaults, now: now)
        #expect(second.items == first.items)
        #expect(second.item(id)?.isPinned == true)
        let stored = String(decoding: try #require(defaults.defaults.data(forKey: OpenedItemsStore.defaultsKey)), as: UTF8.self)
        #expect(!stored.contains("description"))
    }

    // MARK: - Loading

    private static func mergeRequestAnswer(_ iid: Int) -> String {
        """
        {"data": {"project": {"mergeRequest": {
          "iid": "\(iid)", "title": "Fix the thing", "webUrl": "https://gitlab.example.com/group/other/-/merge_requests/\(iid)",
          "draft": false, "reference": "group/other!\(iid)", "updatedAt": "2026-10-01T10:00:00Z",
          "detailedMergeStatus": "MERGEABLE", "sourceBranch": "fix", "author": {"username": "sam", "name": "Sam Lee"},
          "headPipeline": {"status": "SUCCESS"}, "diffStatsSummary": {"additions": 3, "deletions": 1, "fileCount": 2},
          "reviewers": {"nodes": []}}}}}
        """
    }

    private static let workItemAnswer = """
        {"data": {"project": {"issue": {
          "title": "[PROJ-9] The task", "webUrl": "https://gitlab.example.com/group/other/-/issues/9",
          "reference": "group/other#9", "updatedAt": "2026-10-01T10:00:00Z", "type": "TASK", "state": "opened",
          "labels": {"nodes": [{"title": "committed", "color": "#ff0000"}]}, "author": {"username": "sam", "name": "Sam Lee"},
          "assignees": {"nodes": []}}}}}
        """

    @Test("WIN-06 loads one merge request and one work item by project and iid, once a minute")
    func loads() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let now = Now()
        let store = store(TemporaryDefaults(), now: now, services: try Self.services(stub: stub, folder: folder))
        stub.answer(operation: "OpenedMergeRequest", body: Self.mergeRequestAnswer(5))
        stub.answer(operation: "OpenedWorkItem", body: Self.workItemAnswer)
        stub.answer(operation: "RelatedMergeRequests", body: #"{"data": {"project": {"issue": {"relatedMergeRequests": {"nodes": []}}}}}"#)
        let mr = add(store, 5)
        let item = add(store, 9, .workItem)

        await store.load(mr)
        await store.load(item)
        #expect(stub.requests(operation: "OpenedMergeRequest").map(\.graphQL?.variables) == [#"{"path":"group/other","iid":"5"}"#])
        #expect(stub.requests(operation: "OpenedWorkItem").map(\.graphQL?.variables) == [#"{"path":"group/other","iid":"9"}"#])
        let mergeRequest = try #require(store.mergeRequests[mr])
        #expect(mergeRequest.title == "Fix the thing" && mergeRequest.roles.isEmpty && mergeRequest.pipelineStatus?.rawValue == "SUCCESS")
        #expect(store.workItems[item]?.type == .task && store.workItems[item]?.labels.first?.title == "committed")
        #expect(store.related[item]?.mergeRequests.isEmpty == true)
        // The sidebar's titles, with a work item's own key left out.
        #expect(store.item(mr)?.title == "Fix the thing")
        #expect(store.item(item)?.title == "The task")

        // Shown again within a minute: nothing is asked; after it, or on Retry, it is.
        await store.load(mr)
        #expect(stub.requests(operation: "OpenedMergeRequest").count == 1)
        await store.load(mr, force: true)
        #expect(stub.requests(operation: "OpenedMergeRequest").count == 2)
        now.advance(61)
        await store.load(mr)
        #expect(stub.requests(operation: "OpenedMergeRequest").count == 3)
    }

    @Test("WIN-06 an item GitLab doesn't have fails with a message, and a failed refresh keeps the item shown")
    func failures() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = store(TemporaryDefaults(), now: Now(), services: try Self.services(stub: stub, folder: folder))
        let id = add(store, 5)
        stub.answer(operation: "OpenedMergeRequest", body: #"{"data": {"project": {"mergeRequest": null}}}"#)
        await store.load(id)
        #expect(store.states[id] == .failed(.graphQLErrors(messages: ["Not found, or your token can't see it"])))
        #expect(store.mergeRequests[id] == nil)

        stub.answer(operation: "OpenedMergeRequest", body: Self.mergeRequestAnswer(5))
        await store.load(id)
        stub.answer(operation: "OpenedMergeRequest", status: 500, body: "")
        await store.load(id, force: true)
        #expect(store.states[id] == .failed(.httpStatus(.gitLab, status: 500)))
        #expect(store.mergeRequests[id]?.title == "Fix the thing")
    }

    @Test("WIN-06 a Jenkins build opens once per job and number, loads like Pipelines does, and is kept without any body")
    func buildItems() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let defaults = TemporaryDefaults()
        let now = Now()
        let jobURL = URL(string: "https://jenkins.example.com/job/project")!
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: jobURL.absoluteString, gitLabURL: Self.gitLab.absoluteString, gitLabProject: "group/project")))
        let services = PipelinesServices(
            transport: stub, clock: TestClock(),
            tokens: TokenStore(keychain: InMemoryKeychain(values: [
                TokenAccount.jenkins.rawValue: TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
            ])),
            team: team, userStates: UserStateStore(folder: folder.file("support"), report: { _ in }),
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")),
            effects: FakeEffects())
        let store = OpenedItemsStore(defaults: defaults.defaults, pipelines: services, now: { now.value })
        // One answer for the build's own request and its test counts, which read different fields of it.
        stub.answer(
            path: "/job/project/job/MR-9/3/api/json",
            body: #"{"number":3,"building":false,"result":"FAILURE","timestamp":1792800000000,"duration":120000,"#
                + #""estimatedDuration":60000,"actions":[{"failCount":2,"totalCount":10},{}]}"#)
        stub.answer(
            path: "/job/project/job/MR-9/api/json",
            body: #"{"actions":[{"objectDisplayName":"Fix the thing","objectUrl":"https://gitlab.example.com/group/project/-/merge_requests/9"}],"#
                + #""lastBuild":{"number":5,"building":false,"result":"SUCCESS","timestamp":1792900000000}}"#)
        stub.answer(
            path: "/job/project/job/MR-9/3/wfapi/describe",
            body: #"{"stages":[{"name":"build","status":"SUCCESS","durationMillis":4000},{"name":"test","status":"FAILED","durationMillis":9000}]}"#)
        let page = AlertContent.buildURL(job: "MR-9", number: 3, jobURL: jobURL)

        let id = store.openBuild(project: .main, job: "MR-9", number: 3, webURL: page)
        #expect(store.openBuild(project: .main, job: "MR-9", number: 3, webURL: page) == id)
        #expect(store.openBuild(project: .main, job: "MR-9", number: 4, webURL: page) != id)
        // Build 3 of MR-9 and merge request 3 are different items, whatever the project says.
        #expect(add(store, 3) != id)
        #expect(store.items.count == 3)

        await store.load(id)
        let build = try #require(store.builds[id])
        #expect(build.number == 3 && build.result == .failure && build.title == "Fix the thing" && build.project == .main)
        // The build asked for, not the job's last one (5).
        #expect(build.estimatedDuration == 60 && build.testCounts == TestCounts(failed: 2, total: 10))
        #expect(build.stages?.map(\.name) == ["build", "test"] && build.failedStages == ["test"])
        #expect(build.gitLabURL?.absoluteString == "https://gitlab.example.com/group/project/-/merge_requests/9")
        #expect(store.item(id)?.title == "Fix the thing")
        #expect(store.states[id] == .loaded(now.value))

        // Within a minute, nothing is asked again.
        let requests = stub.requests.count
        await store.load(id)
        #expect(stub.requests.count == requests)
        // Kept across a restart as a reference and a title, with the job.
        let launched = OpenedItemsStore(defaults: defaults.defaults, pipelines: services, now: { now.value })
        #expect(launched.item(id)?.job == "MR-9" && launched.item(id)?.kind == .build && launched.builds.isEmpty)
    }

    // MARK: - Open by Link

    struct LinkCase: Sendable, CustomTestStringConvertible {
        var text: String
        var route: LinkRoute?
        var refusal: OpenByLink.Refusal?
        var testDescription: String { text }
    }

    nonisolated static let linkCases: [LinkCase] = [
        LinkCase(text: "https://gitlab.example.com/group/other/-/merge_requests/12/diffs#note_1", route: .mergeRequest(gitLabProject: "group/other", iid: 12)),
        LinkCase(text: " https://gitlab.example.com/group/sub/other/-/issues/7 ", route: .workItem(gitLabProject: "group/sub/other", iid: 7)),
        LinkCase(text: "group/other!5", route: .mergeRequest(gitLabProject: "group/other", iid: 5)),
        LinkCase(text: "group/other#6", route: .workItem(gitLabProject: "group/other", iid: 6)),
        LinkCase(text: "!8", route: .mergeRequest(gitLabProject: "group/project", iid: 8)),
        LinkCase(text: "#9", route: .workItem(gitLabProject: "group/project", iid: 9)),
        LinkCase(text: "https://elsewhere.example.org/group/other/-/merge_requests/12", refusal: .notAnItem),
        LinkCase(text: "https://gitlab.example.com/group/other/-/pipelines/12", refusal: .notAnItem),
        LinkCase(text: "other!5", refusal: .notAnItem),
        LinkCase(text: "group/other!x", refusal: .notAnItem),
        LinkCase(text: "   ", refusal: .empty),
    ]

    @Test("WIN-06 Open by Link reads GitLab links and short references, and says why it can't", arguments: linkCases)
    func openByLink(_ item: LinkCase) {
        let projects = [Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: Self.gitLab.absoluteString, gitLabProject: "group/project"))]
        let result = OpenByLink.parse(item.text, projects: projects, defaultProject: "group/project")
        #expect(result == (item.route.map { .success($0) } ?? .failure(item.refusal!)))
    }

    @Test("WIN-06 a short form without a project needs one in Team")
    func noProject() {
        #expect(OpenByLink.parse("!8", projects: [], defaultProject: " ") == .failure(.noProject))
    }

    // MARK: - Helpers

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

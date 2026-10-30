import Foundation
import Testing

@testable import MenubarCore

/// The work items of a merge request and of a build: the team's title convention and GitLab's own links (MR-12).
@Suite("Linked work items")
@MainActor
struct LinkedWorkItemsTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let team = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString, gitLabProject: "group/project",
        ignoredMergeRequestPrefix: "[cascade]")
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)

    // MARK: The title

    @Test("MR-12 reads the work item references a title starts with", arguments: [
        ("#19202 Dialog bot answers twice", [WorkItemTitleReferences.Reference(iid: 19202)]),
        ("group/other#12 Fix the docs", [.init(project: "group/other", iid: 12)]),
        ("#12, #13 Fix both", [.init(iid: 12), .init(iid: 13)]),
        ("[#12 + group/other#5]: Fix both", [.init(iid: 12), .init(project: "group/other", iid: 5)]),
        ("Draft: #12 Fix", [.init(iid: 12)]),
        ("#12 #12 Fix", [.init(iid: 12)]),
        ("Fix the dialog", []),
        ("Fix #12 in the dialog", []),
        ("#12abc is not one", []),
        ("#0 nothing", []),
        ("[cascade] #12 merge", []),
        ("", []),
    ])
    func titleReferences(title: String, expected: [WorkItemTitleReferences.Reference]) {
        #expect(WorkItemTitleReferences.parse(title) == expected)
    }

    // MARK: The resolver

    @Test("MR-12 a merge request's work items: the title first, then GitLab's closing issues, each once")
    func titleThenCloses() {
        let closes = [
            LinkedWorkItem(project: "group/project", iid: 19202, title: "Dialog bot answers twice", origin: .closes),
            LinkedWorkItem(project: "group/project", iid: 7, title: "Seven", origin: .closes),
        ]

        let items = ItemLinks.workItems(
            ofMergeRequest: "group/project!16", title: "#19202 Dialog bot", evidence: .init(closes: closes), gitLab: Self.gitLab,
            titleOf: { $0 == "group/project#19202" ? "From the list" : nil })

        #expect(items.map(\.reference) == ["group/project#19202", "group/project#7"])
        #expect(items.map(\.origin) == [.title, .closes])
        // The list's title fills the title a reference has none of; GitLab's own stays.
        #expect(items.map(\.title) == ["From the list", "Seven"])
        #expect(items[0].webURL == URL(string: "https://gitlab.example.com/group/project/-/issues/19202"))
    }

    @Test("MR-12 a bare reference means the merge request's own project, another project's reference its own")
    func projectOfAReference() {
        let items = ItemLinks.workItems(ofMergeRequest: "group/project!16", title: "#1 group/other#2 both")

        #expect(items.map(\.reference) == ["group/project#1", "group/other#2"])
    }

    @Test("MR-12 related issues and mentions count only when nothing stronger names a work item")
    func looseLinksAreTheFallback() {
        let related = [LinkedWorkItem(project: "group/project", iid: 19100, origin: .related)]
        let evidence = WorkItemEvidence(related: related, mentionedBy: ["group/project#19100", "group/project#3", "group&4"])

        let fallback = ItemLinks.workItems(ofMergeRequest: "group/project!16", title: "Fix the dialog", evidence: evidence)
        #expect(fallback.map(\.reference) == ["group/project#19100", "group/project#3"])
        #expect(fallback.map(\.origin) == [.related, .mentions])

        let titled = ItemLinks.workItems(ofMergeRequest: "group/project!16", title: "#1 Fix the dialog", evidence: evidence)
        #expect(titled.map(\.reference) == ["group/project#1"])

        // A cascade merge request mentions many items and works on none.
        let cascade = ItemLinks.workItems(
            ofMergeRequest: "group/project!16", title: "[cascade] merge release", evidence: evidence, ignoredPrefix: "[cascade]")
        #expect(cascade.isEmpty)
    }

    @Test("MR-12 the cache names the work items whose related merge requests list a merge request")
    func reverseOfTheCache() throws {
        let mentioned = RelatedMergeRequest(
            iid: 16, state: .opened, title: "x", webURL: Self.source.webURL, reference: "Group/Project!16")
        let other = RelatedMergeRequest(iid: 17, state: .opened, title: "y", webURL: Self.source.webURL, reference: "group/project!17")
        let entry = { (merge: [RelatedMergeRequest]) in
            RelatedMergeRequestsCache.Entry(workItemUpdatedAt: Self.updatedAt, fetchedAt: Self.updatedAt, mergeRequests: merge)
        }
        let cache = RelatedMergeRequestsCache(entries: [
            "group/project#2": entry([mentioned]), "group/project#1": entry([mentioned, other]), "group/project#3": entry([other]),
        ])

        #expect(cache.workItems(mentioning: "group/project!16") == ["group/project#1", "group/project#2"])
    }

    // MARK: Builds

    @Test("MR-12 a build's merge request is its MR job's, from Jenkins' link or the team values")
    func mergeRequestOfABuild() throws {
        let page = Self.gitLab.appending(path: "group/project/-/merge_requests/12477")
        let linked = Self.build(job: "MR-12477", title: "#19202 Dialog bot", gitLabURL: page)
        let unlinked = Self.build(job: "MR-12477", title: nil, gitLabURL: nil)
        let branch = Self.build(job: "release%252F9", title: "#19202 Dialog bot", gitLabURL: page)

        let fromLink = try #require(ItemLinks.mergeRequest(ofBuild: linked, team: Self.team))
        #expect(fromLink.reference == "group/project!12477")
        #expect(fromLink.webURL == page)
        #expect(fromLink.title == "#19202 Dialog bot")

        let fromTeam = try #require(ItemLinks.mergeRequest(ofBuild: unlinked, team: Self.team))
        #expect(fromTeam.webURL == page)

        #expect(ItemLinks.mergeRequest(ofBuild: branch, team: Self.team) == nil)
        #expect(ItemLinks.mergeRequest(ofBuild: unlinked, team: TeamValues()) == nil)
    }

    @Test("MR-12 a build's work items are those of its merge request: the title Jenkins names, else the list's")
    func workItemsOfABuild() {
        let build = Self.build(job: "MR-12477", title: "#19202 Dialog bot", gitLabURL: nil)
        let untitled = Self.build(job: "MR-12477", title: nil, gitLabURL: nil)
        let closes = [LinkedWorkItem(project: "group/project", iid: 7, origin: .closes)]

        #expect(ItemLinks.workItems(ofBuild: build, team: Self.team).map(\.reference) == ["group/project#19202"])
        #expect(ItemLinks.workItems(ofBuild: untitled, team: Self.team).isEmpty)
        #expect(ItemLinks.workItems(ofBuild: untitled, team: Self.team, title: "#5 From a list").map(\.reference) == ["group/project#5"])
        #expect(
            ItemLinks.workItems(ofBuild: build, team: Self.team, evidence: .init(closes: closes)).map(\.reference)
                == ["group/project#19202", "group/project#7"])
        #expect(ItemLinks.workItems(ofBuild: Self.build(job: "main", title: "#1 x", gitLabURL: nil), team: Self.team).isEmpty)
    }

    // MARK: GitLab's links

    @Test("MR-12 reads the issues GitLab says a merge request closes and relates to, in their projects")
    func readsGitLabsLinks() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestClosesIssues", body: try FixtureFiles.string("GitLab/merge-request-closes-issues.json"))
        stub.answer(operation: "MergeRequestRelatedIssues", body: try FixtureFiles.string("GitLab/merge-request-related-issues.json"))

        let links = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-secret").workItemLinks(of: Self.source)

        #expect(links.closes.map(\.reference) == ["group/project#19202"])
        #expect(links.closes.map(\.title) == ["Dialog bot answers twice"])
        #expect(links.related.map(\.reference) == ["group/project#19202", "group/project#19100", "group/other#5"])
        #expect(links.related.allSatisfy { $0.origin == .related })
        #expect(links.closes[0].webURL == URL(string: "https://gitlab.example.com/group/project/-/issues/19202"))
        let paths = stub.requests.map { $0.url.path(percentEncoded: true) }
        #expect(paths.contains("/api/v4/projects/group%2Fproject/merge_requests/16/closes_issues"))
        #expect(paths.contains("/api/v4/projects/group%2Fproject/merge_requests/16/related_issues"))
        // The token is in the header, never in the URL.
        #expect(stub.requests.allSatisfy { !$0.url.absoluteString.contains("glpat-secret") })
    }

    @Test("MR-12 a GitLab without related issues still gives the closing ones; failed closing issues fail the call")
    func looseLinkIsOptional() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestClosesIssues", body: try FixtureFiles.string("GitLab/merge-request-closes-issues.json"))
        stub.answer(operation: "MergeRequestRelatedIssues", status: 404, body: #"{"message":"404 Not Found"}"#)
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t")

        let links = try await client.workItemLinks(of: Self.source)
        #expect(links.closes.count == 1)
        #expect(links.related.isEmpty)

        let failing = StubTransport()
        failing.answer(operation: "MergeRequestClosesIssues", status: 401, body: #"{"message":"401 Unauthorized"}"#)
        await #expect(throws: GitLabError.self) {
            try await GitLabClient(transport: failing, gitLab: Self.gitLab, token: "t").workItemLinks(of: Self.source)
        }
    }

    @Test("MR-12 loads the links of a merge request once per update, and asks again after a failure's pause")
    func loadsOnce() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = LinkedWorkItemsStore(services: try Self.services(stub: stub, folder: folder))
        stub.answer(operation: "MergeRequestClosesIssues", body: try FixtureFiles.string("GitLab/merge-request-closes-issues.json"))
        stub.answer(operation: "MergeRequestRelatedIssues", body: "[]")
        let reference = "group/project!16"

        #expect(store.links(of: reference) == nil)
        await store.load(reference: reference, webURL: Self.source.webURL, updatedAt: Self.updatedAt)
        #expect(store.links(of: "Group/Project!16")?.closes.map(\.iid) == [19202])

        // The same update: nothing is asked.
        await store.load(reference: reference, webURL: Self.source.webURL, updatedAt: Self.updatedAt)
        #expect(stub.requests(operation: "MergeRequestClosesIssues").count == 1)

        // A newer update asks again, and keeps the old links when that fails.
        stub.answer(operation: "MergeRequestClosesIssues", times: 1, status: 500, body: "")
        await store.load(reference: reference, webURL: Self.source.webURL, updatedAt: Self.updatedAt.addingTimeInterval(60))
        #expect(stub.requests(operation: "MergeRequestClosesIssues").count == 2)
        #expect(store.links(of: reference)?.closes.count == 1)

        // The failure is not asked again at once.
        await store.load(reference: reference, webURL: Self.source.webURL, updatedAt: Self.updatedAt.addingTimeInterval(60))
        #expect(stub.requests(operation: "MergeRequestClosesIssues").count == 2)
    }

    @Test("MR-12 asks nothing without a GitLab token and shows no links")
    func withoutToken() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let services = GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: [:])),
            team: TeamStore(folder: folder.file("support"), report: { _ in }),
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
        let store = LinkedWorkItemsStore(services: services)

        await store.load(reference: "group/project!16", webURL: Self.source.webURL)

        #expect(stub.requests.isEmpty)
        #expect(store.links(of: "group/project!16") == nil)
    }

    // MARK: Helpers

    private nonisolated static func build(job: String, title: String?, gitLabURL: URL?) -> Build {
        Build(
            job: job, number: 3, title: title, gitLabURL: gitLabURL, kind: .mine, phase: .finished(result: .failure, duration: 60),
            startedAt: updatedAt)
    }

    /// GitLab on the stub, a token in a fake keychain, and the team values of `group/project`.
    private static func services(stub: StubTransport, folder: TemporaryFolder) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: Self.team))
        return GitLabServices(
            transport: stub, clock: ContinuousClock(),
            tokens: TokenStore(keychain: InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
    }
}

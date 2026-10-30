import Foundation
import Testing

@testable import MenubarCore

/// The window's "In GitLab" search: what a text asks for, the query, the answer and the debounce (WIN-07).
@Suite("GitLabSearch")
@MainActor
struct GitLabSearchTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private nonisolated static let projects = [
        Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "acme/main/server/server", slotGroup: "acme/main")),
        Project(id: ProjectID(rawValue: "web")!, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/web", gitLabURL: gitLab.absoluteString,
            gitLabProject: "acme/main/web/web")),
    ]

    // MARK: - What a text asks for

    struct IntentCase: Sendable, CustomTestStringConvertible {
        var text: String
        var intent: GitLabSearchRules.Intent
        var testDescription: String { text }
    }

    nonisolated static let intentCases: [IntentCase] = [
        IntentCase(text: "!123", intent: .reference(.mergeRequest(gitLabProject: "acme/main/server/server", iid: 123))),
        IntentCase(text: "#7", intent: .reference(.workItem(gitLabProject: "acme/main/server/server", iid: 7))),
        IntentCase(text: "acme/main/web/web!5", intent: .reference(.mergeRequest(gitLabProject: "acme/main/web/web", iid: 5))),
        IntentCase(
            text: " https://gitlab.example.com/acme/main/web/web/-/issues/9 ",
            intent: .reference(.workItem(gitLabProject: "acme/main/web/web", iid: 9))),
        IntentCase(text: "export retry", intent: .text("export retry")),
        IntentCase(text: "  fix ", intent: .text("fix")),
        // Too short, empty, or a link that isn't an item (a text of its own, searched as typed).
        IntentCase(text: "ex", intent: .none),
        IntentCase(text: "   ", intent: .none),
        IntentCase(text: "!x", intent: .none),
        IntentCase(text: "https://elsewhere.example.org/a/b/-/issues/1", intent: .text("https://elsewhere.example.org/a/b/-/issues/1")),
    ]

    @Test("WIN-07 a reference or link is one item, a text of three characters is searched, shorter is not", arguments: intentCases)
    func intent(_ item: IntentCase) {
        #expect(
            GitLabSearchRules.intent(for: item.text, projects: Self.projects, defaultProject: "acme/main/server/server") == item.intent)
    }

    // MARK: - The query

    @Test("WIN-07 asks the groups of the team's projects with their subgroups, the slot group and the projects themselves")
    func scopes() {
        let scopes = GitLabSearchRules.scopes(of: Self.projects)
        #expect(scopes.groups == ["acme/main/server", "acme/main", "acme/main/web"])
        #expect(scopes.projects == ["acme/main/server/server", "acme/main/web/web"])
        #expect(GitLabSearchRules.scopes(of: [Project(id: .main, team: TeamValues())]).groups.isEmpty)
    }

    @Test("WIN-07 the query searches open items first and the recent ones of any state, and only a group takes its subgroups")
    func query() throws {
        let operation = GitLabOperation.searchMergeRequests(text: "export \"retry\"", groups: ["acme/main"], projects: ["me/tools"])
        #expect(operation.name == "SearchMergeRequests")
        #expect(operation.variables == #"{"search":"export \"retry\"","g0":"acme/main","p0":"me/tools"}"#)
        #expect(operation.query.contains("g0: group(fullPath: $g0)") && operation.query.contains("p0: project(fullPath: $p0)"))
        #expect(operation.query.contains("opened: mergeRequests(search: $search, includeSubgroups: true, sort: UPDATED_DESC, first: 20, state: opened)"))
        #expect(operation.query.contains("recent: mergeRequests(search: $search, sort: UPDATED_DESC, first: 20, state: all)"))
        // The text travels as a variable, never inside the query.
        #expect(!operation.query.contains("export"))

        let items = GitLabOperation.searchWorkItems(text: "x", groups: [], projects: ["me/tools"])
        #expect(items.name == "SearchWorkItems" && items.query.contains("fragment hit on Issue"))
        #expect(items.query.contains("recent: issues(search: $search, sort: UPDATED_DESC, first: 20, state: all)"))
    }

    // MARK: - The answer

    @Test("WIN-07 reads the hits of every scope once, leaves out a node without a number and a scope that is null")
    func decoding() throws {
        let operation = GitLabOperation.searchMergeRequests(text: "retry", groups: ["acme/main"], projects: ["acme/main/server/server"])
        let hits = try operation.decode(FixtureFiles.data("GitLab/search-merge-requests.json"))
        #expect(Set(hits.map(\.reference)) == [
            "acme/main/server/server!412", "acme/main/web/web!7", "acme/main/server/server!398", "acme/main/server/server!301",
        ])
        let draft = try #require(hits.first { $0.iid == 412 })
        #expect(draft.isDraft && draft.isOpen && draft.project == "acme/main/server/server" && draft.author == "Alex Kim")
        #expect(draft.shortReference == "!412" && draft.id == "acme/main/server/server!412")
        // Without a name the username stands in; without an author, nothing.
        #expect(hits.first { $0.iid == 7 }?.author == "@sam")
        let closed = try #require(hits.first { $0.iid == 301 })
        #expect(closed.author.isEmpty && closed.stateText == "Closed" && !closed.isOpen)
        #expect(hits.first { $0.iid == 398 }?.stateText == "Merged")
    }

    @Test("WIN-07 a work item hit keeps its type, and an answer without data is the GraphQL error")
    func workItemAnswer() throws {
        let operation = GitLabOperation.searchWorkItems(text: "retry", groups: ["acme/main"], projects: [])
        let body = """
            {"data": {"g0": {"opened": {"nodes": [{"iid": "9", "title": "Retry", "webUrl": "https://gitlab.example.com/acme/main/web/web/-/issues/9",
              "reference": "acme/main/web/web#9", "state": "opened", "type": "TASK", "updatedAt": "2026-10-01T09:15:00Z", "author": null}]},
              "recent": null}}}
            """
        let hit = try #require(try operation.decode(Data(body.utf8)).first)
        #expect(hit.kind == .workItem && hit.type == "TASK" && hit.shortReference == "#9" && hit.project == "acme/main/web/web")
        #expect(throws: GitLabError.self) { try operation.decode(Data(#"{"errors": [{"message": "Complexity is too high"}]}"#.utf8)) }
    }

    private static func hit(_ iid: Int, _ state: String, ageHours: Double, project: String = "acme/main/web/web") -> GitLabSearchHit {
        GitLabSearchHit(
            kind: .mergeRequest, reference: "\(project)!\(iid)", title: "T\(iid)", webURL: gitLab.appending(path: "mr/\(iid)"),
            state: state, updatedAt: now.addingTimeInterval(-ageHours * 3600))
    }

    @Test("WIN-07 the hits are open first, then the latest, each once and at most 20; the list's own rows are left out")
    func ordering() {
        let all = [Self.hit(1, "merged", ageHours: 1), Self.hit(2, "opened", ageHours: 50), Self.hit(3, "opened", ageHours: 5),
                   Self.hit(4, "closed", ageHours: 2), Self.hit(3, "opened", ageHours: 5)]
        #expect(GitLabSearchRules.ordered(all).map(\.iid) == [3, 2, 1, 4])
        let many = (1...30).map { Self.hit($0, "opened", ageHours: Double($0)) }
        #expect(GitLabSearchRules.ordered(many).map(\.iid) == Array(1...20))
        // The list's references come in any case.
        let rest = GitLabSearchRules.leavingOut(shown: ["ACME/main/web/web!3", "acme/main/web/web!1"], from: GitLabSearchRules.ordered(all))
        #expect(rest.map(\.iid) == [2, 4])
    }

    // MARK: - The debounce

    private final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var date = GitLabSearchTests.now
        var value: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private struct Harness {
        var store: GitLabSearchStore
        var stub: StubTransport
        var clock: TestClock
        var now: Now
        var folder: TemporaryFolder
    }

    private func harness(token: Bool = true) throws -> Harness {
        let folder = try TemporaryFolder()
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        let now = Now()
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Self.projects[0])
        let keychain = InMemoryKeychain(values: token ? [TokenAccount.gitlab.rawValue: "glpat-test"] : [:])
        let services = GitLabServices(
            transport: stub, clock: clock, now: { now.value }, tokens: TokenStore(keychain: keychain), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
        return Harness(store: GitLabSearchStore(services: services), stub: stub, clock: clock, now: now, folder: folder)
    }

    private static let answer = """
        {"data": {"g0": {"opened": {"nodes": [{"iid": "5", "title": "Retry", "webUrl": "https://gitlab.example.com/acme/main/server/server/-/merge_requests/5",
          "reference": "acme/main/server/server!5", "state": "opened", "draft": false, "updatedAt": "2026-10-01T09:15:00Z", "author": null}]},
          "recent": {"nodes": []}}}}
        """

    /// Waits, in real time, until the store left loading.
    private func settled(_ store: GitLabSearchStore, _ text: String, kind: GitLabSearchKind = .mergeRequest) async throws -> GitLabSearchStore.Phase {
        for _ in 0..<400 {
            let phase = store.phase(kind: kind, text: text)
            if phase != .loading {
                return phase
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return store.phase(kind: kind, text: text)
    }

    @Test("WIN-07 asks 400 ms after the last keystroke, a newer text cancels the older, and the same text is reused for 5 minutes")
    func debounce() async throws {
        let h = try harness()
        h.stub.answer(operation: "SearchMergeRequests", body: Self.answer)

        h.store.update(kind: .mergeRequest, text: "ret")
        #expect(h.store.phase(kind: .mergeRequest, text: "ret") == .loading)
        await h.clock.waitForSleepers()
        h.clock.advance(by: .milliseconds(300))
        // Another keystroke restarts the wait; nothing was asked.
        h.store.update(kind: .mergeRequest, text: "retr")
        await h.clock.waitForSleepers()
        h.clock.advance(by: .milliseconds(399))
        #expect(h.stub.requests.isEmpty)
        // The text before is no longer the one searched.
        #expect(h.store.phase(kind: .mergeRequest, text: "ret") == .idle)
        await h.clock.waitForSleepers()
        h.clock.advance(by: .milliseconds(1))
        let phase = try await settled(h.store, "retr")
        #expect(phase == .loaded(try [#require(phase.hits.first)]) && phase.hits.first?.iid == 5)
        #expect(h.stub.requests(operation: "SearchMergeRequests").count == 1)
        let variables = try #require(h.stub.requests.first?.graphQL?.variables)
        #expect(variables.contains(#""search":"retr""#) && variables.contains("acme/main/server") && variables.contains("acme/main"))

        // The same text, in other case, comes from the cache; after 5 minutes it asks again.
        h.store.update(kind: .mergeRequest, text: "ret")
        h.store.update(kind: .mergeRequest, text: "RETR")
        #expect(h.store.phase(kind: .mergeRequest, text: "RETR").hits.first?.iid == 5)
        #expect(h.stub.requests.count == 1)
        h.now.advance(301)
        h.store.update(kind: .mergeRequest, text: "retr")
        await h.clock.waitForSleepers()
        h.clock.advance(by: GitLabSearchRules.pause)
        #expect(try await settled(h.store, "retr").hits.count == 1)
        #expect(h.stub.requests.count == 2)

        // Work items are another query, and a reference or a short text asks nothing.
        h.store.update(kind: .workItem, text: "!12")
        h.store.update(kind: .workItem, text: "ab")
        #expect(h.store.phase(kind: .workItem, text: "ab") == .idle && h.store.phase(kind: .mergeRequest, text: "retr") == .idle)
        #expect(h.stub.requests.count == 2)
    }

    @Test("WIN-07 never has two requests in flight: the next waits for the one before")
    func oneInFlight() async throws {
        let h = try harness()
        // An answer takes 2 s on the clock.
        h.stub.answer(operation: "SearchMergeRequests", after: .seconds(2), body: Self.answer)
        let store = h.store
        let slow = h.stub

        store.update(kind: .mergeRequest, text: "first")
        await h.clock.waitForSleepers()
        h.clock.advance(by: GitLabSearchRules.pause)
        // The request is out and waits for its answer on the clock (sleeper 1).
        await h.clock.waitForSleepers()
        #expect(slow.requests.count == 1)
        store.update(kind: .mergeRequest, text: "second")
        // The older request is cancelled, ends, and only then the newer waits for its pause.
        await h.clock.waitForSleepers()
        h.clock.advance(by: GitLabSearchRules.pause)
        await h.clock.waitForSleepers()
        #expect(slow.requests.count == 2)
        h.clock.advance(by: .seconds(2))
        #expect(try await settled(store, "second") != .loading)
        #expect(store.phase(kind: .mergeRequest, text: "first") == .idle)
    }

    @Test("WIN-07 a failed search says so, and without a token it asks nothing")
    func failures() async throws {
        let h = try harness()
        h.stub.answer(operation: "SearchMergeRequests", status: 500, body: "")
        h.store.update(kind: .mergeRequest, text: "retry")
        await h.clock.waitForSleepers()
        h.clock.advance(by: GitLabSearchRules.pause)
        #expect(try await settled(h.store, "retry") == .failed(.httpStatus(.gitLab, status: 500)))

        let none = try harness(token: false)
        none.store.update(kind: .workItem, text: "retry")
        await none.clock.waitForSleepers()
        none.clock.advance(by: GitLabSearchRules.pause)
        #expect(try await settled(none.store, "retry", kind: .workItem) == .failed(.noToken(.gitLab)))
        #expect(none.stub.requests.isEmpty)
    }
}

extension GitLabSearchStore.Phase {
    fileprivate var hits: [GitLabSearchHit] {
        if case .loaded(let hits) = self { hits } else { [] }
    }
}

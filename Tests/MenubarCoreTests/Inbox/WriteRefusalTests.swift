import Foundation
import Testing

@testable import MenubarCore

/// A write GitLab refuses for the token's scope: what the user is told, that the row goes back, and how the scopes are
/// known (INBOX-03, MR-09).
@Suite("WriteRefusal", .timeLimit(.minutes(1)))
@MainActor
struct WriteRefusalTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let scopesPath = "/api/v4/personal_access_tokens/self"
    private static let refusal = "The resource that you are attempting to access does not exist or you don't have permission to perform this action"

    private struct World {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: WriteRefusalTests.gitLab.absoluteString,
                gitLabProject: "acme/web/app")))
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            services = GitLabServices(
                transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs")))
        }

        @MainActor
        func store() -> InboxStore {
            InboxStore(services: services, folder: folder.file("support"), rules: InboxNotificationRules(), myProjects: { [] })
        }
    }

    @Test("INBOX-03 a Mark Done that GitLab refuses for a read-only token goes back and says the token may only read")
    func markDoneRefusedForTheToken() async throws {
        let world = try World()
        world.stub.answer(operation: "InboxTodos", body: try FixtureFiles.string("Inbox/todos.json"))
        world.stub.answer(operation: "TodoMarkDone", body: try FixtureFiles.string("Inbox/todo-mark-done-no-permission.json"))
        world.stub.answer("GET", path: Self.scopesPath, body: try FixtureFiles.string("GitLab/personal-access-token-self-read-api.json"))
        let store = world.store()
        await store.load()
        let rows = store.pending
        let row = try #require(rows.first { $0.todo != nil })

        await store.markDone(row)

        // The row is back, marked as bounced, and the problem names the scope.
        #expect(store.pending == rows)
        #expect(store.done.isEmpty)
        #expect(store.bouncedIDs == [row.id])
        #expect(store.actionProblem == .readOnlyToken(action: "Mark Done"))
        #expect(
            store.actionProblem?.message
                == "GitLab refused: your token may only have read access. Mark Done needs the api scope.")
        #expect(SettingsPane.pane(for: try #require(store.actionProblem)) == .accounts)

        store.dismissActionProblem()
        #expect(store.actionProblem == nil)
    }

    @Test("INBOX-03 the same refusal from a token that has api keeps GitLab's own words, and the scopes are asked once")
    func refusalOfATokenWithApi() async throws {
        let world = try World()
        world.stub.answer(operation: "InboxTodos", body: try FixtureFiles.string("Inbox/todos.json"))
        world.stub.answer(operation: "TodoMarkDone", body: try FixtureFiles.string("Inbox/todo-mark-done-no-permission.json"))
        world.stub.answer("GET", path: Self.scopesPath, body: #"{"scopes":["api"]}"#)
        let store = world.store()
        await store.load()
        let rows = store.pending

        await store.markDone(try #require(rows.first { $0.todo != nil }))
        await store.markDone(try #require(rows.first { $0.todo != nil }))

        #expect(store.pending == rows)
        #expect(store.actionProblem == .graphQLErrors(messages: [Self.refusal]))
        #expect(world.stub.requests.filter { $0.url.path == Self.scopesPath }.count == 1)
    }

    @Test("MR-09 the token's scopes decode from personal_access_tokens/self; a 404 or no scopes is not known, not read-only")
    func scopesDecode() async throws {
        let world = try World()
        let client = GitLabClient(transport: world.stub, gitLab: Self.gitLab, token: "glpat-test", timeouts: .standard)

        world.stub.answer("GET", path: Self.scopesPath, body: try FixtureFiles.string("GitLab/personal-access-token-self-read-api.json"))
        let scopes = try await client.tokenScopes()
        #expect(scopes == ["read_api", "read_user"])
        #expect(WriteAccess(scopes: scopes) == .readOnly)
        // The request carries the token as Bearer auth, and the app never logs or stores the scopes with it.
        #expect(world.stub.requests.first?.headers["Authorization"] == "Bearer glpat-test")

        world.stub.answer("GET", path: Self.scopesPath, status: 404)
        await #expect(throws: GitLabError.self) { try await client.tokenScopes() }
        #expect(world.stub.requests.count == 2)

        // The probe turns a refused lookup into "not known", which blames nothing on the scope.
        let probe = WriteAccessProbe()
        #expect(await probe.check(world.services) == .unknown)
    }

    @Test(
        "MR-09 the read-only note shows for a token known to only read",
        arguments: [
            (["api"], false), (["read_api"], true), (["read_api", "read_user"], true), (["api", "read_user"], false),
            ([], false),
        ])
    func readOnlyNoteRule(scopes: [String], shows: Bool) {
        let note = WriteAccess.note(for: AccountStatus.signedIn(as: "jdoe", scopes: scopes).writeAccess)
        #expect((note != nil) == shows)
        #expect(note == nil || note == "Read-only token: Mark Done, Snooze in GitLab, Merge, Re-request Review and comments need the api scope")
        // A check that couldn't ask shows nothing.
        #expect(WriteAccess.note(for: AccountStatus.signedIn(as: "jdoe", scopes: nil).writeAccess) == nil)
    }

    @Test("MR-09 GitLab's token page is the plain tokens page of the instance")
    func tokensPage() {
        #expect(GitLabLinks.tokensPage(gitLab: Self.gitLab).absoluteString == "https://gitlab.example.com/-/user_settings/personal_access_tokens")
    }
}

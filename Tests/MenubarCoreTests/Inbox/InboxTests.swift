import Foundation
import Testing

@testable import MenubarCore

/// The Inbox: GitLab's to-dos, their groups, Done/Restore/Snooze with their rollback, the events between two polls and
/// their routing (INBOX-01 … INBOX-06).
@Suite("Inbox", .timeLimit(.minutes(1)))
@MainActor
struct InboxTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    /// Monday 2026-11-02 10:00 UTC, when the test clock starts
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_613_600)
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A stub GitLab on the test clock, a token, the team values, and the caches and support folder in a temporary
    /// folder.
    @MainActor
    private final class World {
        let folder: TemporaryFolder
        let clock = TestClock()
        let stub: StubTransport
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            stub = StubTransport(clock: clock)
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: InboxTests.gitLab.absoluteString,
                gitLabProject: "acme/web/app")))
            let clock = clock
            let now: @Sendable () -> Date = {
                let offset = clock.now.offset.components
                return InboxTests.start.addingTimeInterval(Double(offset.seconds) + Double(offset.attoseconds) / 1e18)
            }
            let log = ActivityLog(folder: folder.file("logs"), now: now)
            services = GitLabServices(
                transport: stub, clock: clock, now: now, tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: log)
        }

        var now: Date { services.now() }

        /// A store on this world's support folder, like one launch of the app.
        func store(rules: InboxNotificationRules = InboxNotificationRules(), myProjects: Set<String> = []) -> InboxStore {
            InboxStore(
                services: services, folder: folder.file("support"), rules: rules, myProjects: { myProjects },
                calendar: InboxTests.utc)
        }

        func answer(_ operation: String, after delay: Duration = .zero, _ body: String) {
            stub.answer(operation: operation, after: delay, body: body)
        }

        func answerFixture(_ operation: String, _ name: String) throws {
            stub.answer(operation: operation, body: try FixtureFiles.string("Inbox/\(name)"))
        }

        func requests(_ operation: String) -> [HTTPRequest] {
            stub.requests(operation: operation)
        }

        /// Moves the clock on, waking what sleeps until then.
        func advance(_ seconds: Int) {
            clock.advance(by: .seconds(seconds))
        }
    }

    /// One to-do of a made-up answer.
    private struct Todo: Sendable {
        var id: Int
        var action = "mentioned"
        var created: Date
        var project = "acme/web/app"
        var snoozedUntil: Date?
    }

    /// An InboxTodos answer with these to-dos.
    private static func answer(_ pending: [Todo], snoozed: [Todo] = []) -> String {
        func node(_ todo: Todo) -> String {
            let until = todo.snoozedUntil.map { "\"\($0.formatted(Date.ISO8601FormatStyle()))\"" } ?? "null"
            return """
                {"id": "gid://gitlab/Todo/\(todo.id)", "action": "\(todo.action)", "targetType": "MERGEREQUEST",
                 "state": "pending", "body": "To-do \(todo.id)", "createdAt": "\(todo.created.formatted(Date.ISO8601FormatStyle()))",
                 "snoozedUntil": \(until), "author": {"username": "sam.rivera", "name": "Sam Rivera"},
                 "project": {"fullPath": "\(todo.project)"},
                 "targetEntity": {"webUrl": "\(gitLab)/\(todo.project)/-/merge_requests/\(todo.id)", "name": "Item \(todo.id)",
                                  "iid": "\(todo.id)", "reference": "\(todo.project)!\(todo.id)"}}
                """
        }
        return """
            {"data": {"currentUser": {"username": "alex.doe",
              "pending": {"count": \(pending.count), "nodes": [\(pending.map(node).joined(separator: ","))]},
              "snoozed": {"count": \(snoozed.count), "nodes": [\(snoozed.map(node).joined(separator: ","))]}}}}
            """
    }

    private static func payload(_ field: String, errors: [String] = []) -> String {
        let list = errors.map { "\"\($0)\"" }.joined(separator: ",")
        let todo = field == "todosMarkAllDone" ? "\"todos\": []" : "\"todo\": {\"id\": \"gid://gitlab/Todo/1\"}"
        return "{\"data\": {\"\(field)\": {\"errors\": [\(list)], \(todo)}}}"
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    // MARK: - INBOX-01

    @Test("INBOX-01 the to-dos answer becomes pending and snoozed to-dos with their targets")
    func parsesTheTodos() async throws {
        let stub = StubTransport()
        stub.answer(operation: "InboxTodos", body: try FixtureFiles.string("Inbox/todos.json"))

        let list = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t").send(.inboxTodos())

        #expect(list.username == "alex.doe")
        #expect(list.pendingCount == 6)
        #expect(list.pending.map(\.id) == (900...905).reversed().map { "gid://gitlab/Todo/\($0)" })
        let mention = try #require(list.pending.first)
        #expect(mention.action == .mentioned)
        #expect(mention.targetKind == .mergeRequest)
        #expect(mention.title == "Retry the upload when the network drops")
        #expect(mention.targetURL == URL(string: "https://gitlab.example.com/acme/web/app/-/merge_requests/41"))
        #expect(mention.reference == "acme/web/app!41")
        #expect(mention.iid == 41)
        #expect(mention.projectPath == "acme/web/app")
        #expect(mention.author == MergeRequest.Person(username: "sam.rivera", name: "Sam Rivera"))
        #expect(mention.createdAt == Date(timeIntervalSince1970: 1_793_369_111))
        // Fractions of a second, an action the app doesn't know, a deleted target, no author.
        #expect(abs(list.pending[1].createdAt.timeIntervalSince1970 - 1_793_359_200.123) < 0.001)
        #expect(list.pending[4].action.eventKind == .otherTodo)
        #expect(list.pending[4].title == "A workflow waits for you")
        #expect(list.pending[4].targetURL == nil)
        #expect(list.pending[5].author == nil)
        #expect(list.pending[5].group == .mentions)
        #expect(list.snoozed.map(\.snoozedUntil) == [Date(timeIntervalSince1970: 1_793_696_400)])
    }

    @Test("INBOX-01 a GitLab without the snooze fields is asked at the basic level from then on")
    func basicLevel() async throws {
        let world = try World()
        let refused = try FixtureFiles.string("Inbox/todos-no-snooze.json")
        let basic = Self.answer([Todo(id: 1, created: world.now)]).replacingOccurrences(of: "targetEntity", with: "target")
        world.stub.add(.init(matches: { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("isSnoozed") }) { _ in
            .success(HTTPResponse(status: 200, headers: [:], body: Data(refused.utf8)))
        })
        world.stub.add(.init(matches: { request in
            request.graphQL?.name == "InboxTodos" && !String(decoding: request.body ?? Data(), as: UTF8.self).contains("isSnoozed")
        }) { _ in .success(HTTPResponse(status: 200, headers: [:], body: Data(basic.utf8))) })
        let store = world.store()

        await store.load()
        await store.load()

        #expect(store.problem == nil)
        #expect(store.pending.map(\.id) == ["gid://gitlab/Todo/1"])
        #expect(!store.snoozesInGitLab)
        let bodies = world.requests("InboxTodos").map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(bodies.map { $0.contains("isSnoozed") } == [true, false, false])
        #expect(bodies.last?.contains("target {") == true)
    }

    @Test("INBOX-01 the to-dos load with nothing on screen, at the GitLab pace")
    func loadsInTheBackground() async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([]))
        let store = world.store()
        let scheduler = Scheduler(
            checkInterval: .seconds(3600), clock: world.clock, systemEvents: FakeSystemEvents(),
            reachability: FakeReachability(), powerMode: FakePowerMode(), gitLabMaxAge: .seconds(60),
            loads: [.inbox: store], alwaysShown: [.inbox], check: { _ in .success })

        await scheduler.start()
        #expect(await eventually { world.requests("InboxTodos").count == 1 })
        // The views show other surfaces, or none: the Inbox keeps loading.
        await scheduler.setVisible([])
        await scheduler.setAttentive(false)
        await world.clock.waitForSleepers(2)
        world.advance(60)
        await Task.yield()
        #expect(world.requests("InboxTodos").count == 1)
        world.advance(240)
        #expect(await eventually { world.requests("InboxTodos").count == 2 })
        await scheduler.stop()
    }

    // MARK: - INBOX-02

    @Test("INBOX-02 pending rows are grouped Mentions, Review Requests, Assigned, Other, newest first")
    func grouping() async throws {
        let world = try World()
        try world.answerFixture("InboxTodos", "todos.json")
        let store = world.store()

        await store.load()

        let groups = store.sections.map { ($0.group, $0.entries.map(\.id)) }
        #expect(groups.map(\.0) == [.mentions, .reviewRequests, .assigned, .other])
        #expect(groups.map(\.1) == [
            ["gid://gitlab/Todo/905", "gid://gitlab/Todo/900"], ["gid://gitlab/Todo/904"], ["gid://gitlab/Todo/903"],
            ["gid://gitlab/Todo/902", "gid://gitlab/Todo/901"],
        ])
        #expect(store.sections.first?.entries.first?.headline == "Sam Rivera mentioned you")
        #expect(store.snoozed.map(\.id) == ["gid://gitlab/Todo/899"])
        #expect(store.badgeCount == 6)
        #expect(store.entries(InboxFilter(project: "acme/tools/cli")).map(\.id) == ["gid://gitlab/Todo/903", "gid://gitlab/Todo/900"])
        #expect(store.entries(InboxFilter(state: .snoozed, group: .reviewRequests)).count == 1)
        // The next launch shows the same at once, from the cache.
        #expect(world.store().pending.map(\.id) == store.pending.map(\.id))
    }

    // MARK: - INBOX-03

    @Test("INBOX-03 done and restore round trip through GitLab")
    func doneAndRestore() async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([Todo(id: 1, created: world.now), Todo(id: 2, created: world.now)]))
        try world.answerFixture("TodoMarkDone", "todo-mark-done.json")
        world.answer("TodoRestore", Self.payload("todoRestore"))
        let store = world.store()
        await store.load()
        let row = try #require(store.pending.first { $0.id == "gid://gitlab/Todo/1" })

        await store.markDone(row)
        #expect(store.pending.map(\.id) == ["gid://gitlab/Todo/2"])
        #expect(store.done.map(\.id) == ["gid://gitlab/Todo/1"])
        #expect(world.requests("TodoMarkDone").first?.graphQL?.variables == #"{"id":"gid://gitlab/Todo/1"}"#)

        // GitLab no longer lists it as pending; it stays in Done.
        world.answer("InboxTodos", Self.answer([Todo(id: 2, created: world.now)]))
        await store.load()
        #expect(store.done.map(\.id) == ["gid://gitlab/Todo/1"])

        await store.restore(try #require(store.done.first))
        #expect(Set(store.pending.map(\.id)) == ["gid://gitlab/Todo/1", "gid://gitlab/Todo/2"])
        #expect(store.done.isEmpty)
        #expect(world.requests("TodoRestore").count == 1)
        #expect(store.actionProblem == nil)
    }

    enum Change: String, CaseIterable, Sendable {
        case markDone, markAllDone, snooze
    }

    @Test("INBOX-03 a change GitLab refuses moves at once and comes back", arguments: Change.allCases)
    func refusedChange(_ change: Change) async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([Todo(id: 1, created: world.now), Todo(id: 2, created: world.now)]))
        let (operation, field) = switch change {
        case .markDone: ("TodoMarkDone", "todoMarkDone")
        case .markAllDone: ("TodosMarkAllDone", "todosMarkAllDone")
        case .snooze: ("TodoSnooze", "todoSnooze")
        }
        world.answer(operation, after: .seconds(1), Self.payload(field, errors: ["You don't have permission"]))
        let store = world.store()
        await store.load()
        let rows = store.pending
        let row = try #require(rows.first)

        let task = Task {
            switch change {
            case .markDone: await store.markDone(row)
            case .markAllDone: await store.markAllDone()
            case .snooze: await store.snooze(row, .oneHour)
            }
        }
        // A snooze also waits for its wake-up.
        await world.clock.waitForSleepers(change == .snooze ? 2 : 1)
        #expect(store.pending.count == (change == .markAllDone ? 0 : 1))
        world.advance(1)
        await task.value

        #expect(store.pending == rows)
        #expect(store.done.isEmpty && store.snoozed.isEmpty)
        #expect(store.actionProblem == .graphQLErrors(messages: ["You don't have permission"]))
    }

    @Test("INBOX-03 a load during a change keeps the change until GitLab shows it")
    func loadDuringAChange() async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([Todo(id: 1, created: world.now)]))
        world.answer("TodoMarkDone", after: .seconds(1), Self.payload("todoMarkDone"))
        let store = world.store()
        await store.load()
        let row = try #require(store.pending.first)

        let task = Task { await store.markDone(row) }
        await world.clock.waitForSleepers()
        // A poll answers before GitLab took the change: it still lists the to-do as pending.
        await store.load()
        #expect(store.pending.isEmpty)
        world.advance(1)
        await task.value
        #expect(store.pending.isEmpty)

        // Once GitLab shows it done, its answer decides again.
        world.answer("InboxTodos", Self.answer([]))
        await store.load()
        #expect(store.pending.isEmpty)
        #expect(store.done.map(\.id) == ["gid://gitlab/Todo/1"])
    }

    // MARK: - INBOX-04

    @Test("INBOX-04 a snoozed to-do wakes when its time comes")
    func snoozeWakes() async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([Todo(id: 1, created: world.now), Todo(id: 2, created: world.now)]))
        world.answer("TodoSnooze", Self.payload("todoSnooze"))
        let store = world.store()
        await store.load()
        let row = try #require(store.pending.first { $0.id == "gid://gitlab/Todo/1" })

        await store.snooze(row, .oneHour)

        #expect(store.pending.map(\.id) == ["gid://gitlab/Todo/2"])
        #expect(store.snoozed.map(\.snoozedUntil) == [world.now.addingTimeInterval(3600)])
        #expect(store.badgeCount == 1)
        #expect(world.requests("TodoSnooze").first?.graphQL?.variables
            == #"{"id":"gid://gitlab/Todo/1","until":"2026-11-02T11:00:00Z"}"#)
        await world.clock.waitForSleepers()
        world.advance(3599)
        await Task.yield()
        #expect(store.snoozed.count == 1)
        world.advance(1)
        #expect(await eventually { store.snoozed.isEmpty })
        #expect(store.pending.count == 2)
        #expect(store.badgeCount == 2)
    }

    @Test("INBOX-04 without GitLab's snooze a to-do sleeps on this Mac, across a restart")
    func localSnooze() async throws {
        let world = try World()
        world.answer("InboxTodos", Self.answer([Todo(id: 1, created: world.now)]))
        try world.answerFixture("TodoSnooze", "snooze-unknown.json")
        let store = world.store()
        await store.load()

        await store.snooze(try #require(store.pending.first), .tomorrowMorning)

        #expect(!store.snoozesInGitLab)
        #expect(store.actionProblem == nil)
        #expect(store.snoozed.map(\.snoozedUntil) == [Date(timeIntervalSince1970: 1_793_696_400)])
        // GitLab still lists it as pending; this Mac keeps it asleep, after a relaunch too.
        let next = world.store()
        await next.load()
        #expect(next.pending.isEmpty)
        #expect(next.snoozed.map(\.id) == ["gid://gitlab/Todo/1"])
        await next.unsnooze(try #require(next.snoozed.first))
        #expect(next.pending.map(\.id) == ["gid://gitlab/Todo/1"])
        #expect(world.requests("TodoSnooze").count == 1)
        #expect(world.requests("TodoUnSnooze").isEmpty)
    }

    @Test(
        "INBOX-04 the snooze choices: an hour, tomorrow at 9, next Monday at 9",
        arguments: [
            // Monday 10:00
            (InboxSnoozeChoice.oneHour, 1_793_613_600.0, 1_793_617_200.0),
            (.tomorrowMorning, 1_793_613_600, 1_793_696_400),
            // Monday 10:00 → the Monday after; Sunday 22:00 → the next day
            (.nextWeek, 1_793_613_600, 1_794_214_800),
            (.nextWeek, 1_793_570_400, 1_793_610_000),
        ])
    func snoozeChoices(_ choice: InboxSnoozeChoice, from: TimeInterval, wakes: TimeInterval) {
        #expect(choice.wakeDate(from: Date(timeIntervalSince1970: from), calendar: Self.utc) == Date(timeIntervalSince1970: wakes))
    }

    // MARK: - INBOX-05

    enum Scenario: String, CaseIterable, Sendable {
        /// nothing kept from before: the first load is the start
        case firstLaunch
        /// a to-do created since the last load
        case new
        case unchanged
        /// a to-do announced, gone for a load, and back
        case alreadyAnnounced
        /// a relaunch: what the last run announced isn't again, what came since is
        case afterRestart
        /// an old to-do back from snooze or from done isn't news
        case backFromSnooze
    }

    @Test("INBOX-05 new to-dos are announced once, never after a restart, nothing old at launch", arguments: Scenario.allCases)
    func todoEvents(_ scenario: Scenario) async throws {
        let world = try World()
        let old = Todo(id: 1, created: world.now.addingTimeInterval(-86_400))
        world.answer("InboxTodos", Self.answer([old]))
        var store = world.store()
        await store.load()
        var announced: [String] = []
        store.onEvents = { announced += $0.map(\.event.id) }

        switch scenario {
        case .firstLaunch:
            break
        case .new:
            world.advance(60)
            world.answer("InboxTodos", Self.answer([old, Todo(id: 2, action: "review_requested", created: world.now)]))
            await store.load()
        case .unchanged:
            world.advance(60)
            await store.load()
        case .alreadyAnnounced:
            world.advance(60)
            let fresh = Todo(id: 2, created: world.now)
            world.answer("InboxTodos", Self.answer([old, fresh]))
            await store.load()
            announced = []
            world.advance(60)
            world.answer("InboxTodos", Self.answer([old]))
            await store.load()
            world.advance(60)
            world.answer("InboxTodos", Self.answer([old, fresh]))
            await store.load()
        case .afterRestart:
            world.advance(60)
            let fresh = Todo(id: 2, created: world.now)
            world.answer("InboxTodos", Self.answer([old, fresh]))
            await store.load()
            world.advance(600)
            world.answer("InboxTodos", Self.answer([old, fresh, Todo(id: 3, created: world.now)]))
            store = world.store()
            announced = []
            store.onEvents = { announced += $0.map(\.event.id) }
            await store.load()
        case .backFromSnooze:
            world.advance(60)
            world.answer("InboxTodos", Self.answer([old, Todo(id: 4, created: world.now.addingTimeInterval(-7200))]))
            await store.load()
        }

        let expected: [String] = switch scenario {
        case .new: ["todo|gid://gitlab/Todo/2"]
        case .afterRestart: ["todo|gid://gitlab/Todo/3"]
        default: []
        }
        #expect(announced == expected)
        #expect(store.recentEvents.map(\.id) == (scenario == .alreadyAnnounced ? ["todo|gid://gitlab/Todo/2"] : expected))
    }

    enum ListChange: String, CaseIterable, Sendable {
        case reviewRequested, assignedBySomeoneElse, assignedByMyself, approved, changesRequested, reviewed
        case pipelineFailed, merged, closed, firstAfterLaunchLongAgo
    }

    @Test("INBOX-05 changes of my merge requests between two loads", arguments: ListChange.allCases)
    func mergeRequestEvents(_ change: ListChange) throws {
        let me = MergeRequest.Person(username: "alex.doe", name: "Alex Doe")
        let other = MergeRequest.Person(username: "kim.lee", name: "Kim Lee")
        let url = Self.gitLab.appending(path: "acme/web/app/-/merge_requests/12")
        func state(
            roles: Set<MergeRequest.Role> = [.authored], author: MergeRequest.Person = me,
            pipeline: MergeRequest.PipelineStatus? = .running, review: MergeRequest.ReviewState = .unreviewed,
            approved: Bool = false
        ) -> InboxSnapshot.MergeRequestState {
            InboxSnapshot.MergeRequestState(
                url: url, reference: "acme/web/app!12", title: "Retry the upload", author: author, roles: roles,
                pipelineStatus: pipeline,
                reviewers: [MergeRequest.Reviewer(username: "kim.lee", name: "Kim Lee", reviewState: review, approved: approved)])
        }
        let start = Self.start
        var before = [state()]
        var after = [state()]
        var gap: TimeInterval = 60
        var firstAfterLaunch = false
        let expected: (InboxEventKind, String?)?
        switch change {
        case .reviewRequested:
            before = []
            after = [state(roles: [.reviewRequested], author: other)]
            expected = (.reviewRequested, "kim.lee")
        case .assignedBySomeoneElse:
            before = [state(roles: [.reviewRequested], author: other)]
            after = [state(roles: [.reviewRequested, .assigned], author: other)]
            expected = (.assigned, "kim.lee")
        case .assignedByMyself:
            after = [state(roles: [.authored, .assigned])]
            expected = nil
        case .approved:
            after = [state(review: .approved, approved: true)]
            expected = (.approved, "kim.lee")
        case .changesRequested:
            after = [state(review: .requestedChanges)]
            expected = (.changesRequested, "kim.lee")
        case .reviewed:
            after = [state(review: .reviewed)]
            expected = (.reviewed, "kim.lee")
        case .pipelineFailed:
            after = [state(pipeline: .failed)]
            expected = (.pipelineFailed, nil)
        case .merged:
            after = []
            expected = (.merged, nil)
        case .closed:
            after = []
            expected = nil
        case .firstAfterLaunchLongAgo:
            after = [state(review: .approved, approved: true)]
            gap = 2 * 3600
            firstAfterLaunch = true
            expected = nil
        }
        let previous = InboxSnapshot.MergeRequests(items: before, takenAt: start)
        let current = InboxSnapshot.MergeRequests(items: after, takenAt: start.addingTimeInterval(gap))
        let merged: Set<URL> = change == .merged ? [url] : []

        let events = InboxEventDetector.mergeRequestEvents(
            from: previous, to: current, me: "alex.doe", merged: merged, firstAfterLaunch: firstAfterLaunch)

        #expect(events.map(\.kind) == (expected.map { [$0.0] } ?? []))
        #expect(events.map(\.actor?.username) == (expected.map { [$0.1] } ?? []))
        #expect(events.allSatisfy { $0.targetURL == url && $0.projectPath == "acme/web/app" })
        // Nothing before: the first load is the start.
        #expect(InboxEventDetector.mergeRequestEvents(from: nil, to: current, me: "alex.doe", firstAfterLaunch: false).isEmpty)
        // The same two loads again say nothing new.
        #expect(InboxEventDetector.mergeRequestEvents(from: current, to: current, me: "alex.doe", firstAfterLaunch: false).isEmpty)
    }

    @Test("INBOX-05 the same review from the to-dos and the merge request list is announced once")
    func coalescesAReview() {
        let url = Self.gitLab.appending(path: "acme/web/app/-/merge_requests/12")
        let todo = InboxEvent(
            id: "todo|gid://gitlab/Todo/7", kind: .reviewed, source: .todo, todoID: "gid://gitlab/Todo/7", title: "Retry",
            targetURL: url, occurredAt: Self.start)
        let list = InboxEvent(
            id: "approved|\(url)|kim.lee|1", kind: .approved, source: .mergeRequests, title: "Retry", targetURL: url,
            occurredAt: Self.start.addingTimeInterval(300))
        let failed = InboxEvent(
            id: "pipelineFailed|\(url)||1", kind: .pipelineFailed, source: .mergeRequests, title: "Retry", targetURL: url,
            occurredAt: Self.start.addingTimeInterval(300))

        let first = InboxEventDetector.unannounced([todo], in: InboxAnnouncements(), now: Self.start)
        let second = InboxEventDetector.unannounced([list, failed, failed], in: first.announcements, now: Self.start)
        // Much later, the same kind of news about the target is news again.
        let later = InboxEvent(
            id: "approved|\(url)|kim.lee|2", kind: .approved, source: .mergeRequests, title: "Retry", targetURL: url,
            occurredAt: Self.start.addingTimeInterval(7200))
        let third = InboxEventDetector.unannounced([later], in: second.announcements, now: Self.start.addingTimeInterval(7200))

        #expect(first.events == [todo])
        #expect(second.events == [failed])
        #expect(third.events == [later])
    }

    // MARK: - INBOX-06

    enum RouteCase: String, CaseIterable, Sendable {
        case assignedByDefault, mentionedByDefault, changedByTheUser, noBannerLeft
        case anotherProject, myProject, noProject
    }

    @Test("INBOX-06 routes per kind and only my projects", arguments: RouteCase.allCases)
    func routing(_ route: RouteCase) {
        var rules = InboxNotificationRules()
        var kind = InboxEventKind.assigned
        var project: String? = "acme/web/app"
        let now = Date(timeIntervalSince1970: 1_793_662_200)
        let expected: InboxRoutes
        switch route {
        case .assignedByDefault:
            expected = [.inbox, .badge]
        case .mentionedByDefault:
            kind = .mentioned
            expected = [.inbox, .badge]
        case .changedByTheUser:
            kind = .mentioned
            rules.set([.inbox], for: .mentioned)
            expected = [.inbox]
        case .noBannerLeft:
            // The bit of the macOS banner the app once had, in a value saved then.
            rules.overrides[kind.rawValue] = InboxRoutes(rawValue: 7)
            expected = [.inbox, .badge]
        case .anotherProject:
            rules.onlyMyProjects = true
            project = "acme/other/thing"
            expected = [.inbox]
        case .myProject:
            rules.onlyMyProjects = true
            expected = [.inbox, .badge]
        case .noProject:
            rules.onlyMyProjects = true
            project = nil
            expected = [.inbox, .badge]
        }
        let event = InboxEvent(id: "e", kind: kind, source: .todo, title: "Item", projectPath: project, occurredAt: now)

        #expect(rules.route(event, myProjects: ["acme/web/app"]) == expected)
        // Setting the default back keeps nothing.
        var reset = rules
        reset.set(kind.defaultRoutes, for: kind)
        #expect(reset.overrides.isEmpty)
    }

    @Test("INBOX-06 merge request changes go into the Inbox, and the badge counts what the rules say")
    func deliveredEvents() async throws {
        let world = try World()
        try world.answerFixture("InboxTodos", "todos.json")
        var rules = InboxNotificationRules()
        rules.set([.inbox], for: .otherTodo)
        let store = world.store(rules: rules)
        var delivered: [RoutedInboxEvent] = []
        store.onEvents = { delivered += $0 }
        await store.load()
        #expect(store.badgeCount == 5)

        let me = MergeRequest.Person(username: "alex.doe", name: "Alex Doe")
        func list(approved: Bool, pipeline: MergeRequest.PipelineStatus) -> MergeRequestList {
            MergeRequestList(username: "alex.doe", mergeRequests: [
                MergeRequest(
                    iid: 37, title: "Draw the chart with fewer points",
                    webURL: Self.gitLab.appending(path: "acme/web/app/-/merge_requests/37"), reference: "acme/web/app!37",
                    author: me,
                    reviewers: [.init(username: "kim.lee", name: "Kim Lee", reviewState: approved ? .approved : .unreviewed, approved: approved)],
                    pipelineStatus: pipeline, updatedAt: world.now, roles: [.authored]),
            ])
        }
        await store.mergeRequestsLoaded(list(approved: false, pipeline: .running))
        #expect(delivered.isEmpty)
        world.advance(60)
        await store.mergeRequestsLoaded(list(approved: true, pipeline: .running))

        #expect(delivered.map(\.event.kind) == [.approved])
        #expect(delivered.first?.routes == [.inbox, .badge])
        #expect(delivered.first?.event.headline == "Kim Lee approved !37")
        #expect(store.pending.first?.kind == .approved)
        #expect(store.badgeCount == 6)

        await store.markDone(try #require(store.pending.first))
        #expect(store.done.map(\.kind) == [.approved])
        #expect(store.badgeCount == 5)
        // Kept on this Mac: a relaunch has the entry, and doesn't announce it again.
        let next = world.store(rules: rules)
        #expect(next.done.map(\.kind) == [.approved])
    }

    @Test("INBOX-06 the routing is kept in the preferences")
    func routingIsKept() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        preferences.inboxNotifications.set([.inbox], for: .mentioned)
        preferences.inboxNotifications.onlyMyProjects = true

        store.save(preferences)

        #expect(PreferencesStore(defaults: suite.defaults).load().inboxNotifications == preferences.inboxNotifications)
        preferences.inboxNotifications = InboxNotificationRules()
        store.save(preferences)
        #expect(suite.defaults.object(forKey: PreferencesStore.inboxNotificationsKey) == nil)
        // Text that doesn't decode reads as the default.
        suite.defaults.set("{not json", forKey: PreferencesStore.inboxNotificationsKey)
        #expect(store.load().inboxNotifications == InboxNotificationRules())
    }
}

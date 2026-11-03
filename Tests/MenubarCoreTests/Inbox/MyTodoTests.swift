import Foundation
import Testing

@testable import MenubarCore

/// The user's own to-dos in the Inbox's "My To-Dos" group: added, ticked, restored, reordered, kept across a relaunch, and
/// never sent to GitLab (Task 7.03, INBOX-16).
@Suite("My to-dos", .timeLimit(.minutes(1)))
@MainActor
struct MyTodoTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    /// Monday 2026-11-02 09:00 UTC
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let team = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString, gitLabProject: "acme/web/app")

    private static func context() -> MyTodoLink.Context {
        MyTodoLink.Context(projects: [Project(id: .main, team: team)], primary: Project(id: .main, team: team))
    }

    /// An inbox store like one launch of the app, on a folder that outlives it.
    @MainActor
    private final class World {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let clock = TestClock()
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: MyTodoTests.team))
            let clock = clock
            let now: @Sendable () -> Date = { MyTodoTests.start.addingTimeInterval(Double(clock.now.offset.components.seconds)) }
            services = GitLabServices(
                transport: stub, clock: clock, now: now, tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }),
                log: ActivityLog(folder: folder.file("logs"), now: now))
        }

        func store() -> InboxStore {
            InboxStore(services: services, folder: folder.file("support"), calendar: MyTodoTests.utc)
        }
    }

    @Test(
        "INBOX-16 a pasted link or a bare !123 or #123 becomes the reference chip; a GitLab or Jenkins link leaves the title",
        arguments: [
            // text, title, kind, reference, url
            (
                "https://gitlab.example.com/acme/web/app/-/merge_requests/12 Review the retry", "Review the retry",
                MyTodoLink.Kind.mergeRequest, "acme/web/app!12", "https://gitlab.example.com/acme/web/app/-/merge_requests/12"
            ),
            (
                "https://gitlab.example.com/acme/web/app/-/work_items/7", "Work item #7", .workItem, "acme/web/app#7",
                "https://gitlab.example.com/acme/web/app/-/work_items/7"
            ),
            (
                "Check !123 before lunch", "Check !123 before lunch", .mergeRequest, "acme/web/app!123",
                "https://gitlab.example.com/acme/web/app/-/merge_requests/123"
            ),
            (
                "Answer (#45), then rest", "Answer (#45), then rest", .workItem, "acme/web/app#45",
                "https://gitlab.example.com/acme/web/app/-/work_items/45"
            ),
            (
                "https://jenkins.example.com/job/project/job/MR-12501/5/console", "Build of !12501", .build, "!12501",
                "https://jenkins.example.com/job/project/job/MR-12501/5/console"
            ),
            (
                "Read this https://docs.example.org/guide", "Read this", .web, nil, "https://docs.example.org/guide"
            ),
        ] as [(String, String, MyTodoLink.Kind, String?, String)])
    func linksBecomeChips(text: String, title: String, kind: MyTodoLink.Kind, reference: String?, url: String) {
        let parsed = MyTodoLink.parse(text, context: Self.context())
        #expect(parsed.title == title)
        #expect(parsed.link?.kind == kind)
        #expect(parsed.link?.reference == reference)
        #expect(parsed.link?.url.absoluteString == url)
    }

    @Test("INBOX-16 words without a link stay words; a bare number needs a project, and 0, #abc and 1!2 are no references")
    func plainWords() {
        for text in ["Water the plants", "Fix issue #abc", "Version 1!2", "Number !0", "Email ops@example.com"] {
            let parsed = MyTodoLink.parse(text, context: Self.context())
            #expect(parsed.link == nil)
            #expect(parsed.title == text)
        }
        // No project values: a bare number reads as text.
        #expect(MyTodoLink.parse("Look at !12", context: MyTodoLink.Context()).link == nil)
        #expect(MyTodoLink.parseLink("  https://gitlab.example.com/acme/web/app/-/issues/4 ", context: Self.context())?.reference == "acme/web/app#4")
        #expect(MyTodoLink.parseLink("not a link", context: Self.context()) == nil)
    }

    @Test("INBOX-16 a to-do is added on top, ticked into Done, restored, and counts in the badge until it is done")
    func addDoneRestore() async throws {
        let world = try World()
        let store = world.store()
        let first = try #require(store.addMyTodo("Water the plants"))
        world.clock.advance(by: .seconds(60))
        let second = try #require(store.addMyTodo(MyTodoDraft(
            title: "  Prepare the demo ", note: "  with the new inbox ", dueDate: Self.start.addingTimeInterval(86400))))
        #expect(store.addMyTodo("   ") == nil)

        // On top, in my order; the group is the first one.
        #expect(store.pending.filter(\.isMine).compactMap(\.myTodo?.id) == [second.id, first.id])
        let row = try #require(store.pending.first { $0.myTodo?.id == second.id })
        #expect(row.title == "Prepare the demo" && row.body == "with the new inbox")
        #expect(row.dueDate == Self.start.addingTimeInterval(86400))
        #expect(row.group == .myToDos && row.kind == .myTodo && !row.isLocalItem)
        #expect(store.sections.first?.group == .myToDos)
        #expect(store.badgeCount == 2)

        await store.markDone(row)
        #expect(store.pending.compactMap(\.myTodo?.id) == [first.id])
        #expect(store.done.compactMap(\.myTodo?.id) == [second.id])
        #expect(store.badgeCount == 1)

        await store.restore(try #require(store.done.first))
        #expect(store.pending.compactMap(\.myTodo?.id) == [second.id, first.id])
        #expect(store.done.isEmpty)

        // Mark All Done is for the notifications: my own list is left alone.
        await store.markAllDone()
        #expect(store.pending.count == 2)
        // Never GitLab.
        #expect(world.stub.requests.isEmpty)
    }

    @Test("INBOX-16 the badge counts my to-dos only while their Badge toggle is on")
    func badgeToggle() throws {
        let world = try World()
        let store = world.store()
        store.addMyTodo("One")
        store.addMyTodo("Two")
        #expect(store.badgeCount == 2)
        var rules = InboxNotificationRules()
        rules.set(.badge, false, for: .myTodo)
        store.rules = rules
        #expect(store.badgeCount == 0)
        #expect(store.pending.count == 2)
    }

    @Test("INBOX-16 a drag reorders the pending to-dos and leaves the done and snoozed ones where they are")
    func reorder() async throws {
        let world = try World()
        let store = world.store()
        let a = try #require(store.addMyTodo("A"))
        let b = try #require(store.addMyTodo("B"))
        let c = try #require(store.addMyTodo("C"))
        let d = try #require(store.addMyTodo("D"))
        // Newest on top: D, C, B, A. B is done in between.
        await store.markDone(try #require(store.pending.first { $0.myTodo?.id == b.id }))
        func shown() -> [String] { store.sections.first { $0.group == .myToDos }?.entries.compactMap { $0.myTodo?.title } ?? [] }
        #expect(shown() == ["D", "C", "A"])

        store.moveMyTodos(from: [2], to: 0)
        #expect(shown() == ["A", "D", "C"])
        store.moveMyTodos(from: [0], to: 3)
        #expect(shown() == ["D", "C", "A"])
        store.moveMyTodos(from: [0, 1], to: 3)
        #expect(shown() == ["A", "D", "C"])
        // The done one keeps its place in the list and comes back where it was.
        await store.restore(try #require(store.done.first))
        #expect(store.myTodos.map(\.title).contains("B"))
        #expect(Set(store.myTodos.map(\.id)) == [a.id, b.id, c.id, d.id])
    }

    @Test("INBOX-16 a to-do can be edited, snoozed and deleted, and a snoozed one wakes by itself")
    func editSnoozeDelete() async throws {
        let world = try World()
        let store = world.store()
        let todo = try #require(store.addMyTodo("Call the vendor"))

        let link = MyTodoLink.parseLink("https://gitlab.example.com/acme/web/app/-/merge_requests/9", context: store.linkContext)
        store.updateMyTodo(todo.id, with: MyTodoDraft(title: "Call the vendor back", note: "ask about the invoice", dueDate: Self.start, link: link))
        store.updateMyTodo(todo.id, with: MyTodoDraft(title: "   "))
        let row = try #require(store.pending.first)
        #expect(row.title == "Call the vendor back" && row.body == "ask about the invoice")
        #expect(row.reference == "acme/web/app!9" && row.targetURL?.lastPathComponent == "9")

        await store.snooze(row, .oneHour)
        #expect(store.pending.isEmpty && store.snoozed.compactMap(\.myTodo?.id) == [todo.id])
        #expect(store.badgeCount == 0)
        await world.clock.waitForSleepers()
        world.clock.advance(by: .seconds(3601))
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(store.pending.compactMap(\.myTodo?.id) == [todo.id])

        store.deleteMyTodo(todo.id)
        #expect(store.pending.isEmpty && store.snoozed.isEmpty && store.done.isEmpty)
    }

    @Test("INBOX-16 the to-dos are kept in the app's support folder across a relaunch, with their order, notes and done state")
    func persistence() async throws {
        let world = try World()
        let store = world.store()
        let a = try #require(store.addMyTodo("A https://gitlab.example.com/acme/web/app/-/merge_requests/3"))
        let b = try #require(store.addMyTodo(MyTodoDraft(title: "B", note: "note", dueDate: Self.start)))
        let c = try #require(store.addMyTodo("C"))
        await store.markDone(try #require(store.pending.first { $0.myTodo?.id == c.id }))
        store.moveMyTodos(from: [1], to: 0)

        let file = world.folder.file("support").appending(path: "Inbox/my-todos.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let next = world.store()
        #expect(next.myTodos.map(\.title) == store.myTodos.map(\.title))
        #expect(next.sections.first?.entries.compactMap(\.myTodo?.id) == [a.id, b.id])
        #expect(next.done.compactMap(\.myTodo?.id) == [c.id])
        let kept = try #require(next.myTodos.first { $0.id == b.id })
        #expect(kept.note == "note" && kept.dueDate == Self.start)
        #expect(next.myTodos.first { $0.id == a.id }?.link?.reference == "acme/web/app!3")
        #expect(world.stub.requests.isEmpty)

        // A done to-do goes after 90 days; a file with a field missing still reads.
        var list = MyTodoList(todos: [MyTodo(title: "Old", createdAt: Self.start, doneAt: Self.start)])
        list.prune(now: Self.start.addingTimeInterval(89 * 86400))
        #expect(list.todos.count == 1)
        list.prune(now: Self.start.addingTimeInterval(91 * 86400))
        #expect(list.todos.isEmpty)
        let bare = #"{"todos":[{"id":"x","title":"Bare","createdAt":0}]}"#
        let decoded = try JSONDecoder().decode(MyTodoList.self, from: Data(bare.utf8))
        #expect(decoded.todos.first?.note == "" && decoded.todos.first?.doneAt == nil)
    }
}

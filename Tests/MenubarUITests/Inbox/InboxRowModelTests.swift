import Foundation
import Testing

@testable import MenubarCore
@testable import MenubarUI

@Suite("Inbox rows")
@MainActor
struct InboxRowModelTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let person = MergeRequest.Person(username: "akim", name: "Alex Kim")

    private static func todo(
        _ action: InboxTodo.Action, reference: String? = "group/project!12", title: String = "Add a retry", body: String = "",
        author: MergeRequest.Person? = person, minutesAgo: Double = 5
    ) -> InboxEntry {
        InboxEntry(
            todo: InboxTodo(
                id: "gid://gitlab/Todo/1", action: action, targetKind: .mergeRequest, title: title, body: body,
                reference: reference, projectPath: "group/project", author: author,
                createdAt: now.addingTimeInterval(-minutesAgo * 60)))
    }

    @Test(
        "INBOX-07 line 1 says what happened and to what; line 2 has the chip, the author and the age",
        arguments: [
            (InboxTodo.Action.mentioned, "Mentioned you: Add a retry", true),
            (.reviewRequested, "Review requested: Add a retry", false),
            (.assigned, "Assigned to you: Add a retry", false),
            (.approvalRequired, "Approval requested: Add a retry", false),
            (.buildFailed, "Pipeline failed: Add a retry", false),
        ] as [(InboxTodo.Action, String, Bool)])
    func wordsOfARow(action: InboxTodo.Action, title: String, isMention: Bool) {
        let row = InboxRowModel(Self.todo(action), now: Self.now)
        #expect(row.title == title)
        #expect(row.isMention == isMention)
        #expect(row.age == "5m")
        #expect(row.author == InboxRowModel.Author(name: "Alex Kim", username: "akim"))
    }

    @Test("INBOX-07 a merge request's reference is a green chip, a work item's a blue one, an epic's too")
    func chips() {
        #expect(InboxRowModel(Self.todo(.mentioned, reference: "group/project!12"), now: Self.now).reference == .init(kind: .mergeRequest, text: "!12"))
        #expect(InboxRowModel(Self.todo(.mentioned, reference: "group/project#7"), now: Self.now).reference == .init(kind: .workItem, text: "#7"))
        #expect(InboxRowModel(Self.todo(.mentioned, reference: "group&3"), now: Self.now).reference == .init(kind: .workItem, text: "&3"))
        #expect(InboxRowModel(Self.todo(.mentioned, reference: nil), now: Self.now).reference == nil)
    }

    @Test("INBOX-07 the excerpt is the first line of GitLab's text and never the title again")
    func excerpt() {
        #expect(InboxRowModel(Self.todo(.mentioned, body: "\n  @jdoe look at this\nsecond line"), now: Self.now).excerpt == "@jdoe look at this")
        #expect(InboxRowModel(Self.todo(.mentioned, title: "Same", body: "Same"), now: Self.now).excerpt == nil)
    }

    @Test("INBOX-07 a snoozed row says when it wakes: today, tomorrow, the weekday, the date")
    func wakeText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10, minute: 42))!
        func text(days: Int, hour: Int) -> String {
            let date = calendar.date(byAdding: .day, value: days, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!)!
            return InboxRowModel.wakeText(date, now: now, calendar: calendar)
        }
        #expect(text(days: 0, hour: 14).hasPrefix("Until ") && !text(days: 0, hour: 14).contains("tomorrow"))
        #expect(text(days: 1, hour: 9).hasPrefix("Until tomorrow "))
        #expect(text(days: 4, hour: 9).hasPrefix("Until Sat "))
        #expect(text(days: 20, hour: 9).hasPrefix("Until Nov 23"))
    }

    @Test("INBOX-07 a thing of this app says it in its own words; a failed build is a green chip and its number")
    func localEntries() {
        let answer = InboxEvent.claudeAnswered(
            subjectKey: "mr:g/p!1", useCase: "Why Did It Fail?", failed: false, title: "Fix the login", reference: "g/p!1",
            excerpt: "# The cookie is rewritten", url: nil, at: Self.now)
        let row = InboxRowModel(InboxEntry(event: answer), now: Self.now)
        #expect(row.title == "Claude answered: Why Did It Fail?")
        #expect(row.excerpt == "The cookie is rewritten")
        #expect(row.subtitle == "Fix the login")
        #expect(row.author == nil)
        #expect(InboxOpening.isLocal(row.entry))

        let build = InboxEvent.buildFailed(
            jobKey: "main|MR-1", number: 5, label: "!12501 #5", isUnstable: false, title: "Fix the login",
            url: URL(string: "https://jenkins.example.com/job/x/5/")!, at: Self.now)
        let buildRow = InboxRowModel(InboxEntry(event: build), now: Self.now)
        #expect(buildRow.title == "Build !12501 #5 failed")
        #expect(buildRow.reference == .init(kind: .mergeRequest, text: "!12501"))
        #expect(buildRow.subtitle == "#5 · Fix the login")
        #expect(buildRow.tint == .build(.failed))
        #expect(!InboxOpening.isLocal(Self.todo(.mentioned)))
    }

    @Test("INBOX-07 the list groups the rows with Claude first, filters by group and project, and searches")
    func list() {
        let mention = Self.todo(.mentioned)
        let review = Self.todo(.reviewRequested, title: "Other thing")
        let answer = InboxEntry(
            event: InboxEvent.claudeAnswered(
                subjectKey: "k", useCase: "Q", failed: false, title: "T", reference: nil, excerpt: nil, url: nil, at: Self.now))
        let data = InboxData(now: Self.now, pending: [mention, review, answer], fetchedAt: Self.now)
        let all = InboxListModel(data, filter: InboxViewFilter(), query: "")
        // My To-Dos is first, with its add field, even while it has no rows.
        #expect(all.sections.map(\.group) == [.myToDos, .claude, .mentions, .reviewRequests])
        #expect(all.sections.first?.showsAddField == true && all.sections.first?.rows.isEmpty == true)
        #expect(InboxListModel(data, filter: InboxViewFilter(group: .mentions), query: "").rows.count == 1)
        #expect(InboxListModel(data, filter: InboxViewFilter(project: "nope"), query: "").empty?.title == "Nothing Here")
        #expect(InboxListModel(data, filter: InboxViewFilter(), query: "other thing").rows.count == 1)
        #expect(InboxListModel(data, filter: InboxViewFilter(), query: "zzz").findsNothing)
        // The states: nothing snoozed, the Done list not asked yet.
        #expect(InboxListModel(data, filter: InboxViewFilter(state: .snoozed), query: "").empty?.title == "Nothing Snoozed")
        var notLoaded = data
        notLoaded.hasLoadedDone = false
        #expect(InboxListModel(notLoaded, filter: InboxViewFilter(state: .done), query: "").isPlaceholder)
        // Nothing pending: My To-Dos and its add field stand, so there is no empty state over them.
        let zero = InboxListModel(InboxData(now: Self.now, fetchedAt: Self.now), filter: InboxViewFilter(), query: "")
        #expect(zero.sections.map(\.group) == [.myToDos] && zero.empty == nil)
        #expect(InboxListModel(InboxData(now: Self.now, fetchedAt: Self.now), filter: InboxViewFilter(state: .done), query: "").empty?.title == "Nothing Done Yet")
        // The first load shows bars; a failed first load shows the error alone.
        #expect(InboxListModel(InboxData(now: Self.now), filter: InboxViewFilter(), query: "").isPlaceholder)
        let failed = InboxListModel(InboxData(now: Self.now, problem: .unreachable(.gitLab)), filter: InboxViewFilter(), query: "")
        #expect(failed.failure != nil && failed.problems.isEmpty && !failed.showsFilterBar)
    }

    @Test("INBOX-07 the sidebar's badge and marker come from the Inbox, and the section sits second")
    func shell() {
        let panel = Fixtures().panel()
        let model = MainWindowShellModel(panel, section: .inbox, inbox: InboxShell(badge: 4, problem: .unreachable(.gitLab), subtitle: "Last checked 10:42"))
        #expect(model.badges[.inbox] == 4)
        #expect(model.markers[.inbox] == "GitLab problem")
        #expect(model.subtitle == "Last checked 10:42")
        // A missing token is a setup step, not a problem.
        #expect(MainWindowShellModel(panel, section: .pipelines, inbox: InboxShell(problem: .noToken(.gitLab))).markers[.inbox] == nil)
        #expect(MainWindowSection.allCases.prefix(2) == [.pipelines, .inbox])
    }
}

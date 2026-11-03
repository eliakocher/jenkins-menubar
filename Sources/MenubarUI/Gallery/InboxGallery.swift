#if DEBUG
import MenubarCore
import SwiftUI

extension Fixtures {
    private var sam: MergeRequest.Person { MergeRequest.Person(username: "slee", name: "Sam Lee") }
    private var alex: MergeRequest.Person { MergeRequest.Person(username: "akim", name: "Alex Kim") }
    private var jane: MergeRequest.Person { MergeRequest.Person(username: "jdoe", name: "Jane Doe") }
    private var projectPath: String { "group/subgroup/project" }
    private var gitLabHost: String { "https://gitlab.example.com/\(projectPath)" }

    /// A to-do of the Inbox, with its target's page.
    private func todo(
        _ number: Int, _ action: InboxTodo.Action, mergeRequest: Int? = nil, workItem: Int? = nil, _ title: String,
        by author: MergeRequest.Person?, ago: Double, body: String = "", state: InboxTodo.State = .pending
    ) -> InboxTodo {
        let isMergeRequest = mergeRequest != nil
        let iid = mergeRequest ?? workItem ?? 0
        return InboxTodo(
            id: "gid://gitlab/Todo/\(number)", action: action, targetKind: isMergeRequest ? .mergeRequest : .workItem, state: state,
            title: title, body: body,
            targetURL: URL(string: "\(gitLabHost)/-/\(isMergeRequest ? "merge_requests" : "work_items")/\(iid)"),
            reference: "\(projectPath)\(isMergeRequest ? "!" : "#")\(iid)", iid: iid, projectPath: projectPath, author: author,
            createdAt: minutesAgo(ago))
    }

    /// The pending rows of a busy morning, all groups: three mentions, two review requests, an assignment, a failed
    /// pipeline, a merge request that can't be merged, and what Claude and the build alert put in.
    var inboxPending: [InboxEntry] {
        let local: [InboxEvent] = [
            InboxEvent.claudeAnswered(
                subjectKey: "mr:\(projectPath)!204", useCase: "Why Did It Fail?", failed: false, title: "Fix the login redirect after a timeout",
                reference: "\(projectPath)!204", excerpt: "The redirect loops because the session cookie is rewritten before the check.",
                url: URL(string: "\(gitLabHost)/-/merge_requests/204"), at: minutesAgo(6)),
            InboxEvent.buildFailed(
                jobKey: "main|MR-16", number: 3, label: "!210 #3", isUnstable: false, title: "Add a retry to the export job",
                url: URL(string: "https://jenkins.example.com/job/project/job/MR-16/3/")!, at: minutesAgo(31)),
        ]
        let todos: [InboxTodo] = [
            todo(
                1, .mentioned, mergeRequest: 204, "Fix the login redirect after a timeout", by: sam, ago: 12,
                body: "@jdoe can you check the redirect when the session runs out? It loops on Safari."),
            todo(
                2, .mentioned, workItem: 31, "Rework the color tokens so the badges, the panel and the main window share one source of truth",
                by: jane, ago: 140, body: "@jdoe the dark values need your eye before we lock the slot."),
            todo(3, .directlyAddressed, workItem: 38, "Show the merge status in the tooltip", by: alex, ago: 60 * 20, body: "@jdoe thoughts?"),
            todo(4, .reviewRequested, mergeRequest: 210, "Add a retry to the export job", by: alex, ago: 25),
            todo(5, .approvalRequired, mergeRequest: 198, "Remove the old onboarding page", by: jane, ago: 60 * 26),
            todo(6, .assigned, workItem: 44, "Update the onboarding checklist", by: sam, ago: 190),
            todo(7, .buildFailed, mergeRequest: 204, "Fix the login redirect after a timeout", by: nil, ago: 40),
            todo(8, .unmergeable, mergeRequest: 187, "Move the color values into one file", by: nil, ago: 60 * 50),
        ]
        return (todos.map { InboxEntry(todo: $0) } + local.map { InboxEntry(event: $0) } + inboxCoffee + inboxMine).sorted { $0.date > $1.date }
    }

    /// today's coffee break, a local entry of its own group
    var inboxCoffee: [InboxEntry] {
        [InboxEntry(event: .coffeeBreak(line: "Warm cups, cold pipelines, that's the plan.", at: minutesAgo(103)))]
    }

    /// three to-dos of my own: one with a note and a date, one with a link, one overdue
    var inboxMine: [InboxEntry] {
        let day: TimeInterval = 86400
        let todos = [
            MyTodo(
                id: "a", title: "Prepare the demo for Thursday", note: "Walk through the new Inbox and the coffee break",
                dueDate: Calendar.current.startOfDay(for: now).addingTimeInterval(day), createdAt: minutesAgo(30)),
            MyTodo(
                id: "b", title: "Review the retry change",
                link: MyTodoLink(url: URL(string: "\(gitLabHost)/-/merge_requests/210")!, kind: .mergeRequest, reference: "\(projectPath)!210"),
                createdAt: minutesAgo(90)),
            MyTodo(
                id: "c", title: "Send the release notes to the team", dueDate: Calendar.current.startOfDay(for: now).addingTimeInterval(-day),
                createdAt: minutesAgo(60 * 20)),
        ]
        return todos.enumerated().map { InboxEntry(mine: $1, position: $0) }
    }

    /// a to-do of mine that is done
    var inboxMineDone: InboxEntry {
        InboxEntry(mine: MyTodo(id: "d", title: "Book the meeting room", createdAt: minutesAgo(60 * 30), doneAt: minutesAgo(60 * 3)))
    }

    /// two snoozed to-dos: one wakes this afternoon, one tomorrow morning
    var inboxSnoozed: [InboxEntry] {
        [
            InboxEntry(
                todo: todo(11, .reviewRequested, mergeRequest: 176, "Retry the upload when the connection drops", by: sam, ago: 60 * 5),
                snoozedUntil: now.addingTimeInterval(3 * 3600)),
            InboxEntry(
                todo: todo(12, .mentioned, workItem: 27, "Plan the next slot's code freeze", by: jane, ago: 60 * 9, body: "@jdoe please confirm the date."),
                snoozedUntil: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now.addingTimeInterval(86400))),
        ]
    }

    /// the last to-dos done, newest first
    var inboxDone: [InboxEntry] {
        [
            InboxEntry(todo: todo(21, .reviewRequested, mergeRequest: 190, "Rename the export columns", by: alex, ago: 60 * 3, state: .done)),
            InboxEntry(todo: todo(22, .mentioned, workItem: 29, "Dark mode for the report page", by: sam, ago: 60 * 8, body: "@jdoe looks fine?", state: .done)),
            InboxEntry(todo: todo(23, .assigned, workItem: 25, "Fix the flaky export test", by: jane, ago: 60 * 30, state: .done)),
            InboxEntry(todo: todo(24, .buildFailed, mergeRequest: 181, "Add a retry to the export job", by: nil, ago: 60 * 52, state: .done)),
            inboxMineDone,
        ]
    }

    /// the Inbox's data at 10:42, a typical morning
    func inboxData(
        pending: [InboxEntry]? = nil, snoozed: [InboxEntry]? = nil, done: [InboxEntry]? = nil, fetched: Bool = true,
        problem: Problem? = nil, actionProblem: Problem? = nil, hasLoadedDone: Bool = true
    ) -> InboxData {
        InboxData(
            now: now, pending: pending ?? inboxPending, snoozed: snoozed ?? inboxSnoozed, done: done ?? inboxDone,
            fetchedAt: fetched ? minutesAgo(1) : nil, problem: problem, actionProblem: actionProblem,
            hasLoadedDone: hasLoadedDone)
    }

    /// the Inbox right after an update: the unread "What's New" entry among a few pending rows
    func inboxWhatsNewData() -> InboxData {
        let sections = WhatsNewGallery.sections(from: "1.0.2", to: "1.0.4")
        let update = InboxEntry(
            event: .whatsNew(WhatsNewEntry(version: "1.0.4", from: "1.0.2", sections: sections), at: minutesAgo(2)))
        var data = inboxData(pending: [update] + inboxPending.prefix(4))
        data.unreadWhatsNew = update
        data.whatsNewSections = sections
        return data
    }

    /// the ids of the rows the gallery shows as opened
    var inboxSeen: Set<String> {
        ["gid://gitlab/Todo/2", "gid://gitlab/Todo/5"]
    }

    /// the pane's Inbox: the pending rows and their count
    var inboxPanel: PanelData.Inbox {
        let entries = inboxPending.filter { !$0.isMine }
        return PanelData.Inbox(entries: entries, badgeCount: entries.count)
    }
}

/// The whole main window with the Inbox selected, as the gallery shows it: the shell from fixtures and the list.
struct InboxGalleryView: View {
    let data: InboxData
    let panel: PanelData
    var filter = InboxViewFilter()
    var query = ""
    var seen: Set<String> = []
    /// the rows shown as just put back after GitLab refused their change
    var bounced: Set<String> = []
    var size = MainWindowGallerySize.standard

    var body: some View {
        let shell = InboxShell(
            badge: data.pending.count, problem: data.problem,
            subtitle: data.fetchedAt.map { Formatting.lastChecked($0) }, hasUnreadWhatsNew: data.unreadWhatsNew != nil)
        MainWindowGalleryView(
            model: MainWindowShellModel(panel, section: .inbox, inbox: shell), section: .inbox, searchText: query, size: size
        ) {
            InboxListContent(
                model: InboxListModel(data, filter: filter, query: query), filter: .constant(filter), actions: .none, links: .none)
                .environment(\.inboxIsSeen) { seen.contains($0) }
                .environment(\.inboxIsBounced) { bounced.contains($0) }
        } detail: {
            EmptyView()
        }
    }
}

extension GalleryCatalog {
    /// The Inbox in its states (INBOX-02): a typical morning with every group, the other filters, loading, an error, the
    /// empty state, narrow, and the pane's flyout.
    static var inboxEntries: [GalleryEntry] {
        let size = MainWindowGallerySize.standard
        let narrow = CGSize(width: MainWindowGallerySize.minimum.width, height: 640)
        return [
            GalleryEntry(screen: "inbox", state: "typical", size: CGSize(width: size.width, height: 820)) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), seen: f.inboxSeen, size: CGSize(width: size.width, height: 820))
            },
            // The first launch after an update: its card on top of the list, and the gift on the sidebar's Inbox row.
            GalleryEntry(screen: "inbox", state: "whats-new", size: size) { f in
                InboxGalleryView(data: f.inboxWhatsNewData(), panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "whats-new-narrow", size: narrow) { f in
                InboxGalleryView(data: f.inboxWhatsNewData(), panel: f.panel(), size: narrow)
            },
            // Reduce Motion: the same gradient, standing still.
            GalleryEntry(screen: "inbox", state: "whats-new-reduce-motion", size: size) { f in
                InboxGalleryView(data: f.inboxWhatsNewData(), panel: f.panel())
                    .environment(\._accessibilityReduceMotion, true)
            },
            // Opened or dismissed: an ordinary row in its group, no card, no gift.
            GalleryEntry(screen: "inbox", state: "whats-new-seen", size: size) { f in
                var data = f.inboxWhatsNewData()
                data.unreadWhatsNew = nil
                return InboxGalleryView(data: data, panel: f.panel())
            },
            // The pane's Inbox row wears the gift too.
            GalleryEntry(screen: "inbox", state: "pane-whats-new", size: CGSize(width: 400, height: 520)) { f in
                var data = f.menuPaneData
                data.inbox = PanelData.Inbox(entries: f.inboxPending.filter { !$0.isMine }, badgeCount: 3, hasUnreadWhatsNew: true)
                return MenuPaneGalleryView(data: data)
            },
            GalleryEntry(screen: "inbox", state: "snoozed", size: size) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), filter: InboxViewFilter(state: .snoozed))
            },
            GalleryEntry(screen: "inbox", state: "done", size: size) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), filter: InboxViewFilter(state: .done))
            },
            GalleryEntry(screen: "inbox", state: "done-loading", size: size) { f in
                InboxGalleryView(
                    data: f.inboxData(hasLoadedDone: false), panel: f.panel(), filter: InboxViewFilter(state: .done))
            },
            GalleryEntry(screen: "inbox", state: "filtered", size: size) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), filter: InboxViewFilter(group: .mentions))
            },
            GalleryEntry(screen: "inbox", state: "search", size: size) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), query: "export")
            },
            GalleryEntry(screen: "inbox", state: "empty", size: size) { f in
                InboxGalleryView(data: f.inboxData(pending: [], snoozed: [], done: []), panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "loading", size: size) { f in
                InboxGalleryView(data: f.inboxData(pending: [], snoozed: [], done: [], fetched: false), panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "error", size: size) { f in
                InboxGalleryView(
                    data: f.inboxData(pending: [], snoozed: [], done: [], fetched: false, problem: .unreachable(.gitLab)),
                    panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "error-with-rows", size: size) { f in
                InboxGalleryView(data: f.inboxData(problem: .unreachable(.gitLab)), panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "action-problem", size: size) { f in
                InboxGalleryView(
                    data: f.inboxData(actionProblem: .unreachable(.gitLab)), panel: f.panel(), seen: f.inboxSeen)
            },
            GalleryEntry(screen: "inbox", state: "action-read-only-token", size: size) { f in
                InboxGalleryView(
                    data: f.inboxData(actionProblem: .readOnlyToken(action: "Mark Done")), panel: f.panel(), seen: f.inboxSeen,
                    bounced: ["gid://gitlab/Todo/1"])
            },
            GalleryEntry(screen: "inbox", state: "no-token", size: size) { f in
                InboxGalleryView(
                    data: f.inboxData(pending: f.inboxMine, snoozed: [], done: [], fetched: false, problem: .noToken(.gitLab)),
                    panel: f.panel())
            },
            GalleryEntry(screen: "inbox", state: "narrow", size: narrow) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), seen: f.inboxSeen, size: narrow)
            },
            GalleryEntry(screen: "inbox", state: "pane-flyout", size: CGSize(width: 800, height: 640)) { f in
                MenuPaneGalleryView(data: f.menuPaneData, open: .inbox, flyoutHighlight: 1)
                    .environment(\.inboxIsSeen) { f.inboxSeen.contains($0) }
            },
            GalleryEntry(screen: "inbox", state: "pane-flyout-refused", size: CGSize(width: 800, height: 640)) { f in
                var data = f.menuPaneData
                data.inbox.actionProblem = .readOnlyToken(action: "Mark Done")
                return MenuPaneGalleryView(data: data, open: .inbox, flyoutHighlight: 1)
                    .environment(\.inboxIsSeen) { f.inboxSeen.contains($0) }
            },
            GalleryEntry(screen: "inbox", state: "my-todos-empty", size: CGSize(width: size.width, height: 520)) { f in
                InboxGalleryView(
                    data: f.inboxData(pending: [], snoozed: [], done: []), panel: f.panel(),
                    size: CGSize(width: size.width, height: 520))
            },
            GalleryEntry(screen: "inbox", state: "my-todos-filtered", size: size) { f in
                InboxGalleryView(data: f.inboxData(), panel: f.panel(), filter: InboxViewFilter(group: .myToDos))
            },
            GalleryEntry(screen: "inbox", state: "my-order-builds-first", size: CGSize(width: size.width, height: 820)) { f in
                var data = f.inboxData()
                data.groupOrder = [.builds, .claude, .mentions, .reviewRequests, .assigned, .myToDos, .coffee, .other]
                return InboxGalleryView(data: data, panel: f.panel(), seen: f.inboxSeen, size: CGSize(width: size.width, height: 820))
            },
            GalleryEntry(screen: "inbox", state: "todo-sheet", size: CGSize(width: 380, height: 330)) { f in
                MyTodoSheet(target: .edit(f.inboxMine[0].myTodo!), parseLink: { _ in nil }, save: { _ in }, cancel: {})
            },
            GalleryEntry(screen: "inbox", state: "pane-flyout-empty", size: CGSize(width: 800, height: 520)) { f in
                var data = f.menuPaneData
                data.inbox = PanelData.Inbox()
                return MenuPaneGalleryView(data: data, open: .inbox)
            },
        ]
    }
}
#endif

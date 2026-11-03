import Foundation
import MenubarCore

/// What the Inbox shows of the store at one moment, as plain values: the three lists, what loaded and the problems. The
/// list view takes it from the store (``init(_:now:)``); the gallery and the tests build it from fixtures.
struct InboxData: Sendable {
    var now: Date
    var pending: [InboxEntry]
    var snoozed: [InboxEntry]
    var done: [InboxEntry]
    /// `nil` before the first load
    var fetchedAt: Date?
    /// the problem of the last load; `.noToken(.gitLab)` shows the setup steps (MR-04)
    var problem: Problem?
    /// the problem of the last Done, Restore or Snooze that failed and was put back
    var actionProblem: Problem?
    /// whether the done list was loaded at least once, and whether it loads now
    var hasLoadedDone: Bool
    var isLoadingDone: Bool
    /// whether a load of the to-dos runs
    var isLoading: Bool
    /// the app-wide problem rows: offline, the team values, a failed update
    var appWideProblems: [PanelModel.ProblemItem]
    /// whether the team values are missing (TEAM-03), which shows their row alone
    var teamValuesMissing: Bool
    /// the groups in the user's order (Settings → Notifications)
    var groupOrder: [InboxGroup]

    init(
        now: Date, pending: [InboxEntry] = [], snoozed: [InboxEntry] = [], done: [InboxEntry] = [], fetchedAt: Date? = nil,
        problem: Problem? = nil, actionProblem: Problem? = nil, hasLoadedDone: Bool = true, isLoadingDone: Bool = false,
        isLoading: Bool = false, appWideProblems: [PanelModel.ProblemItem] = [], teamValuesMissing: Bool = false,
        groupOrder: [InboxGroup] = InboxGroup.allCases
    ) {
        self.now = now
        self.pending = pending
        self.snoozed = snoozed
        self.done = done
        self.fetchedAt = fetchedAt
        self.problem = problem
        self.actionProblem = actionProblem
        self.hasLoadedDone = hasLoadedDone
        self.isLoadingDone = isLoadingDone
        self.isLoading = isLoading
        self.appWideProblems = appWideProblems
        self.teamValuesMissing = teamValuesMissing
        self.groupOrder = groupOrder
    }

    /// Returns what the store holds now. It reads the lists, so only the Inbox list calls it, not the window's root.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - now: the time the ages count from
    @MainActor
    init(_ model: AppModel, now: Date) {
        let store = model.inbox
        self.init(
            now: now, pending: store.pending, snoozed: store.snoozed, done: store.done, fetchedAt: store.fetchedAt,
            problem: store.problem, actionProblem: store.actionProblem, hasLoadedDone: store.hasLoadedDone,
            isLoadingDone: store.isLoadingDone, isLoading: store.isLoading,
            appWideProblems: MainWindowProblems.appWide(jenkins: model.projects.problem, update: model.updates.state),
            teamValuesMissing: MainWindowProblems.teamValuesMissing(model.projects.problem),
            groupOrder: store.rules.groupOrder)
    }
}

/// What the Inbox list is filtered by: the state, and maybe one group or one project (INBOX-02).
struct InboxViewFilter: Hashable, Sendable {
    var state: InboxFilter.State = .pending
    var group: InboxGroup?
    var project: String?

    /// whether a group or a project narrows the list
    var isNarrowed: Bool { group != nil || project != nil }
}

/// What the Inbox list shows of an ``InboxData`` after the filter and the search: the problem rows, the groups with their
/// rows, or the placeholders, the error, or the empty state (INBOX-02).
struct InboxListModel: Sendable {
    /// the red rows on top: the app-wide ones, then the load's own
    var problems: [PanelModel.ProblemItem]
    /// a failed Done, Restore or Snooze, which was put back: a quiet banner
    var actionNote: String?
    /// no GitLab token: the setup steps stand in for the rows (MR-04)
    var needsToken: Bool
    /// rows of bars: the first load, or the first look at the Done list
    var isPlaceholder: Bool
    /// a load that failed with nothing to show: the error with Try Again
    var failure: String?
    /// the groups that have rows after the filter and the search, in the Inbox's order
    var sections: [Section]
    /// the empty state's words; `nil` while rows show
    var empty: Empty?
    /// the filter and the search text, trimmed
    var filter: InboxViewFilter
    var query: String
    /// how many to-dos each state has, for the filter's labels; the done count only after it loaded
    var pendingCount: Int
    var snoozedCount: Int
    var doneCount: Int?
    /// the projects the filter menu lists
    var projects: [String]
    /// how many rows Mark All Done would clear: every pending row, whatever the filter, as GitLab's does
    var markAllCount: Int

    /// One group of rows.
    struct Section: Hashable, Sendable, Identifiable {
        var group: InboxGroup
        var rows: [InboxRowModel]
        /// whether the "Add a To-Do…" field sits at the top of the group: My To-Dos, while pending rows show
        var showsAddField = false

        /// whether a drag can reorder the rows: my own to-dos in the pending list, with nothing narrowing it
        var canReorder = false

        var id: InboxGroup { group }
        var title: String { group.title }
    }

    /// The empty state: a title and a line.
    struct Empty: Hashable, Sendable {
        var title: String
        var detail: String
        var symbol: String
    }

    /// whether the filter bar shows: not without a token, and not over the error that has nothing to filter
    var showsFilterBar: Bool { !needsToken && failure == nil }

    /// whether the search finds nothing, which shows the system's no-results view
    var findsNothing: Bool {
        !query.isEmpty && empty != nil
    }

    /// the rows of every group, in the list's order
    var rows: [InboxRowModel] {
        sections.flatMap(\.rows)
    }

    /// Returns the row with an id.
    func row(_ id: String) -> InboxRowModel? {
        rows.first { $0.id == id }
    }

    /// Returns what the list shows.
    ///
    /// - Parameters:
    ///   - data: the store's values
    ///   - filter: the state, the group and the project
    ///   - query: the window's search text; empty shows everything
    ///   - calendar: the user's calendar, for the wake times
    init(_ data: InboxData, filter: InboxViewFilter, query: String, calendar: Calendar = .current) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filter = filter
        self.query = query
        pendingCount = data.pending.count
        snoozedCount = data.snoozed.count
        doneCount = data.hasLoadedDone ? data.done.count : nil
        // My own to-dos are my list, not notifications: Mark All Done leaves them.
        markAllCount = data.pending.count { !$0.isMine }
        projects = Set((data.pending + data.snoozed + data.done).compactMap(\.projectPath)).sorted()
        problems = data.appWideProblems
        actionNote = data.actionProblem?.message
        needsToken = data.problem == .noToken(.gitLab)
        isPlaceholder = false
        failure = nil
        sections = []
        empty = nil
        // TEAM-03 shows alone: nothing can be asked without the values.
        guard !data.teamValuesMissing else {
            return
        }
        // Offline shows the cached rows without another problem row (OD-05); a missing token shows the steps instead.
        guard !needsToken else {
            return
        }
        let neverLoaded = data.fetchedAt == nil
        if !neverLoaded, let problem = data.problem, problem != .offline {
            problems.append(PanelModel.problemItem(problem))
        }
        if neverLoaded {
            // The first load: bars, unless a problem says why nothing came.
            if data.problem == nil {
                isPlaceholder = true
            } else if let problem = data.problem {
                failure = problem.message
            }
            return
        }
        if filter.state == .done, !data.hasLoadedDone {
            isPlaceholder = data.isLoadingDone || query.isEmpty
            return
        }
        let source =
            switch filter.state {
            case .pending: data.pending
            case .snoozed: data.snoozed
            case .done: data.done
            }
        let rows = source
            .filter { (filter.group == nil || $0.group == filter.group) && (filter.project == nil || $0.projectPath == filter.project) }
            .map { InboxRowModel($0, now: data.now, calendar: calendar) }
            .filter { $0.matches(query) }
        // The add field shows while the pending list isn't narrowed or searched, so My To-Dos is there even when empty.
        let addsTodos = filter.state == .pending && query.isEmpty && filter.project == nil
            && (filter.group == nil || filter.group == .myToDos)
        sections = InboxGroupOrder.merged(stored: data.groupOrder.map(\.rawValue)).compactMap { group in
            let inGroup = rows.filter { $0.entry.group == group }
            if group == .myToDos, addsTodos {
                return Section(group: group, rows: inGroup, showsAddField: true, canReorder: true)
            }
            return inGroup.isEmpty ? nil : Section(group: group, rows: inGroup)
        }
        if sections.isEmpty {
            empty = Self.empty(filter: filter, query: query)
        }
    }

    /// Returns the words of an empty list.
    static func empty(filter: InboxViewFilter, query: String) -> Empty {
        if !query.isEmpty {
            return Empty(title: "No Results", detail: "Nothing in \(filter.state.title) matches “\(query)”.", symbol: "magnifyingglass")
        }
        if filter.isNarrowed {
            return Empty(title: "Nothing Here", detail: "No \(filter.state.title.lowercased()) to-dos match the filter.", symbol: "line.3.horizontal.decrease.circle")
        }
        switch filter.state {
        case .pending: return Empty(title: "Inbox Zero", detail: "Nothing needs you right now.", symbol: "tray")
        case .snoozed: return Empty(title: "Nothing Snoozed", detail: "Snoozed to-dos wait here until their time comes.", symbol: "moon.zzz")
        case .done: return Empty(title: "Nothing Done Yet", detail: "The to-dos you finish show up here.", symbol: "checkmark.circle")
        }
    }
}

extension InboxGroup {
    /// The groups in their default order, for what has no user order at hand, like the pane's summary line; the window and
    /// the flyout follow ``InboxNotificationRules/groupOrder`` (INBOX-15).
    static let displayOrder: [InboxGroup] = allCases

    /// the group's symbol in Settings → Notifications and the Inbox's filter
    var systemImage: String {
        switch self {
        case .myToDos: "checklist"
        case .coffee: "cup.and.saucer.fill"
        case .claude: "sparkles"
        case .mentions: "at"
        case .reviewRequests: "eye.circle.fill"
        case .assigned: "person.crop.circle.fill"
        case .builds: "hammer.fill"
        case .other: "tray.fill"
        }
    }
}

extension InboxFilter.State {
    /// the state's name in the filter, in Title Style
    var title: String {
        switch self {
        case .pending: "Pending"
        case .snoozed: "Snoozed"
        case .done: "Done"
        }
    }
}

import Foundation
import Observation

extension CacheFile where Value == InboxTodoList {
    /// the pending and snoozed to-dos of the last load, so the Inbox shows at once after a relaunch (OD-01)
    public static var inboxTodos: CacheFile { CacheFile("inbox-todos") }
}

/// The Inbox: GitLab's To-Do List with Snooze, and the events between two polls (Task 7.03, INBOX-01 … INBOX-06).
///
/// - The lists (pending, snoozed, done), their groups and the badge count are ready to draw; the cached to-dos show
///   at once (OD-01).
/// - Done, Restore, Mark All Done and Snooze change the lists at once and go to GitLab; a failure puts the lists back
///   and sets ``actionProblem``. A GitLab without the snooze mutations snoozes on this Mac.
/// - A snoozed to-do comes back to the pending list when its time comes, on the injected clock.
/// - The ``Scheduler`` loads it with the other GitLab data, whatever is shown (`Surface.inbox`): every maximum age
///   while someone looks, every 5 minutes otherwise (OD-06). The merge request list's loads feed
///   ``mergeRequestsLoaded(_:)``.
/// - Each load finds the new events, leaves out those announced before (kept on disk, across restarts), routes them by
///   ``rules`` and hands them to ``onEvents``; those routed to the Inbox that aren't to-dos become local entries. There
///   are no macOS banners (the user, 2026-11-03): the Inbox, its badge and the menu bar's count are the notification.
/// - Things of this app go in the same way, as local entries that never reach GitLab (``addLocal(_:)``): a Claude answer
///   that landed while its card wasn't on screen, and the morning digest.
@Observable @MainActor
public final class InboxStore {
    /// the key of its problem in the ``ProblemTracker``
    public nonisolated static let problemKey = "gitlab.inbox"
    /// the most recent events kept in ``recentEvents``
    public nonisolated static let recentLimit = 50

    /// the pending rows: the to-dos that aren't snoozed and the local entries not done, newest first
    public private(set) var pending: [InboxEntry] = []
    /// the snoozed to-dos, the soonest to wake first
    public private(set) var snoozed: [InboxEntry] = []
    /// the done to-dos (once ``loadDone()`` ran, and those marked done here) and the done local entries, newest first
    public private(set) var done: [InboxEntry] = []
    /// the badge: the pending rows whose kind counts in it (INBOX-06), plus the pending to-dos beyond the first 100
    public private(set) var badgeCount = 0
    /// when the to-dos were loaded
    public private(set) var fetchedAt: Date?
    /// when the last load ended, whether it worked or not
    public private(set) var lastLoadAt: Date?
    /// the problem of the last load; ``Problem/noToken(_:)`` shows the setup steps (MR-04)
    public private(set) var problem: Problem?
    /// the problem of the last Done, Restore or Snooze that failed and was put back; `nil` after one that worked
    public private(set) var actionProblem: Problem?
    /// the rows GitLab refused a change of and that were put back, for a moment: the list shakes and tints them
    public private(set) var bouncedIDs: Set<String> = []
    /// whether a load is under way
    public private(set) var isLoading = false
    /// whether the done to-dos were loaded at least once
    public private(set) var hasLoadedDone = false
    /// whether the done to-dos are being loaded
    public private(set) var isLoadingDone = false
    /// the events announced since launch, newest first, ``recentLimit`` at most
    public private(set) var recentEvents: [RoutedInboxEvent] = []
    /// the routing of the events; Settings → Notifications edits it through ``Preferences/inboxNotifications``
    public var rules: InboxNotificationRules {
        didSet { rebuild() }
    }

    /// called with each load's new events that go somewhere
    @ObservationIgnored public var onEvents: @MainActor ([RoutedInboxEvent]) -> Void = { _ in }

    /// the rows the user opened, which the list shows faded; opening one doesn't mark it done
    @ObservationIgnored public let seen: InboxSeen

    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private let project: ProjectID
    @ObservationIgnored private let stateFile: FileStore<InboxState>
    @ObservationIgnored private let myTodosFile: FileStore<MyTodoList>
    @ObservationIgnored private var mine: MyTodoList
    @ObservationIgnored private let myProjects: @Sendable () -> Set<String>
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var state: InboxState
    @ObservationIgnored private var server: InboxTodoList?
    @ObservationIgnored private var serverDone: [InboxTodo]?
    /// the changes made here that GitLab may not show yet, by to-do id
    @ObservationIgnored private var overrides: [String: Override] = [:]
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var loadsStarted = 0
    @ObservationIgnored private var detectedTodosSinceLaunch = false
    @ObservationIgnored private var detectedMergeRequestsSinceLaunch = false
    @ObservationIgnored private var wake: (task: Task<Void, Never>, at: Date)?

    /// A change made here, shown until a load that started after GitLab took it.
    private struct Override {
        var todo: InboxTodo
        var place: Place
        var serial: Int
        /// the last load started when GitLab took the change; a load after it shows GitLab's state; `nil` while the
        /// request is under way
        var settledAfterLoad: Int?
    }

    private enum Place: Equatable {
        case pending
        case snoozed(until: Date)
        case done
    }

    /// Creates the store with the cached to-dos and the kept state. Nothing is asked yet.
    ///
    /// - Parameters:
    ///   - services: the transport, the token, the team values, the caches and the logs
    ///   - folder: the app's support folder; the state goes in `Inbox/state.json`
    ///   - rules: the routing of the events
    ///   - myProjects: the full paths of my projects, for "only my projects"
    ///   - calendar: the calendar of the snooze choices and the quiet hours
    public init(
        services: GitLabServices, folder: URL, rules: InboxNotificationRules = InboxNotificationRules(),
        myProjects: @escaping @Sendable () -> Set<String> = { [] }, calendar: Calendar = .current
    ) {
        self.services = services
        self.rules = rules
        self.myProjects = myProjects
        self.calendar = calendar
        project = services.team.primaryProject().id
        let report: @Sendable (String) -> Void = { [log = services.log] message in
            Task { await log.log(.warning, .app, message) }
        }
        stateFile = FileStore(url: folder.appending(path: "Inbox/state.json", directoryHint: .notDirectory), report: report)
        state = stateFile.load() ?? InboxState()
        myTodosFile = FileStore(
            url: folder.appending(path: "Inbox/my-todos.json", directoryHint: .notDirectory), report: report)
        mine = myTodosFile.load() ?? MyTodoList()
        mine.prune(now: services.now())
        seen = InboxSeen(
            file: FileStore(url: folder.appending(path: "Inbox/seen.json", directoryHint: .notDirectory), report: report),
            now: services.now)
        if let cached = services.caches.load(.inboxTodos, for: project) {
            server = cached.value
            fetchedAt = cached.fetchedAt
            lastLoadAt = cached.fetchedAt
            problem = cached.problem
        }
        rebuild()
    }

    // MARK: - What the views show

    /// the pending rows in their groups (INBOX-02)
    public var sections: [InboxSection] {
        InboxSection.grouped(pending, order: rules.groupOrder)
    }

    /// Returns the rows of a filter.
    ///
    /// - Parameter filter: the state, and maybe one group or project
    /// - Returns: the rows, in the list's order
    public func entries(_ filter: InboxFilter) -> [InboxEntry] {
        let rows = switch filter.state {
        case .pending: pending
        case .snoozed: snoozed
        case .done: done
        }
        return rows.filter(filter.includes)
    }

    /// Returns the rows of a filter in their groups.
    ///
    /// - Parameter filter: the state, and maybe one group or project
    /// - Returns: the sections
    public func sections(_ filter: InboxFilter) -> [InboxSection] {
        InboxSection.grouped(entries(filter), order: rules.groupOrder)
    }

    /// the projects of the rows, for the project filter, sorted
    public var projects: [String] {
        Set((pending + snoozed + done).compactMap(\.projectPath)).sorted()
    }

    /// whether GitLab snoozes the to-dos; `false` once it turned out not to, and they sleep on this Mac
    public var snoozesInGitLab: Bool {
        state.snoozesInGitLab ?? (state.level != .basic)
    }

    // MARK: - Loading

    /// Loads the pending and snoozed to-dos, finds the new events and announces them.
    ///
    /// - Without a GitLab token, it asks nothing and forgets the to-dos (MR-04).
    /// - A failed load keeps the to-dos and saves its problem with them (MR-05).
    /// - A GitLab that refuses the snooze fields is asked at the basic level from then on.
    public func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        loadsStarted += 1
        let number = loadsStarted
        let problem: Problem?
        switch await services.session() {
        case .failure(let refusal):
            if refusal.problem == .noToken(.gitLab) {
                tokenRemoved()
            }
            problem = refusal.problem
        case .success(let session):
            do {
                let list = try await fetch { try await session.client.send(.inboxTodos(level: $0)) }
                apply(list, load: number)
                problem = nil
            } catch let error as GitLabError where !Task.isCancelled {
                problem = error.problem
            } catch {
                // Cancelled, as sleep does.
                return
            }
        }
        self.problem = problem
        lastLoadAt = services.now()
        saveCache()
        await services.track(Self.problemKey, problem)
    }

    /// Loads the 50 newest done to-dos, for the Done list. Asked only while it shows.
    public func loadDone() async {
        guard !isLoadingDone, case .success(let session) = await services.session() else {
            return
        }
        isLoadingDone = true
        defer { isLoadingDone = false }
        do {
            serverDone = try await fetch { try await session.client.send(.doneTodos(level: $0)) }
            hasLoadedDone = true
            rebuild()
        } catch {
            // The Done list keeps what it had; the next look asks again.
        }
    }

    /// Asks at the level the GitLab answered last; the full level once, then the basic one when GitLab refuses its
    /// fields.
    private func fetch<Value>(_ send: (TodoQueryLevel) async throws -> Value) async throws -> Value {
        let level = state.level ?? .full
        do {
            let value = try await services.measure { try await send(level) }
            if state.level == nil {
                state.level = level
                saveState()
            }
            return value
        } catch let error as GitLabError where level == .full && error.namesMissingTodoField {
            state.level = .basic
            saveState()
            log(.info, "Inbox: this GitLab has no to-do snooze; snoozing on this Mac")
            return try await services.measure { try await send(.basic) }
        }
    }

    private func apply(_ list: InboxTodoList, load number: Int) {
        let now = services.now()
        server = list
        fetchedAt = now
        // A change GitLab took before this load started is in its answer now.
        overrides = overrides.filter { $0.value.settledAfterLoad.map { $0 >= number } ?? true }
        rebuild()

        let events = InboxEventDetector.todoEvents(
            list.pending, since: state.snapshot.todos, now: now, firstAfterLaunch: !detectedTodosSinceLaunch)
        detectedTodosSinceLaunch = true
        state.snapshot.todos = InboxSnapshot.Todos(ids: Set((list.pending + list.snoozed).map(\.id)), takenAt: now)
        announce(events, now: now)
    }

    /// Finds the events between this load of my merge requests and the last one: review requested, assigned, and on
    /// my own MRs approved, changes requested, reviewed, pipeline failed, merged (INBOX-05). An MR of mine gone from
    /// the list is asked about, once: merged or closed.
    ///
    /// - Parameter list: the merge request list just loaded
    public func mergeRequestsLoaded(_ list: MergeRequestList) async {
        let now = services.now()
        let current = InboxSnapshot.MergeRequests(list, takenAt: now)
        let previous = state.snapshot.mergeRequests
        let firstAfterLaunch = !detectedMergeRequestsSinceLaunch
        detectedMergeRequestsSinceLaunch = true
        state.snapshot.mergeRequests = current
        var merged: Set<URL> = []
        let vanished = InboxEventDetector.vanishedAuthored(from: previous, to: current)
        if !vanished.isEmpty, case .success(let session) = await services.session() {
            for (path, items) in Dictionary(grouping: vanished, by: \.path) {
                let iids = try? await session.client.send(.mergedMergeRequests(project: path, iids: items.map(\.iid)))
                merged.formUnion(items.filter { iids?.contains($0.iid) == true }.map(\.url))
            }
        }
        let events = InboxEventDetector.mergeRequestEvents(
            from: previous, to: current, me: list.username, merged: merged, firstAfterLaunch: firstAfterLaunch)
        announce(events, now: services.now())
    }

    /// Adds an item of this app to the Inbox: a Claude answer that landed while its card wasn't on screen, the morning
    /// digest, a failed build. It is routed like any event (Settings → Notifications can turn its kind off), kept on
    /// this Mac across restarts, and never goes to GitLab: Done only moves it to the Done list here. The same id twice
    /// adds it once.
    ///
    /// - Parameter event: the item, built by the `InboxEvent` factories for Claude's answers, the digest and the failed
    ///   builds; its source is ``InboxEvent/Source/local``
    public func addLocal(_ event: InboxEvent) {
        announce([event], now: services.now())
    }

    /// Whether an event was announced before, on this launch or an earlier one (kept 14 days): the same id is never
    /// added twice, so the daily items check it before they spend a Claude run on today's.
    ///
    /// - Parameter id: the event's id
    public func wasAnnounced(_ id: String) -> Bool {
        state.announcements.entries.contains { $0.id == id }
    }

    /// Marks the pending local items of a kind whose id starts with a prefix done: a later green build clears the failed
    /// entries of its job.
    ///
    /// - Parameters:
    ///   - kind: the kind
    ///   - idPrefix: the start of the ids
    ///   - except: an id to leave pending: today's coffee break stays when yesterday's clears
    public func resolveLocal(kind: InboxEventKind, idPrefix: String, except: String? = nil) {
        let now = services.now()
        var changed = false
        for index in state.localEntries.indices {
            let entry = state.localEntries[index]
            if entry.doneAt == nil, entry.event.kind == kind, entry.event.id.hasPrefix(idPrefix), entry.event.id != except {
                state.localEntries[index].doneAt = now
                changed = true
            }
        }
        if changed {
            saveState()
            rebuild()
        }
    }

    /// Leaves out what was announced, routes the rest, keeps the local entries and the state, and hands the events on.
    private func announce(_ events: [InboxEvent], now: Date) {
        let (fresh, announcements) = InboxEventDetector.unannounced(events, in: state.announcements, now: now)
        state.announcements = announcements
        let mine = myProjects()
        // Something that goes nowhere but announces itself, like a coffee break set to a panel with the Inbox off, still counts.
        let routed = fresh.map {
            RoutedInboxEvent(event: $0, routes: rules.route($0, myProjects: mine), delivery: rules.delivery(for: $0.kind))
        }.filter { !$0.routes.isEmpty || $0.delivery != .inboxOnly }
        for item in routed where item.event.source != .todo && item.routes.contains(.inbox) {
            state.localEntries.append(InboxLocalEntry(event: item.event))
        }
        state.pruneLocalEntries(now: now)
        saveState()
        guard !routed.isEmpty else {
            return
        }
        rebuild()
        recentEvents = Array((routed.reversed() + recentEvents).prefix(Self.recentLimit))
        for item in routed {
            log(.info, "Inbox: \(item.event.headline)")
        }
        onEvents(routed)
    }

    /// Forgets the to-dos and the snapshot, deletes their cache and shows the setup steps: the GitLab token was
    /// removed (MR-04). The next token's first load announces nothing old.
    public func tokenRemoved() {
        server = nil
        serverDone = nil
        overrides = [:]
        fetchedAt = nil
        hasLoadedDone = false
        problem = .noToken(.gitLab)
        state.snapshot = InboxSnapshot()
        saveState()
        try? services.caches.delete(.inboxTodos, for: project)
        rebuild()
    }

    // MARK: - My to-dos

    /// my own to-dos in my order, whether pending, snoozed or done
    public var myTodos: [MyTodo] { mine.todos }

    /// the places a typed link is read against: the team's Jenkins jobs and GitLab, and the primary project for a bare `!123`
    public var linkContext: MyTodoLink.Context {
        MyTodoLink.Context(projects: services.team.projects(), primary: services.team.primaryProject())
    }

    /// Adds a to-do from the quick-add field's words: a pasted GitLab or Jenkins link, or a bare `!123` or `#123`, becomes
    /// the reference chip (``MyTodoLink/parse(_:context:)``). It goes on top of the list and never to GitLab.
    ///
    /// - Parameter text: what was typed
    /// - Returns: the new to-do; `nil` for empty words
    @discardableResult
    public func addMyTodo(_ text: String) -> MyTodo? {
        let parsed = MyTodoLink.parse(text, context: linkContext)
        return addMyTodo(MyTodoDraft(title: parsed.title, link: parsed.link))
    }

    /// Adds a to-do from the form.
    ///
    /// - Parameter draft: the title, the note, the date and the link
    /// - Returns: the new to-do; `nil` for an empty title
    @discardableResult
    public func addMyTodo(_ draft: MyTodoDraft) -> MyTodo? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }
        let todo = MyTodo(
            title: title, note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines), dueDate: draft.dueDate,
            link: draft.link, createdAt: services.now())
        mine.add(todo)
        saveMine()
        return todo
    }

    /// Changes a to-do's words, date and link; an empty title changes nothing.
    ///
    /// - Parameters:
    ///   - id: the to-do's id (``MyTodo/id``)
    ///   - draft: the new values
    public func updateMyTodo(_ id: String, with draft: MyTodoDraft) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }
        var clean = draft
        clean.title = title
        clean.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if mine.update(id, with: clean) {
            saveMine()
        }
    }

    /// Deletes a to-do for good.
    ///
    /// - Parameter id: the to-do's id
    public func deleteMyTodo(_ id: String) {
        mine.remove(id)
        saveMine()
    }

    /// Moves my pending to-dos as a drag in the list does.
    ///
    /// - Parameters:
    ///   - source: the offsets of the dragged rows among my pending to-dos, in the order the list shows them
    ///   - destination: the offset they are dropped before
    public func moveMyTodos(from source: IndexSet, to destination: Int) {
        let shown = pending.filter(\.isMine).sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map(\.myTodo?.id)
        mine.move(visible: shown.compactMap { $0 }, from: source, to: destination)
        saveMine()
    }

    private func saveMine() {
        try? myTodosFile.save(mine)
        rebuild()
    }

    /// Returns the row an announced event has now, so a panel's or a banner's Done and Snooze act on it: a GitLab to-do by
    /// its id, a local entry by its own.
    ///
    /// - Parameter event: the event
    /// - Returns: the row; `nil` when the event isn't in the Inbox (its Inbox toggle is off, or it is gone)
    public func entry(for event: InboxEvent) -> InboxEntry? {
        let id = event.todoID ?? event.id
        return (pending + snoozed + done).first { $0.id == id }
    }

    // MARK: - Done, Restore, Snooze

    /// Marks a row done (INBOX-03): a to-do in GitLab, a local entry here. The row moves at once and comes back if
    /// GitLab refuses.
    ///
    /// - Parameter entry: the row
    public func markDone(_ entry: InboxEntry) async {
        switch entry.source {
        case .event:
            setLocal(entry.id, doneAt: services.now())
        case .mine(let todo):
            mine.setDone(todo.id, at: services.now())
            saveMine()
        case .todo(let todo):
            _ = await change(todo, to: .done, .todoMarkDone(id: todo.id), "Mark Done")
        }
    }

    /// Makes a done row pending again (INBOX-03), the same way.
    ///
    /// - Parameter entry: the row
    public func restore(_ entry: InboxEntry) async {
        switch entry.source {
        case .event:
            setLocal(entry.id, doneAt: nil)
        case .mine(let todo):
            mine.setDone(todo.id, at: nil)
            saveMine()
        case .todo(let todo):
            _ = await change(todo, to: .pending, .todoRestore(id: todo.id), "Restore")
        }
    }

    /// Marks every pending row done (INBOX-03): GitLab's own "mark all done" for the to-dos. On a failure every row
    /// comes back.
    public func markAllDone() async {
        // My own to-dos are my list, not notifications: only their checkboxes finish them.
        let rows = pending.filter { !$0.isMine }
        guard !rows.isEmpty else {
            return
        }
        let now = services.now()
        var before: [String: Override?] = [:]
        var serials: [String: Int] = [:]
        for row in rows {
            switch row.source {
            case .event:
                setLocal(row.id, doneAt: now, rebuilding: false)
            case .mine:
                break
            case .todo(let todo):
                before[todo.id] = overrides[todo.id]
                serials[todo.id] = place(todo, .done)
            }
        }
        rebuild()
        guard !serials.isEmpty else {
            return
        }
        let outcome = await perform(GitLabOperation<[String]>.todosMarkAllDone, "Mark All Done")
        for (id, serial) in serials where overrides[id]?.serial == serial {
            if case .failure = outcome {
                overrides[id] = before[id] ?? nil
                bounce(id)
            } else if let todo = overrides[id]?.todo {
                overrides[id]?.settledAfterLoad = loadsStarted
                commit(todo, .done)
            }
        }
        if case .failure = outcome {
            for row in rows where row.todo == nil {
                setLocal(row.id, doneAt: nil, rebuilding: false)
            }
        }
        rebuild()
        if case .failure(let error) = outcome {
            await explainRefusal(error, "Mark All Done")
        }
    }

    /// Snoozes a to-do (INBOX-04): in GitLab when it can, otherwise on this Mac. It is in the Snoozed list until its
    /// time comes, then back in the pending list. A time that has passed does nothing.
    ///
    /// - Parameters:
    ///   - entry: the row; a local entry or one of my to-dos sleeps on this Mac
    ///   - choice: for how long
    public func snooze(_ entry: InboxEntry, _ choice: InboxSnoozeChoice) async {
        let now = services.now()
        let until = choice.wakeDate(from: now, calendar: calendar)
        guard until > now, entry.canSnooze else {
            return
        }
        switch entry.source {
        case .event:
            setLocal(entry.id, snoozedUntil: until)
            return
        case .mine(let todo):
            mine.setSnooze(todo.id, until: until)
            saveMine()
            return
        case .todo:
            break
        }
        guard let todo = entry.todo else {
            return
        }
        if snoozesInGitLab {
            let outcome = await change(todo, to: .snoozed(until: until), .todoSnooze(id: todo.id, until: until), "Snooze")
            guard case .failure(let error) = outcome, error.namesMissingSnooze else {
                if case .success = outcome {
                    state.snoozesInGitLab = true
                    saveState()
                }
                return
            }
            // This GitLab can't: snooze here, and from now on.
            actionProblem = nil
            state.snoozesInGitLab = false
            log(.info, "Inbox: this GitLab has no to-do snooze; snoozing on this Mac")
        }
        state.localSnoozes[todo.id] = until
        saveState()
        rebuild()
    }

    /// Wakes a snoozed to-do now (INBOX-04).
    ///
    /// - Parameter entry: the row
    public func unsnooze(_ entry: InboxEntry) async {
        switch entry.source {
        case .event:
            setLocal(entry.id, snoozedUntil: nil)
            return
        case .mine(let todo):
            mine.setSnooze(todo.id, until: nil)
            saveMine()
            return
        case .todo:
            break
        }
        guard let todo = entry.todo else {
            return
        }
        if state.localSnoozes.removeValue(forKey: todo.id) != nil {
            saveState()
            rebuild()
            return
        }
        _ = await change(todo, to: .pending, .todoUnSnooze(id: todo.id), "Unsnooze")
    }

    /// Moves a to-do at once, asks GitLab, and puts it back when GitLab refuses.
    private func change(
        _ todo: InboxTodo, to destination: Place, _ operation: GitLabOperation<Void>, _ name: String
    ) async -> Result<Void, GitLabError> {
        let before = overrides[todo.id]
        let serial = place(todo, destination)
        rebuild()
        let outcome = await perform(operation, name)
        guard overrides[todo.id]?.serial == serial else {
            // A later change of the same row decides.
            return outcome.map { _ in () }
        }
        switch outcome {
        case .success:
            overrides[todo.id]?.settledAfterLoad = loadsStarted
            commit(todo, destination)
        case .failure(let error):
            overrides[todo.id] = before
            if !error.namesMissingSnooze {
                bounce(todo.id)
            }
            rebuild()
            await explainRefusal(error, name)
        }
        return outcome.map { _ in () }
    }

    /// Writes a change GitLab took into its lists as last loaded, so it stays once the next load drops the change:
    /// a to-do marked done here stays in the Done list without asking for it.
    private func commit(_ todo: InboxTodo, _ destination: Place) {
        // GitLab's pending count follows the moves, so the badge's "beyond the first 100" stays right.
        if server?.pending.contains(where: { $0.id == todo.id }) == true {
            server?.pendingCount -= 1
        }
        if destination == .pending {
            server?.pendingCount += 1
        }
        server?.pending.removeAll { $0.id == todo.id }
        server?.snoozed.removeAll { $0.id == todo.id }
        serverDone?.removeAll { $0.id == todo.id }
        var moved = todo
        switch destination {
        case .done:
            moved.state = .done
            moved.snoozedUntil = nil
            serverDone = [moved] + (serverDone ?? [])
        case .pending:
            moved.state = .pending
            moved.snoozedUntil = nil
            server?.pending.insert(moved, at: 0)
        case .snoozed(let until):
            moved.snoozedUntil = until
            server?.snoozed.append(moved)
        }
        rebuild()
    }

    private func place(_ todo: InboxTodo, _ destination: Place) -> Int {
        serial += 1
        overrides[todo.id] = Override(todo: todo, place: destination, serial: serial)
        return serial
    }

    /// Marks a row as put back after a refusal, for 2 seconds on the injected clock.
    private func bounce(_ id: String) {
        bouncedIDs.insert(id)
        let clock = services.clock
        Task { [weak self] in
            try? await clock.sleep(for: .seconds(2))
            self?.bouncedIDs.remove(id)
        }
    }

    /// Says why a write was refused: a refusal that can be a token without the `api` scope asks GitLab for the token's
    /// scopes (once per token) and names the token when it is read-only or unknown; anything else keeps GitLab's words.
    /// Logs it once. A GitLab without the snooze mutations isn't a refusal worth a line.
    private func explainRefusal(_ error: GitLabError, _ name: String) async {
        guard !error.namesMissingSnooze else {
            return
        }
        let problem = await services.problem(for: error, action: name)
        // A later action may have answered while GitLab was asked.
        if actionProblem == error.problem {
            actionProblem = problem
        }
        log(.warning, "Inbox: \(name) failed: \(problem.message)")
    }

    /// Forgets the note about the last refused write, once the user has read it.
    public func dismissActionProblem() {
        actionProblem = nil
    }

    /// Sends a mutation. A failure sets ``actionProblem`` at once (``explainRefusal(_:_:)`` words it better); a success
    /// clears it.
    private func perform<Value>(_ operation: GitLabOperation<Value>, _ name: String) async -> Result<Value, GitLabError> {
        let outcome: Result<Value, GitLabError>
        switch await services.session() {
        case .failure(let refusal):
            outcome = .failure(refusal)
        case .success(let session):
            do {
                outcome = .success(try await session.client.send(operation))
            } catch let error as GitLabError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(GitLabError(.unreachable(.gitLab)))
            }
        }
        switch outcome {
        case .success:
            actionProblem = nil
        case .failure(let error):
            actionProblem = error.problem
        }
        return outcome
    }

    private func setLocal(_ id: String, doneAt: Date?, rebuilding: Bool = true) {
        guard let index = state.localEntries.firstIndex(where: { $0.event.id == id }) else {
            return
        }
        state.localEntries[index].doneAt = doneAt
        state.localEntries[index].snoozedUntil = nil
        saveState()
        if rebuilding {
            rebuild()
        }
    }

    private func setLocal(_ id: String, snoozedUntil: Date?) {
        guard let index = state.localEntries.firstIndex(where: { $0.event.id == id }) else {
            return
        }
        state.localEntries[index].snoozedUntil = snoozedUntil
        saveState()
        rebuild()
    }

    // MARK: - The lists

    /// Puts together the lists from GitLab's answers, the changes made here, the local snoozes and entries, and
    /// waits for the next snoozed to-do to wake.
    private func rebuild() {
        let now = services.now()
        var todos: [String: InboxTodo] = [:]
        var places: [String: Place] = [:]
        for todo in serverDone ?? [] {
            todos[todo.id] = todo
            places[todo.id] = .done
        }
        for todo in server?.snoozed ?? [] {
            todos[todo.id] = todo
            places[todo.id] = .snoozed(until: todo.snoozedUntil ?? now)
        }
        for todo in server?.pending ?? [] {
            todos[todo.id] = todo
            places[todo.id] = .pending
        }
        for (id, change) in overrides {
            todos[id] = change.todo
            places[id] = change.place
        }
        for (id, until) in state.localSnoozes where places[id] == .pending {
            places[id] = .snoozed(until: until)
        }

        var pending: [InboxEntry] = []
        var snoozed: [InboxEntry] = []
        var done: [InboxEntry] = []
        var nextWake: Date?
        for (id, todo) in todos {
            switch places[id] {
            case .snoozed(let until) where until > now:
                snoozed.append(InboxEntry(todo: todo, snoozedUntil: until))
                nextWake = min(nextWake ?? until, until)
            case .pending, .snoozed:
                pending.append(InboxEntry(todo: todo))
            case .done:
                done.append(InboxEntry(todo: todo))
            case nil:
                break
            }
        }
        for local in state.localEntries {
            if local.doneAt != nil {
                done.append(InboxEntry(event: local.event))
            } else if let until = local.snoozedUntil, until > now {
                snoozed.append(InboxEntry(event: local.event, snoozedUntil: until))
                nextWake = min(nextWake ?? until, until)
            } else {
                pending.append(InboxEntry(event: local.event))
            }
        }
        for (position, todo) in mine.todos.enumerated() {
            if todo.doneAt != nil {
                done.append(InboxEntry(mine: todo))
            } else if let until = todo.snoozedUntil, until > now {
                snoozed.append(InboxEntry(mine: todo, snoozedUntil: until))
                nextWake = min(nextWake ?? until, until)
            } else {
                pending.append(InboxEntry(mine: todo, position: position))
            }
        }
        self.pending = pending.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        self.snoozed = snoozed.sorted { ($0.snoozedUntil ?? now, $0.id) < ($1.snoozedUntil ?? now, $1.id) }
        self.done = done.sorted { ($0.date, $0.id) > ($1.date, $1.id) }

        let mine = myProjects()
        let counted = pending.filter { rules.countsInBadge($0.kind, projectPath: $0.projectPath, myProjects: mine) }.count
        let beyond = max(0, (server?.pendingCount ?? 0) - (server?.pending.count ?? 0))
        badgeCount = counted + beyond

        // The local snoozes that woke, or whose to-do is gone, are forgotten.
        if server != nil {
            let kept = state.localSnoozes.filter { $0.value > now && todos[$0.key] != nil }
            if kept != state.localSnoozes {
                state.localSnoozes = kept
                saveState()
            }
        }
        scheduleWake(at: nextWake, now: now)
    }

    /// Sleeps on the clock until the next snoozed to-do wakes, then rebuilds the lists.
    private func scheduleWake(at date: Date?, now: Date) {
        guard wake?.at != date else {
            return
        }
        wake?.task.cancel()
        wake = nil
        guard let date else {
            return
        }
        let clock = services.clock
        let wait = Duration.seconds(max(0, date.timeIntervalSince(now)))
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: wait)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            self.wake = nil
            self.rebuild()
        }
        wake = (task, date)
    }

    // MARK: - Files

    private func saveState() {
        // A state that can't be written costs the next launch its memory of what was announced.
        try? stateFile.save(state)
    }

    private func saveCache() {
        guard let server, let fetchedAt else {
            return
        }
        try? services.caches.save(Cached(value: server, fetchedAt: fetchedAt, problem: problem), as: .inboxTodos, for: project)
    }

    private func log(_ level: ActivityEntry.Level, _ message: String) {
        let log = services.log
        Task { await log.log(level, .gitlab, message) }
    }
}

extension InboxStore: OnDemandLoading {
    public func dataAge() async -> Duration? {
        services.age(since: lastLoadAt)
    }
}

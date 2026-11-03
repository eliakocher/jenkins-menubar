import AppKit
import MenubarCore
import SwiftUI

/// The Inbox section's list (Task 7.03, INBOX-02): GitLab's To-Do List in the window and the user's own to-dos, grouped in
/// the order of Settings → Notifications (My To-Dos, Coffee, Claude, Mentions, Review Requests, Assigned, Builds, Other),
/// newest first, with the Pending, Snoozed and Done filters, Done, Snooze and Mark All Done. It is full
/// width, like Slots: a click opens the target in the app (its list or "Opened"; ⌥ opens the browser).
///
/// It reads the store from the environment and draws an ``InboxListContent`` from it, refreshed every 30 s for the ages.
/// Only this list reads the rows, so a change of the to-dos draws this list and the sidebar's badge, not the window.
public struct InboxListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @ViewState private var filter = InboxViewFilter()
    private let searchText: String

    /// - Parameter searchText: the window's search text; empty shows everything
    public init(searchText: String) {
        self.searchText = searchText
    }

    public var body: some View {
        let links = GitLabSectionActions.live(model: model, router: router, openURL: openURL)
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            InboxListContent(
                model: InboxListModel(InboxData(model, now: context.date), filter: filter, query: searchText),
                filter: $filter, actions: .live(model: model, links: links, router: router), links: links)
            // Each row asks for its own seen mark, so marking one draws that row and not the list.
            .environment(\.inboxIsSeen) { [store = model.inbox] in store.seen.isSeen($0) }
            .environment(\.inboxIsBounced) { [store = model.inbox] in store.bouncedIDs.contains($0) }
        }
        // The Done list is asked while it shows (INBOX-01), and again when the user comes back to it.
        .task(id: filter.state) {
            if filter.state == .done {
                await model.inbox.loadDone()
            }
        }
    }
}

/// The Inbox list drawn from plain values, for the window and the gallery.
struct InboxListContent: View {
    let model: InboxListModel
    @Binding var filter: InboxViewFilter
    let actions: InboxActions
    let links: GitLabSectionActions
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    /// the rows the keys and the context menu act on
    @ViewState private var selection: Set<String> = []
    @ViewState private var isConfirmingMarkAll = false
    @ViewState private var isPickingDate = false
    /// the rows the date picker snoozes
    @ViewState private var dateEntries: [InboxEntry] = []
    /// the to-do the form edits, or a new one
    @ViewState private var todoSheet: MyTodoSheetTarget?

    /// the keys of Done, which Settings → Shortcuts changes
    private var doneShortcut: HotkeyShortcut? {
        (settings?.preferences.shortcuts ?? ShortcutMap()).shortcut(for: "inboxDone")
    }

    var body: some View {
        List(selection: $selection) {
            MainWindowProblemRows(model.problems, openSettings: links.openSettings)
            if let note = model.actionNote {
                InboxActionNote(
                    text: note, fixesToken: model.actionFixesToken, openAccounts: { links.openSettings(.accounts) },
                    dismiss: actions.dismissNote)
            }
            if model.showsFilterBar {
                InboxFilterBar(model: model, filter: $filter, isConfirmingMarkAll: $isConfirmingMarkAll)
            }
            if model.isPlaceholder {
                SectionPlaceholderRows()
            }
            ForEach(model.sections) { section in
                Section {
                    if section.showsAddField {
                        MyTodoAddField(add: actions.addTodo) { todoSheet = .new }
                    }
                    ForEach(section.rows) { row in
                        InboxRowContent(row: row, state: filter.state, actions: actions) { entries in
                            dateEntries = entries
                            isPickingDate = true
                        }
                        .tag(row.id)
                        .onTapGesture { open(row) }
                    }
                    // A drag reorders my own to-dos, and only them.
                    .onMove(perform: section.canReorder && section.rows.count > 1 ? { actions.moveTodos($0, $1) } : nil)
                } header: {
                    InboxSectionHeader(title: section.title, count: section.rows.count)
                }
            }
            if model.needsToken {
                // Under My To-Dos, which need no token: the steps for GitLab's own to-dos.
                InboxTokenNote(openAccounts: { links.openSettings(.accounts) })
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: rows(of: ids))
        } primaryAction: { ids in
            // Return and a double-click open the first one, as a click does; a to-do of mine without a link opens its form.
            if let row = rows(of: ids).first {
                if row.entry.isMine, row.entry.targetURL == nil, let todo = row.entry.myTodo {
                    todoSheet = .edit(todo)
                } else {
                    open(row)
                }
            }
        }
        .onKeyPress(phases: .down) { press in
            // ⌘⌫ is Done, ⌘⌫ in Done is Restore; plain ⌫ stays the field's. The keys are the user's (KEYS-01).
            guard let shortcut = doneShortcut, shortcut.matches(press), !selection.isEmpty else {
                return .ignored
            }
            let rows = rows(of: selection).map(\.entry)
            guard !rows.isEmpty else {
                return .ignored
            }
            if filter.state == .done {
                actions.restore(rows)
            } else {
                actions.done(rows)
            }
            return .handled
        }
        .animation(.snappy(duration: 0.25), value: model.rows.map(\.id))
        .overlay { emptyState }
        .alert("Mark All as Done?", isPresented: $isConfirmingMarkAll) {
            Button("Mark All Done") { actions.markAllDone() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This marks all \(model.markAllCount) pending to-dos done in GitLab. Snoozed ones stay snoozed.")
        }
        .sheet(item: $todoSheet) { target in
            MyTodoSheet(target: target, parseLink: actions.parseLink) { draft in
                if case .edit(let todo) = target {
                    actions.saveTodo(todo.id, draft)
                } else {
                    actions.saveTodo(nil, draft)
                }
                todoSheet = nil
            } cancel: {
                todoSheet = nil
            }
        }
        .sheet(isPresented: $isPickingDate) {
            InboxSnoozeSheet(count: dateEntries.count) { date in
                actions.snooze(dateEntries, .until(date))
                isPickingDate = false
            } cancel: {
                isPickingDate = false
            }
        }
    }

    /// The rows with these ids, in the list's order.
    private func rows(of ids: Set<String>) -> [InboxRowModel] {
        model.rows.filter { ids.contains($0.id) }
    }

    /// Opens the target in the app; the browser with ⌥. A click that extends the selection (⇧ or ⌘) opens nothing.
    private func open(_ row: InboxRowModel) {
        guard NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) else {
            return
        }
        // A to-do of mine without a link has nothing to open: its checkbox and its form are what it has.
        guard !row.entry.isMine || row.entry.targetURL != nil else {
            return
        }
        actions.open(row.entry)
    }

    /// The context menu of one or several rows: Done and Snooze, or Restore, then the target's links.
    @ViewBuilder
    private func menu(for rows: [InboxRowModel]) -> some View {
        let entries = rows.map(\.entry)
        let many = entries.count > 1
        if !entries.isEmpty {
            switch filter.state {
            case .pending:
                Button(many ? "Mark \(entries.count) Done" : "Done") { actions.done(entries) }
                // The coffee break can't be snoozed.
                if entries.allSatisfy(\.canSnooze) {
                    InboxSnoozeMenu(entries: entries, actions: actions) { dateEntries = $0; isPickingDate = true } label: {
                        Text("Snooze")
                    }
                }
            case .snoozed:
                Button("Wake Now") { actions.wake(entries) }
                Button(many ? "Mark \(entries.count) Done" : "Done") { actions.done(entries) }
            case .done:
                Button(many ? "Restore \(entries.count)" : "Restore") { actions.restore(entries) }
            }
            if !many, let url = entries[0].targetURL {
                Divider()
                Button("Show in App") { actions.open(entries[0]) }
                if entries[0].isMine {
                    Button("Open in Browser") { links.open(url) }
                    Button("Copy Link") { links.copy(url) }
                } else if !InboxOpening.isLocal(entries[0]) {
                    Button("Open in GitLab") { links.open(url) }
                    Button("Copy Link") { links.copy(url) }
                }
            }
            if entries.allSatisfy(\.isMine) {
                Divider()
                if !many, let todo = entries[0].myTodo {
                    Button("Edit…") { todoSheet = .edit(todo) }
                }
                Button(many ? "Delete \(entries.count) To-Dos" : "Delete", role: .destructive) { actions.deleteTodos(entries) }
            }
        }
    }

    /// The empty state, the error with Try Again, or the missing token's steps.
    @ViewBuilder
    private var emptyState: some View {
        if model.needsToken {
            EmptyView()
        } else if let failure = model.failure {
            ContentUnavailableView {
                Label("Couldn't Load the Inbox", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure)
            } actions: {
                Button("Try Again") { actions.retry() }
            }
        } else if let empty = model.empty {
            if model.findsNothing {
                ContentUnavailableView.search(text: model.query)
            } else {
                ContentUnavailableView {
                    Label(empty.title, systemImage: empty.symbol)
                } description: {
                    Text(verbatim: empty.detail)
                }
            }
        }
    }
}

/// The missing token's steps, under My To-Dos: the key, a title, the setup text and the way to Settings → Accounts.
private struct InboxTokenNote: View {
    let openAccounts: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "key")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Needs a GitLab Token")
                .font(.headline)
            Text(verbatim: PanelModel.SetupText.needsToken)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings → Accounts", action: openAccounts)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

/// A group's header: its title in the list's section style and its count after it.
private struct InboxSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            Text(verbatim: String(count))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

/// A Done, Restore or Snooze that GitLab refused and that was put back: a tinted banner above the rows, with the words of
/// the refusal, and for a token that can only read the way to Settings → Accounts.
private struct InboxActionNote: View {
    let text: String
    let fixesToken: Bool
    let openAccounts: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: fixesToken ? "key.fill" : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(MergeRequestStatus.Color.orange.swiftUI)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if fixesToken {
                Button("Open Settings → Accounts", action: openAccounts)
                    .buttonStyle(.link)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .accessibilityLabel("Dismiss")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            MergeRequestStatus.Color.orange.swiftUI.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(MergeRequestStatus.Color.orange.swiftUI.opacity(0.35), lineWidth: 0.75)
        }
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

/// The bar atop the list: the Pending, Snoozed and Done filter as a segmented control, the group and project filters in a
/// menu, and Mark All Done at the end (the way the Work Items list keeps its filters in its own header).
private struct InboxFilterBar: View {
    let model: InboxListModel
    @Binding var filter: InboxViewFilter
    @Binding var isConfirmingMarkAll: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter.state) {
                ForEach(InboxFilter.State.allCases, id: \.self) { state in
                    Text(verbatim: label(of: state)).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            filterMenu
            Spacer(minLength: 8)
            if filter.state == .pending, model.markAllCount > 0 {
                Button("Mark All Done") { isConfirmingMarkAll = true }
                    .help("Mark all \(model.markAllCount) pending to-dos done in GitLab")
            }
        }
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    /// "Pending 4", "Snoozed 2", "Done": the counts of the first two, so a sleeping to-do isn't forgotten
    private func label(of state: InboxFilter.State) -> String {
        let count: Int? =
            switch state {
            case .pending: model.pendingCount
            case .snoozed: model.snoozedCount
            case .done: nil
            }
        guard let count, count > 0 else {
            return state.title
        }
        return "\(state.title) \(count)"
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $filter.group) {
                Text("All Types").tag(InboxGroup?.none)
                Divider()
                ForEach(InboxGroup.allCases, id: \.self) { group in
                    Text(verbatim: group.title).tag(InboxGroup?.some(group))
                }
            }
            .pickerStyle(.inline)
            if !model.projects.isEmpty {
                Picker("Project", selection: $filter.project) {
                    Text("All Projects").tag(String?.none)
                    Divider()
                    ForEach(model.projects, id: \.self) { project in
                        Text(verbatim: project).tag(String?.some(project))
                    }
                }
                .pickerStyle(.menu)
            }
            if filter.isNarrowed {
                Divider()
                Button("Clear Filters") {
                    filter.group = nil
                    filter.project = nil
                }
            }
        } label: {
            Image(systemName: filter.isNarrowed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .accessibilityLabel("Filter")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filter.isNarrowed ? "Filtered by type or project" : "Filter by type or project")
    }
}

/// "Until a Date…": the date and time a to-do wakes at, in a small sheet (INBOX-04).
struct InboxSnoozeSheet: View {
    /// how many to-dos it snoozes
    let count: Int
    let snooze: (Date) -> Void
    let cancel: () -> Void
    @ViewState private var date = InboxSnoozeChoice.tomorrowMorning.wakeDate(from: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(count > 1 ? "Snooze \(count) To-Dos Until" : "Snooze Until")
                .font(.headline)
            DatePicker("Wake at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Snooze") { snooze(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= Date())
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

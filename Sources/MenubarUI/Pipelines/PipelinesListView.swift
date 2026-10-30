import MenubarCore
import SwiftUI

/// The Pipelines section's content column (Task 5.2, `docs/design/pipelines.md`): the problem rows, My Builds,
/// Watching and the link rows, filtered by the window's search.
///
/// It reads the stores from the environment and draws a ``PipelinesListContent``, refreshed every 10 s for the running
/// builds' times. A selected job that leaves the list (hidden, dropped, no longer watched) leaves no selection.
public struct PipelinesListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Binding private var selection: String?
    private let searchText: String

    /// the name this list reads the checkouts under, for its tags
    private static let workspacesHost = "pipelines-section"

    /// - Parameters:
    ///   - selection: the selected job, `Build.job` (a WAITING job: `WatchedJob.job`)
    ///   - searchText: the window's search text; empty shows everything
    public init(selection: Binding<String?>, searchText: String) {
        _selection = selection
        self.searchText = searchText
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            PipelinesListContent(
                model: PipelinesListModel(PipelinesData(model, now: context.date), query: searchText),
                selection: $selection,
                actions: .mainWindow(model, router: router, openURL: openURL),
                focusRequest: router.listFocusRequest)
        }
        .onChange(of: PipelinesData(model, now: model.pipelines.now).jobs, initial: true) { _, jobs in
            dropSelection(keeping: jobs)
        }
        .onAppear {
            // The hiding rules' time moves on as when the panel opens (HIDE-02).
            model.projects.refreshTime()
            // The tags name the checkouts, which are read while the list shows (WS-07).
            model.workspaces.show(by: Self.workspacesHost)
        }
        .onDisappear {
            model.workspaces.hide(by: Self.workspacesHost)
        }
        .workspaceTagsClickable()
    }

    /// Clears the selection when its job left the list; before the first check the list has nothing to compare with.
    private func dropSelection(keeping jobs: Set<String>) {
        let pipelines = model.pipelines
        guard let job = selection, !jobs.contains(job), pipelines.hasLoaded || pipelines.problem != nil else {
            return
        }
        selection = nil
    }
}

/// The Pipelines list drawn from plain values, for the window and the gallery.
struct PipelinesListContent: View {
    let model: PipelinesListModel
    @Binding var selection: String?
    let actions: PanelActions
    /// grows when the list should take the keyboard focus
    var focusRequest = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if !model.problems.isEmpty {
                    MainWindowProblemRows(model.problems, openSettings: actions.openSettings)
                }
                if let myBuilds = model.myBuilds {
                    Section {
                        switch myBuilds {
                        case .rows(let rows):
                            ForEach(rows, id: \.build.job) { row in
                                BuildRowContent(model: row) { actions.cancelRebuild(row.build.jobKey) }
                                    .tag(row.build.job)
                            }
                        case .placeholder:
                            PipelinesPlaceholderRows()
                        case .note(let text):
                            Text(verbatim: text)
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                    } header: {
                        header("My Builds", group: .mine, subject: "My Builds")
                    }
                }
                if !model.watching.isEmpty {
                    Section {
                        ForEach(model.watching) { item in
                            row(item)
                                .tag(item.id)
                        }
                    } header: {
                        header("Watching", group: .watching, subject: "Watched Builds")
                    }
                }
                if model.allBuilds != nil || model.showHiddenTitle != nil {
                    Section {
                        linkRows
                    }
                }
            }
            .focused($isFocused)
            .contextMenu(forSelectionType: String.self) { jobs in
                if let job = jobs.first, let item = item(job) {
                    menu(item)
                }
            } primaryAction: { jobs in
                // The build shows in the detail already; ⌥ opens its page in Jenkins (the user, 2026-10-30).
                if let job = jobs.first, let url = item(job).flatMap(page) {
                    actions.follow(url)
                }
            }
            .onKeyPress(.return) {
                // The primary action is the double click's only; Return opens the build too (`pipelines.md`, Keyboard).
                guard let selection, let url = item(selection).flatMap(page) else {
                    return .ignored
                }
                actions.follow(url)
                return .handled
            }
            .overlay {
                if let empty = model.empty {
                    emptyState(empty)
                } else if model.findsNothing {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .onAppear {
                isFocused = true
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
            .onChange(of: focusRequest) {
                isFocused = true
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    /// A section header with the bell that turns the group's notifications on or off (ALERT-09).
    private func header(_ title: String, group: NotificationPolicy.Group, subject: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            let isOn = model.notifications.isOn(group)
            NotificationsBell(isOn: isOn, subject: subject) { actions.setGroupNotifications(group, !isOn) }
        }
    }

    @ViewBuilder
    private func row(_ item: PipelinesItem) -> some View {
        switch item {
        case .build(let row):
            BuildRowContent(model: row) { actions.cancelRebuild(row.build.jobKey) }
        case .waiting(let watched):
            PanelRowLayout {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            } lines: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: watched.label)
                    Spacer(minLength: 0)
                    if waitingNotifications(watched).isMuted {
                        MutedMark()
                    }
                }
                Text(verbatim: "WAITING")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .help(BuildDetailModel.StageNote.waiting)
        }
    }

    @ViewBuilder
    private var linkRows: some View {
        if let url = model.allBuilds {
            Link("All Builds in Jenkins", destination: url)
                .buttonStyle(.link)
                .selectionDisabled()
        }
        if let title = model.showHiddenTitle {
            Button(title) { actions.showHidden() }
                .buttonStyle(.link)
                .selectionDisabled()
        }
    }

    /// PIPE-06's text with its next steps: "Provide clear next steps on any blank screens." [writing › Best practices]
    private func emptyState(_ empty: PipelinesListModel.Empty) -> some View {
        ContentUnavailableView {
            Label(empty.title, systemImage: "hammer")
        } actions: {
            if empty.offersWatch {
                Button("Watch a Build…") { actions.watchBuild() }
            }
            if let title = empty.showHiddenTitle {
                Button(title) { actions.showHidden() }
            }
            if let url = empty.allBuilds {
                Link("All Builds in Jenkins", destination: url)
            }
        }
    }

    /// The panel's context menu; a waiting job's has its job link, Copy Link and Stop Watching (`pipelines.md`).
    @ViewBuilder
    private func menu(_ item: PipelinesItem) -> some View {
        switch item {
        case .build(let row):
            BuildRowMenu(model: row, actions: actions)
        case .waiting(let watched):
            if let url = page(item) {
                Button("Open Job in Jenkins") { actions.open(url) }
                Divider()
                Button("Copy Link") { actions.copy(url) }
                Divider()
            }
            JobNotificationsMenu(notifications: waitingNotifications(watched)) {
                actions.setJobNotifications(watched.job, $0)
            }
            Button("Stop Watching") { actions.stopWatching(watched.job) }
        }
    }

    /// Returns a waiting job's notifications; it is always one of Watching.
    private func waitingNotifications(_ watched: WatchedJob) -> JobNotifications {
        JobNotifications(model.notifications, job: watched.job, group: .watching)
    }

    /// Returns the row of a job, among the rows the list shows.
    private func item(_ job: String) -> PipelinesItem? {
        var items = model.watching
        if case .rows(let rows)? = model.myBuilds {
            items += rows.map(PipelinesItem.build)
        }
        return items.first { $0.id == job }
    }

    /// Returns the page a double-click opens: the build's, or a waiting job's job page.
    private func page(_ item: PipelinesItem) -> URL? {
        model.page(of: item)
    }
}

/// Rows of bars standing in for My Builds before the first check (OD-01).
struct PipelinesPlaceholderRows: View {
    var body: some View {
        SkeletonRows(count: 4, leading: .symbol(column: 16), spacing: 8)
    }
}

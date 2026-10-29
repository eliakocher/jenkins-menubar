import MenubarCore
import SwiftUI

/// The main window's content (Task 5.1, `docs/design/main-window.md`): a `NavigationSplitView` with the sidebar's four
/// sections, the selected section's list in the content column and its detail in the detail column, the toolbar and
/// the search, and the Watch a Build… sheet, which shows while ``WindowRouter/watchRequest`` is set (Task 4.6).
///
/// - The section and each section's selection live on the ``WindowRouter``, so a route can pick the section before
///   the window opens and a detail's "Show in …" can switch to a row of another section; the router keeps them in
///   UserDefaults (WIN-05). The search belongs to the window: a section change clears it, and it isn't kept.
/// - It tells the scheduler what it shows (OD-02): the selected section while it is open, and Merge Requests and Work
///   Items for their badges while it can be seen.
public struct MainWindowRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @AppStorage("mainWindow.sidebarVisible") private var sidebarVisible = true
    /// whether Activity's inspector shows; its toolbar toggle, View › Show Inspector and the rows' ⓘ share it (LOG-04)
    @AppStorage("activity.inspectorShown") private var activityInspectorShown = false
    /// whether "Clear all activity?" shows; Activity's toolbar and File › Clear Activity… share the section's one alert
    @ViewState private var isConfirmingClearActivity = false
    @ViewState private var searchText = ""
    @ViewState private var isOnScreen = true
    /// which spellcheck demo the search shows, while it shows one (EGG-07)
    @ViewState private var spellcheckDemo: Int?

    public init() {}

    public var body: some View {
        shell
        .focusedSceneValue(\.mainWindowSection, router.section)
        .background {
            WindowOnScreenReader { onScreen in
                isOnScreen = onScreen
            }
        }
        .onChange(of: router.section) {
            // A leftover filter would hide rows of the new section.
            searchText = ""
            reportSurfaces()
        }
        .onChange(of: isOnScreen) {
            reportSurfaces()
        }
        .onChange(of: searchIsSpellcheck) { _, isSpellcheck in
            // The demo counts once each time the search turns to "spellcheck", not per keystroke.
            spellcheckDemo = isSpellcheck ? model.pipelines.countSpellcheckDemo() : nil
        }
        .onAppear {
            reportSurfaces()
        }
        .onDisappear {
            router.report([], shownBy: MainWindowSurfaces.host, to: model.scheduler)
        }
        .sheet(isPresented: isWatching) {
            WatchSheet()
        }
    }

    /// The shell, filled from the stores.
    private var shell: some View {
        @Bindable var router = router
        let model: MainWindowShellModel = MainWindowShellModel(
            PanelView.data(self.model, now: self.model.pipelines.now), section: router.section,
            activitySubtitle: activitySubtitle, workspacesSubtitle: workspacesSubtitle,
            workspacesBusy: self.model.workspaces.isRefreshing)
        let actions: PanelActions = PanelActions.mainWindow(self.model, router: router, openURL: openURL)
        return MainWindowShell(
            model: model, section: $router.section, searchText: $searchText, columnVisibility: columnVisibility,
            actions: actions, searchFocusRequest: router.searchFocusRequest, searchNote: eggNote
        ) {
            content(selection: $router.selection)
                // Edit › Copy copies the selected row's link; Activity copies its entries itself (LOG-04).
                .onCopyCommand(perform: copyAction)
        } detail: {
            detail
        } sectionToolbar: {
            MainWindowSectionToolbar(
                section: router.section, activityInspectorShown: $activityInspectorShown,
                isConfirmingClearActivity: $isConfirmingClearActivity)
        }
    }

    private var searchIsSpellcheck: Bool {
        model.pipelines.preferences.easterEggs && EggRules.searchMatch(searchText) == .spellcheck
    }

    /// The easter egg note for the search text (EGG-06 to EGG-08): a quiet line above the results, never instead of them.
    private var eggNote: String? {
        guard model.pipelines.preferences.easterEggs, let match = EggRules.searchMatch(searchText) else {
            return nil
        }
        switch match {
        case .note(let text):
            return text
        case .coffee:
            return EggRules.coffeeNote(running: model.projects.myBuilds, now: model.dependencies.now())
        case .spellcheck:
            return spellcheckDemo.map(EggRules.spellcheckNote)
        case .typo(let suggestion):
            return EggRules.typoNote(suggestion: suggestion)
        }
    }

    /// Edit › Copy's action; none in Activity, whose table copies its entries itself, and none without a selected row,
    /// so the command is disabled then
    private var copyAction: (() -> [NSItemProvider])? {
        guard router.section != .activity, MainWindowLinks.selected(model, router: router) != nil else {
            return nil
        }
        return { copySelectedLink() }
    }

    /// The selected section's list.
    @ViewBuilder
    private func content(selection: Binding<MainWindowSelection>) -> some View {
        switch router.section {
        case .pipelines:
            PipelinesListView(selection: selection.pipelines, searchText: searchText)
        case .mergeRequests:
            MergeRequestsListView(selection: selection.mergeRequests, searchText: searchText)
        case .workItems:
            WorkItemsListView(selection: selection.workItems, searchText: searchText)
        case .activity:
            ActivityView(
                selection: selection.activity, searchText: searchText, isInspectorShown: $activityInspectorShown,
                isConfirmingClear: $isConfirmingClearActivity)
        case .workspaces:
            WorkspacesListView(selection: selection.workspaces, searchText: searchText)
        case .slots:
            SlotsView(searchText: searchText)
        }
    }

    /// The selected section's detail, for its selection; none for Activity, whose log is full width and shows its
    /// details in an inspector (LOG-04).
    @ViewBuilder
    private var detail: some View {
        let selection = router.selection
        switch router.section {
        case .pipelines:
            BuildDetailView(selection: selection.pipelines)
        case .mergeRequests:
            MergeRequestDetailView(selection: selection.mergeRequests)
        case .workItems:
            WorkItemDetailView(selection: selection.workItems)
        case .activity:
            EmptyView()
        case .workspaces:
            WorkspaceDetailView(selection: selection.workspaces)
        case .slots:
            EmptyView()
        }
    }

    /// The sidebar shows by default; hiding it is kept with the section (`main-window.md`, Restored).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .doubleColumn },
            set: { sidebarVisible = $0 != .doubleColumn && $0 != .detailOnly })
    }

    /// Activity's subtitle: "182 entries", or "12 of 182 entries" while a filter or the search narrows the list
    /// (LOG-04), as lane T's content builds it.
    private var activitySubtitle: String? {
        let activity = model.activity
        return ActivityContentData.subtitle(
            isLoaded: activity.isLoaded, matching: activity.matchingItems.count, total: activity.items.count,
            isNarrowed: ActivityContentData.isNarrowed(
                level: activity.levelFilter, source: activity.sourceFilter, search: activity.searchText))
    }

    /// Workspaces' subtitle: "4 checkouts · 2 free" (WS-01).
    private var workspacesSubtitle: String? {
        WorkspacesListModel(WorkspacesData(model, now: model.pipelines.now)).subtitle
    }

    /// The selected row's link for Edit › Copy; nothing without one.
    private func copySelectedLink() -> [NSItemProvider] {
        guard let url = MainWindowLinks.selected(model, router: router) else {
            return []
        }
        return [NSItemProvider(object: url.absoluteString as NSString)]
    }

    private func reportSurfaces() {
        router.report(
            MainWindowSurfaces.shown(section: router.section, isOnScreen: isOnScreen), shownBy: MainWindowSurfaces.host,
            to: model.scheduler)
    }

    /// The sheet shows while there is a watch request; closing it clears the request.
    private var isWatching: Binding<Bool> {
        Binding(
            get: { router.watchRequest != nil },
            set: { shown in
                if !shown {
                    router.watchRequest = nil
                }
            })
    }
}

/// Group 1 of the toolbar: the section's own items, from the section's lane; Pipelines and Merge Requests have none.
struct MainWindowSectionToolbar: ToolbarContent {
    let section: MainWindowSection
    /// Activity's inspector, which its toolbar toggles
    @Binding var activityInspectorShown: Bool
    /// Activity's Clear confirmation, which its toolbar asks for
    @Binding var isConfirmingClearActivity: Bool

    var body: some ToolbarContent {
        if section == .workItems {
            WorkItemsToolbar()
        }
        if section == .activity {
            ActivityToolbar(isInspectorShown: $activityInspectorShown, isConfirmingClear: $isConfirmingClearActivity)
        }
        // The daily digest, written by Claude, in every section while the Claude features are on (AI-04).
        DigestToolbarItem()
    }
}

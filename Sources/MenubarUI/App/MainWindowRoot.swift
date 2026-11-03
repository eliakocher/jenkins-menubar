import AppKit
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
    /// the sidebar's order of the sections, which Settings → Appearance and a drag in the sidebar change (WIN-01)
    @AppStorage(SectionOrder.key) private var sectionOrder = ""
    /// whether "Clear all activity?" shows; Activity's toolbar and File › Clear Activity… share the section's one alert
    @ViewState private var isConfirmingClearActivity = false
    @ViewState private var searchText = ""
    /// changes on each reveal, so that a list in the shown section loads afresh and scrolls to the selection
    @ViewState private var revealedList = 0
    @ViewState private var isOnScreen = true
    /// which spellcheck demo the search shows, while it shows one (EGG-07)
    @ViewState private var spellcheckDemo: Int?

    public init() {}

    public var body: some View {
        shell
        .focusedSceneValue(\.mainWindowSection, router.section)
        // The size the user left, also after a restart; the first launch keeps the scene's .defaultSize.
        .remembersWindowFrame("MainWindow", defaultSize: CGSize(width: 1120, height: 720))
        .background {
            WindowOnScreenReader { onScreen in
                isOnScreen = onScreen
            }
        }
        // The mouse's back and forward buttons and ⌘← ⌘→ (WIN-08): the router's one monitor, which learns this window here.
        .background {
            NavigationWindowAnchor(input: router.navigationInput)
        }
        .onChange(of: router.section) {
            // A leftover filter would hide rows of the new section.
            searchText = ""
            reportSurfaces()
        }
        .onChange(of: router.opened) {
            // Showing an opened item is like changing the section: the old query belongs to the list it filtered. Typing
            // over an item returns to the list (opened turns nil) and keeps the query.
            if router.opened != nil {
                searchText = ""
            }
        }
        .onChange(of: router.revealRequest) {
            // A row from the menu bar pane: a leftover filter would hide it.
            searchText = ""
            revealedList += 1
        }
        .onChange(of: isOnScreen) {
            reportSurfaces()
        }
        // The Digest section showing a digest the sidebar's dot was for: the dot goes.
        .onChange(of: isShowingUnreadDigest, initial: true) { _, isShowing in
            if isShowing {
                model.ai.markDigestSeen()
            }
        }
        .onChange(of: searchIsSpellcheck) { _, isSpellcheck in
            // The demo counts once each time the search turns to "spellcheck", not per keystroke.
            spellcheckDemo = isSpellcheck ? model.pipelines.countSpellcheckDemo() : nil
        }
        .onAppear {
            router.startNavigationInput(model: model)
            reportSurfaces()
        }
        .onDisappear {
            router.report([], shownBy: MainWindowSurfaces.host, to: model.scheduler)
        }
        .sheet(isPresented: isWatching) {
            WatchSheet()
        }
        .sheet(isPresented: isOpeningByLink) {
            OpenByLinkSheet()
        }
        .sheet(item: rebuildRequest) { request in
            RebuildSheet(
                build: request.build.label,
                load: { [model] in await model.projects.rebuildForm(for: request.build) },
                rebuild: { [model] in model.projects.rebuild(request.build, with: $0) },
                close: { [router] in router.rebuildRequest = nil })
        }
        // A link to a merge request or work item in a description or a comment opens in the app (WIN-06).
        .environment(\.openItemLink, OpenItemLink { [model, router] url in router.openItemLink(url, model: model) })
    }

    /// The shell, filled from the stores.
    private var shell: some View {
        @Bindable var router = router
        // The subtitles and spinners of the other sections are neither shown nor read: reading them made every change
        // of the log or the checkouts draw the whole window again.
        let section = router.section
        let model: MainWindowShellModel = MainWindowShellModel(
            PanelView.data(self.model, now: self.model.pipelines.now), section: section,
            activitySubtitle: section == .activity ? activitySubtitle : nil,
            workspacesSubtitle: section == .workspaces ? workspacesSubtitle : nil,
            workspacesBusy: section == .workspaces && self.model.workspaces.isRefreshing,
            slotsBusy: section == .slots && (self.model.slotLabels.isLoading || self.model.slotItems.isLoading),
            digestSubtitle: section == .digest ? DigestPage.subtitle(state: digestState) : nil,
            digestBusy: section == .digest && digestState.isBusy, digestUnread: self.model.ai.hasUnreadDigest,
            inbox: inboxShell(section))
        let actions: PanelActions = PanelActions.mainWindow(self.model, router: router, openURL: openURL)
        let ai = self.model.ai
        return MainWindowShell(
            model: model, section: $router.section, searchText: $searchText, columnVisibility: columnVisibility,
            actions: actions, reload: { [model = self.model, router] in
                MainWindowReload.run(router.section, selection: router.selection, opened: router.opened, model: model)
            }, searchFocusRequest: router.searchFocusRequest, searchNote: eggNote, opened: openedSidebar,
            navigation: navigation, detailLink: DetailLink.current(self.model, router: router),
            sections: MainWindowSection.sidebarSections(claudeIsOffered: ai.isOffered, shown: router.section, order: sectionOrder),
            moveSections: { moveSections(from: $0, to: $1) }
        ) {
            content(selection: $router.selection)
                .id(revealedList)
                // Edit › Copy copies the selected row's link; Activity copies its entries itself (LOG-04).
                .onCopyCommand(perform: copyAction)
        } detail: {
            detail
        } sectionToolbar: {
            MainWindowSectionToolbar(
                section: router.section, watchBuild: actions.watchBuild, activityInspectorShown: $activityInspectorShown,
                isConfirmingClearActivity: $isConfirmingClearActivity)
        }
    }

    /// What the Inbox adds to the shell: the badge and the problem always, since the sidebar shows them; the subtitle and the
    /// spinner only while it is shown. The rows aren't read here, so a change of the to-dos doesn't draw the window.
    private func inboxShell(_ section: MainWindowSection) -> InboxShell {
        let inbox = model.inbox
        return InboxShell(
            badge: inbox.badgeCount, problem: inbox.problem,
            subtitle: section == .inbox ? inbox.fetchedAt.map { Formatting.lastChecked($0) } : nil,
            isBusy: section == .inbox && inbox.isLoading)
    }

    /// Saves the order after a drag of the sidebar's rows; a section the sidebar hides keeps its place.
    private func moveSections(from source: IndexSet, to destination: Int) {
        let shown = MainWindowSection.sidebarSections(
            claudeIsOffered: model.ai.isOffered, shown: router.section, order: sectionOrder)
        let moved = SectionOrder.moving(
            SectionOrder.merged(stored: sectionOrder), shown: shown, from: source, to: destination)
        sectionOrder = SectionOrder.stored(moved)
    }

    /// whether the window shows the Digest section, with something the sidebar's dot was for
    private var isShowingUnreadDigest: Bool {
        router.section == .digest && router.opened == nil && isOnScreen && model.ai.hasUnreadDigest
    }

    /// where the digest stands
    private var digestState: AIAnswerState {
        model.ai.state(of: .digest)
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
            SlotsView(selection: selection.slots, searchText: searchText)
        case .inbox:
            InboxListView(searchText: searchText)
        case .digest:
            DigestView(searchText: searchText)
        }
    }

    /// The selected section's detail, for its selection; none for Activity, whose log is full width and shows its
    /// details in an inspector (LOG-04).
    @ViewBuilder
    private var detail: some View {
        if let opened = router.opened, model.opened.item(opened) != nil {
            OpenedItemDetailView(id: opened)
        } else {
            sectionDetail(router.selection)
        }
    }

    @ViewBuilder
    private func sectionDetail(_ selection: MainWindowSelection) -> some View {
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
        case .slots, .digest, .inbox:
            EmptyView()
        }
    }

    /// The toolbar's Back and Forward buttons: the router's history, and the places as the menus list them (WIN-08). The
    /// places are read only when a menu opens.
    private var navigation: NavigationControls {
        let router = router
        let model = model
        let history = router.history
        func entries(_ places: @escaping @MainActor () -> [NavigationLocation]) -> @MainActor () -> [NavigationControls.Entry] {
            {
                let resolver = NavigationResolver(model)
                return NavigationControls.entries(
                    places(), exists: resolver.exists, title: resolver.title, systemImage: resolver.systemImage)
            }
        }
        return NavigationControls(
            canGoBack: history.canGoBack, canGoForward: history.canGoForward,
            backEntries: entries { router.history.backEntries }, forwardEntries: entries { router.history.forwardEntries },
            goBack: { router.goBack(model: model) }, goForward: { router.goForward(model: model) },
            jump: { router.jump(to: $0, model: model) })
    }

    /// The sidebar's "Opened" group, with what its rows do (WIN-06).
    private var openedSidebar: OpenedSidebar {
        let store = model.opened
        let router = router
        return OpenedSidebar(
            items: store.items,
            selection: Binding(get: { router.opened }, set: { router.opened = $0 }),
            actions: OpenedItemActions(
                close: { router.close(opened: $0, in: store) },
                closeAll: {
                    store.closeAll()
                    if let id = router.opened, store.item(id) == nil {
                        router.opened = store.items.first?.id
                    }
                },
                setPinned: { store.setPinned($0, $1) },
                openInGitLab: { router.browse($0) },
                copyLink: { MainWindowLinks.copy($0) }),
            // Read in each row's own body, from what the store loaded: a load redraws that row, not the window.
            details: { item in
                OpenedItemRowDetails.make(
                    item: item, workItem: store.workItems[item.id],
                    related: store.related[item.id], build: store.builds[item.id])
            })
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

    /// "Open by Link…" shows while the router asks for it (WIN-06).
    private var isOpeningByLink: Binding<Bool> {
        @Bindable var router = router
        return $router.isOpeningByLink
    }

    /// the "Rebuild with Changes…" sheet shows while there is a request; closing it clears the request (PIPE-09)
    private var rebuildRequest: Binding<RebuildRequest?> {
        @Bindable var router = router
        return $router.rebuildRequest
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

/// The section's own items, from the section's lane; the others have none. The shell places them (and the spacer
/// after them) before the update item and the Open in and Reload group.
struct MainWindowSectionToolbar: ToolbarContent {
    let section: MainWindowSection
    /// Pipelines' Watch a Build…
    let watchBuild: @MainActor () -> Void
    /// Activity's inspector, which its toolbar toggles
    @Binding var activityInspectorShown: Bool
    /// Activity's Clear confirmation, which its toolbar asks for
    @Binding var isConfirmingClearActivity: Bool

    var body: some ToolbarContent {
        if section == .pipelines {
            PipelinesToolbarItems(watchBuild: watchBuild)
        }
        if section == .workItems {
            WorkItemsToolbar()
        }
        if section == .activity {
            ActivityToolbar(isInspectorShown: $activityInspectorShown, isConfirmingClear: $isConfirmingClearActivity)
        }
        if section == .slots {
            SlotsToolbarItems()
        }
        if section == .inbox {
            InboxToolbarItems()
        }
    }
}

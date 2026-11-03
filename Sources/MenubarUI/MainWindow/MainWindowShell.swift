import MenubarCore
import SwiftUI

/// The main window's shell drawn from plain values (`docs/design/main-window.md`): the split view with the sidebar,
/// the section's list and detail, the title and subtitle, the toolbar's groups and the search. ``MainWindowRoot``
/// fills it from the stores; the gallery fills it from fixtures.
struct MainWindowShell<Content: View, Detail: View, SectionToolbar: ToolbarContent>: View {
    let model: MainWindowShellModel
    @Binding var section: MainWindowSection
    @Binding var searchText: String
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// Open in GitLab and the rebuild
    let actions: PanelActions
    /// Reload's action, which loads the shown section again (``MainWindowReload``); `nil` does nothing, as in the gallery
    var reload: (@MainActor () -> Void)?
    /// grows when the search field should take the keyboard focus (⌘F)
    var searchFocusRequest = 0
    /// the easter egg note for the search text, above the list; `nil` for none (EGG-06)
    var searchNote: String?
    /// the "Opened" group of the sidebar; while one of its items is selected, the window shows its detail in place of a
    /// section's list and detail (WIN-06)
    var opened = OpenedSidebar()
    /// the Back and Forward buttons at the toolbar's leading side (WIN-08); `nil` shows none, as in the gallery
    var navigation: NavigationControls?
    /// the toolbar's "Open in GitLab" or "Open in Jenkins": always there, disabled without a link to open
    var detailLink = DetailLink(.gitLab)
    /// the sections the sidebar lists (Digest only while the Claude features are on)
    var sections = MainWindowSection.allCases
    /// called with the offsets and the destination of a drag of the sidebar's rows; `nil` leaves the rows fixed
    var moveSections: ((IndexSet, Int) -> Void)?
    private let content: Content
    private let detail: Detail
    private let sectionToolbar: SectionToolbar
    @FocusState private var isSearchFocused: Bool

    /// - Parameters:
    ///   - model: what the shell shows of the stores
    ///   - section: the sidebar's selection
    ///   - searchText: the search field's text
    ///   - columnVisibility: whether the sidebar shows
    ///   - actions: the toolbar's actions
    ///   - reload: Reload's action, which loads the shown section again
    ///   - searchFocusRequest: grows when the search field should take the keyboard focus
    ///   - searchNote: the easter egg note for the search text; `nil` for none
    ///   - opened: the "Opened" group
    ///   - navigation: the Back and Forward buttons; `nil` for none
    ///   - detailLink: the toolbar's "Open in GitLab" or "Open in Jenkins"
    ///   - sections: the sections the sidebar lists
    ///   - moveSections: what a drag of the sidebar's rows does
    ///   - content: the section's list
    ///   - detail: the section's detail; not shown for Activity, whose list is full width
    ///   - sectionToolbar: the section's own toolbar items: Watch a Build in Pipelines, the filter menu in Work Items,
    ///     Activity's items; empty for the others
    init(
        model: MainWindowShellModel, section: Binding<MainWindowSection>, searchText: Binding<String>,
        columnVisibility: Binding<NavigationSplitViewVisibility>, actions: PanelActions,
        reload: (@MainActor () -> Void)? = nil, searchFocusRequest: Int = 0,
        searchNote: String? = nil, opened: OpenedSidebar = OpenedSidebar(), navigation: NavigationControls? = nil,
        detailLink: DetailLink = DetailLink(.gitLab), sections: [MainWindowSection] = MainWindowSection.allCases,
        moveSections: ((IndexSet, Int) -> Void)? = nil,
        @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail,
        @ToolbarContentBuilder sectionToolbar: () -> SectionToolbar
    ) {
        self.model = model
        _section = section
        _searchText = searchText
        _columnVisibility = columnVisibility
        self.actions = actions
        self.reload = reload
        self.searchFocusRequest = searchFocusRequest
        self.searchNote = searchNote
        self.opened = opened
        self.navigation = navigation
        self.detailLink = detailLink
        self.sections = sections
        self.moveSections = moveSections
        self.content = content()
        self.detail = detail()
        self.sectionToolbar = sectionToolbar()
    }

    var body: some View {
        splitView
        .navigationTitle(opened.selected.map { $0.title ?? $0.reference } ?? section.title)
        .navigationSubtitle(opened.selected?.reference ?? model.subtitle ?? "")
        .modifier(
            SectionSearch(
                isOffered: MainWindowSearch.isOffered(section: section, opened: opened.selected?.kind), text: searchBinding,
                prompt: MainWindowSearch.prompt(section: section, opened: opened.selected?.kind), isFocused: $isSearchFocused))
        .onChange(of: searchFocusRequest) {
            isSearchFocused = true
        }
        .frame(minHeight: 480)
        // The butler peeks out of the window's edges now and then (the fun layer).
        .butlerPeek()
    }

    /// The field's text. Over an opened item the field belongs to the item's kind (a build searches Pipelines, a merge
    /// request Merge Requests, a work item Work Items) and starts empty: typing takes the window to that section's list
    /// with the query, the item staying under "Opened" (``MainWindowSearch``, WIN-06). The two-column window gives way to
    /// the three-column one then, which makes the system field again, so it takes the focus back once the change is
    /// through.
    private var searchBinding: Binding<String> {
        Binding(
            // Never the query of the section left behind, not even for the frame before the window clears it.
            get: { opened.selected == nil ? searchText : "" },
            set: { newValue in
                let target = MainWindowSearch.destination(typed: newValue, opened: opened.selected?.kind)
                searchText = newValue
                if let target {
                    section = target
                    opened.selection.wrappedValue = nil
                    isSearchFocused = false
                    Task { @MainActor in
                        await Task.yield()
                        isSearchFocused = true
                    }
                }
            })
    }

    /// The split view. Pipelines, Merge Requests and Work Items: the sidebar, the list and its detail. Activity: the
    /// sidebar and its log at full width, which shows the details in an inspector of its own (LOG-04; the user,
    /// 2026-10-29, "old look, new brains"); the `detail` view isn't shown then. Slots and Digest are full width too.
    @ViewBuilder
    private var splitView: some View {
        if opened.selected != nil {
            // An opened item has no list: the sidebar and the detail at full width.
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                detail
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .toolbar { toolbar }
            }
        } else if section.isFullWidth {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                content
                    .searchEggNote(searchNote)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .toolbar { toolbar }
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } content: {
                // No column's minimum height may become the window's: a tall detail would push the split view past the
                // window and slide the sidebar under the toolbar.
                content
                    .searchEggNote(searchNote)
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 560)
            } detail: {
                detail
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 520)
                    .toolbar { toolbar }
            }
        }
    }

    private var sidebar: some View {
        MainWindowSidebar(section: $section, sections: sections, moveSections: moveSections, badges: model.badges, markers: model.markers, unread: model.unread, gifts: model.gifts, opened: opened)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    /// The sidebar's visibility for the two-column split view, where `.detailOnly` hides the sidebar; the binding keeps
    /// the three-column values, where `.doubleColumn` does.
    private var twoColumnVisibility: Binding<NavigationSplitViewVisibility> {
        let visibility = $columnVisibility
        return Binding(
            get: { visibility.wrappedValue == .all ? .all : .detailOnly },
            set: { visibility.wrappedValue = $0 == .detailOnly ? .doubleColumn : .all })
    }

    /// Whether the section contributes its own items (Pipelines, Work Items, Activity), and not while an opened item
    /// takes the window, which has no list to watch or filter.
    private var showsSectionItems: Bool {
        opened.selected == nil && section.hasToolbarItems
    }

    /// The groups, leading to trailing: Back and Forward; then, after the flexible spacer that pushes the rest to the
    /// trailing edge, the section's own items, the update, and last Open in GitLab (or Jenkins) with Reload, in every
    /// section and over an opened item. A fixed spacer follows each group that is there and none else, so a group coming
    /// or going only moves the ones to its leading side: Open in and Reload never move (`main-window.md`, Toolbar).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let navigation {
            NavigationButtons(controls: navigation)
        }
        ToolbarSpacer(.flexible)
        if showsSectionItems {
            sectionToolbar
            ToolbarSpacer(.fixed)
        }
        if model.showsUpdateItem {
            // Lane U's update item (`update-row.md`), hidden as a whole while no update applies.
            ToolbarItem {
                UpdateToolbarButton(state: model.update, rebuild: actions.rebuild)
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            Button {
                if let url = detailLink.url {
                    actions.open(url)
                }
            } label: {
                Label(detailLink.title, systemImage: "arrow.up.forward.app")
            }
            .help(detailLink.title)
            // Without a selection that has a link the item stays, so Reload doesn't move.
            .disabled(detailLink.url == nil)
            Button {
                // During a check this starts nothing new (JERR-07); the scheduler sees to that.
                reload?()
            } label: {
                ReloadLabel(title: MainWindowReload.title(for: section, opened: opened.selected != nil), isBusy: model.isBusy)
            }
            .help(MainWindowReload.title(for: section, opened: opened.selected != nil))
            // Activity has nothing to fetch, and Digest is written by its own button only, never by a stray ⌘R; the item
            // stays, so the others don't move.
            .disabled(!MainWindowReload.isAvailable(in: section, opened: opened.selected != nil))
        }
    }
}

/// Reload's label, named for the section ("Reload Merge Requests"): its symbol, or a small spinner in the same place
/// while a check or load of the section runs past 1 s, so quick ones don't flicker and the item keeps its width
/// (`main-window.md`, Toolbar).
struct ReloadLabel: View {
    let title: String
    let isBusy: Bool
    @Environment(\.panelSpinnerDelay) private var delay
    @ViewState private var showsSpinner = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(showsSpinner ? 0 : 1)
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task(id: isBusy) {
            guard isBusy else {
                showsSpinner = false
                return
            }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            showsSpinner = !Task.isCancelled
        }
    }
}

/// The search field of the toolbar: in every section, Digest included, so the items after it never move.
private struct SectionSearch: ViewModifier {
    let isOffered: Bool
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOffered {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
                .searchFocused(isFocused)
        } else {
            content
        }
    }
}

/// What the search field is, and does, while an opened item is shown (WIN-06).
enum MainWindowSearch {
    /// Returns the section an opened item's kind belongs to, whose list its search filters: a build's is Pipelines, a merge
    /// request's Merge Requests, a work item's Work Items.
    ///
    /// - Parameter kind: the opened item's kind
    /// - Returns: the section, or `nil` for a kind without one, whose field is hidden
    static func section(for kind: OpenedItem.Kind) -> MainWindowSection? {
        switch kind {
        case .build: .pipelines
        case .mergeRequest: .mergeRequests
        case .workItem: .workItems
        }
    }

    /// Returns whether the search field is there.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - opened: the kind of the opened item that takes the window, if one does
    static func isOffered(section: MainWindowSection, opened: OpenedItem.Kind?) -> Bool {
        guard let opened else {
            return section.isSearchable
        }
        return Self.section(for: opened) != nil
    }

    /// Returns what the field's placeholder says: over an opened item what its kind searches, else the section's own.
    ///
    /// - Parameters:
    ///   - section: the shown section
    ///   - opened: the kind of the opened item that takes the window, if one does
    static func prompt(section: MainWindowSection, opened: OpenedItem.Kind?) -> String {
        guard let opened, let scope = Self.section(for: opened) else {
            return section.searchPrompt
        }
        // The section's own wording everywhere ("Search builds"), so the field reads the same from Pipelines and from an opened build.
        return scope.searchPrompt
    }

    /// Returns the section typed text takes the window to: over an opened item, which has no list, any text takes it to
    /// the list of the item's kind; clearing the field (or its ✕) leaves the item shown.
    ///
    /// - Parameters:
    ///   - typed: the field's new text
    ///   - opened: the kind of the opened item that takes the window, if one does
    /// - Returns: the section whose list shows with the query, or `nil` to stay
    static func destination(typed: String, opened: OpenedItem.Kind?) -> MainWindowSection? {
        guard let opened, !typed.isEmpty else {
            return nil
        }
        return section(for: opened)
    }
}

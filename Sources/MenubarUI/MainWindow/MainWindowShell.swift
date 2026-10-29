import MenubarCore
import SwiftUI

/// The main window's shell drawn from plain values (`docs/design/main-window.md`): the split view with the sidebar,
/// the section's list and detail, the title and subtitle, the toolbar's three groups and the search. ``MainWindowRoot``
/// fills it from the stores; the gallery fills it from fixtures.
struct MainWindowShell<Content: View, Detail: View, SectionToolbar: ToolbarContent>: View {
    let model: MainWindowShellModel
    @Binding var section: MainWindowSection
    @Binding var searchText: String
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// Check Now, Watch a Build… and the rebuild
    let actions: PanelActions
    /// grows when the search field should take the keyboard focus (⌘F)
    var searchFocusRequest = 0
    /// the easter egg note for the search text, above the list; `nil` for none (EGG-06)
    var searchNote: String?
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
    ///   - searchFocusRequest: grows when the search field should take the keyboard focus
    ///   - searchNote: the easter egg note for the search text; `nil` for none
    ///   - content: the section's list
    ///   - detail: the section's detail; not shown for Activity, whose list is full width
    ///   - sectionToolbar: the section's own toolbar items, group 1; empty for Pipelines and Merge Requests
    init(
        model: MainWindowShellModel, section: Binding<MainWindowSection>, searchText: Binding<String>,
        columnVisibility: Binding<NavigationSplitViewVisibility>, actions: PanelActions, searchFocusRequest: Int = 0,
        searchNote: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail,
        @ToolbarContentBuilder sectionToolbar: () -> SectionToolbar
    ) {
        self.model = model
        _section = section
        _searchText = searchText
        _columnVisibility = columnVisibility
        self.actions = actions
        self.searchFocusRequest = searchFocusRequest
        self.searchNote = searchNote
        self.content = content()
        self.detail = detail()
        self.sectionToolbar = sectionToolbar()
    }

    var body: some View {
        splitView
        .navigationTitle(section.title)
        .navigationSubtitle(model.subtitle ?? "")
        .searchable(text: $searchText, placement: .toolbar, prompt: Text(section.searchPrompt))
        .searchFocused($isSearchFocused)
        .onChange(of: searchFocusRequest) {
            isSearchFocused = true
        }
        .frame(minHeight: 480)
    }

    /// The split view. Pipelines, Merge Requests and Work Items: the sidebar, the list and its detail. Activity: the
    /// sidebar and its log at full width, which shows the details in an inspector of its own (LOG-04; the user,
    /// 2026-10-29, "old look, new brains"); the `detail` view isn't shown then.
    @ViewBuilder
    private var splitView: some View {
        if section == .activity || section == .slots {
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
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            } detail: {
                detail
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 520)
                    .toolbar { toolbar }
            }
        }
    }

    private var sidebar: some View {
        MainWindowSidebar(section: $section, badges: model.badges, markers: model.markers)
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

    /// The groups, leading to trailing: the section's, the update, the shared one. The flexible spacer pushes them all
    /// to the trailing edge, so the conditional groups grow toward the leading side and Watch a Build…, Check Now and
    /// the search never move (`main-window.md`, Toolbar).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        sectionToolbar
        if section == .workItems || section == .activity {
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
                actions.watchBuild()
            } label: {
                Label("Watch a Build…", systemImage: "binoculars")
            }
            .help("Watch the builds of someone else's merge request or branch")
            Button {
                // During a check this starts nothing new (JERR-07); the scheduler sees to that.
                actions.checkNow()
            } label: {
                CheckNowLabel(isBusy: model.isBusy)
            }
            .help("Check Jenkins and reload GitLab now")
        }
    }
}

/// Check Now's label: its symbol, or a small spinner in the same place while a check or load runs past 1 s, so quick
/// ones don't flicker and the item keeps its width (`main-window.md`, Toolbar).
struct CheckNowLabel: View {
    let isBusy: Bool
    @Environment(\.panelSpinnerDelay) private var delay
    @ViewState private var showsSpinner = false

    var body: some View {
        Label {
            Text("Check Now")
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

import MenubarCore
import SwiftUI

/// The Merge Requests section's content column (Task 5.3, `docs/design/merge-requests.md`): the problem rows, MR-01's
/// sections and the link row, filtered by the window's search.
///
/// It reads the stores from the environment and draws a ``MergeRequestsListContent`` from them, refreshed every 10 s
/// for the "updated 5m ago" ages.
public struct MergeRequestsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Binding private var selection: MergeRequest.ID?
    private let searchText: String

    /// - Parameters:
    ///   - selection: the selected merge request, by its web URL
    ///   - searchText: the window's search text; empty shows everything
    public init(selection: Binding<MergeRequest.ID?>, searchText: String) {
        _selection = selection
        self.searchText = searchText
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let list = MergeRequestsListModel(MergeRequestsData(model, now: context.date), query: searchText)
            MergeRequestsListContent(
                model: list,
                selection: $selection,
                actions: .live(model: model, router: router, openURL: openURL),
                search: list.showsGitLabSearch
                    ? GitLabSearchRows.make(
                        kind: .mergeRequest, text: searchText, shown: list.sections.flatMap(\.rows).map(\.mergeRequest.reference),
                        model: model, now: context.date)
                    : .hidden)
        }
        // "In GitLab" follows the search field (WIN-07).
        .onChange(of: searchText, initial: true) {
            model.gitLabSearch.update(kind: .mergeRequest, text: searchText)
        }
        .workspaceTagsClickable()
        .onAppear {
            // The tags name the checkouts, which are read while the list shows (WS-07).
            model.workspaces.show(by: Self.workspacesHost)
        }
        .onDisappear {
            model.workspaces.hide(by: Self.workspacesHost)
        }
    }

    /// the name this list reads the checkouts under, for its tags
    private static let workspacesHost = "merge-requests-section"
}

/// The Merge Requests list drawn from plain values, for the window and the gallery.
struct MergeRequestsListContent: View {
    let model: MergeRequestsListModel
    @Binding var selection: MergeRequest.ID?
    let actions: GitLabSectionActions
    /// the "In GitLab" section while the search has text (WIN-07)
    var search = GitLabSearchRows.hidden
    /// the "In GitLab" row that the arrow keys are on; the list's own selection stays, so the detail doesn't change
    @ViewState private var highlighted: URL?

    /// the list's selection with the "In GitLab" rows in it: the arrow keys reach them, and they open on a click or Return
    private var listSelection: Binding<MergeRequest.ID?> {
        Binding(
            get: { search.row(url: highlighted) != nil ? highlighted : selection },
            set: { newValue in
                if search.row(url: newValue) != nil {
                    highlighted = newValue
                } else {
                    highlighted = nil
                    selection = newValue
                }
            })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: listSelection) {
                MainWindowProblemRows(model.problems, openSettings: actions.openSettings)
                if let setup = model.setup {
                    setupRows(setup)
                }
                if model.isPlaceholder {
                    SectionPlaceholderRows()
                }
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            MergeRequestRowContent(row: row)
                                .tag(row.id)
                        }
                    }
                }
                GitLabSearchSection(search: search, tag: \.url) { actions.follow($0.url) }
                if let link = model.link {
                    Section {
                        Link("All Merge Requests in GitLab", destination: link)
                            .buttonStyle(.link)
                            .selectionDisabled()
                    }
                }
            }
            .contextMenu(forSelectionType: MergeRequest.ID.self) { ids in
                if let found = search.row(url: ids.first) {
                    Button(found.openTitle) { actions.open(found.url) }
                    Divider()
                    Button("Copy Link") { actions.copy(found.url) }
                } else if let row = model.row(ids.first) {
                    Button(row.openTitle) { actions.open(row.id) }
                    Divider()
                    Button("Copy Link") { actions.copy(row.id) }
                    if let newWorkItem = actions.newWorkItem {
                        Divider()
                        Button("New Follow-Up Item") { newWorkItem(.followUp(row.mergeRequest)) }
                    }
                }
            } primaryAction: { ids in
                // It shows in the detail already; ⌥ opens it in GitLab (the user, 2026-10-30).
                if let found = search.row(url: ids.first) {
                    actions.follow(found.url)
                } else if let row = model.row(ids.first) {
                    actions.follow(row.id)
                }
            }
            .onKeyPress(.return) {
                if let found = search.row(url: highlighted) {
                    actions.follow(found.url)
                    return .handled
                }
                guard let row = model.row(selection) else {
                    return .ignored
                }
                actions.follow(row.id)
                return .handled
            }
            .overlay {
                if model.showsEmpty {
                    ContentUnavailableView {
                        Label(MergeRequestSections.emptyText, systemImage: "arrow.triangle.pull")
                    } actions: {
                        if let link = model.emptyLink {
                            Link("All Merge Requests in GitLab", destination: link)
                        }
                    }
                } else if model.findsNothing, !search.isShown {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .task {
                // A selection from another section ("Show in Merge Requests") or a restored one comes into view.
                if let selection, model.row(selection) != nil {
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    /// MR-04's note and its three steps, in the panel's look rather than a red row: a missing token is a setup step
    /// (`docs/design/merge-requests.md`, Departures 4).
    @ViewBuilder
    private func setupRows(_ setup: MergeRequestsListModel.Setup) -> some View {
        Text(verbatim: PanelModel.SetupText.needsToken)
            .foregroundStyle(.secondary)
            .selectionDisabled()
        if let url = setup.newTokenURL {
            Link(PanelModel.SetupText.createToken, destination: url)
                .buttonStyle(.link)
                .selectionDisabled()
        }
        Button(PanelModel.SetupText.pasteToken) { actions.openSettings(.accounts) }
            .buttonStyle(.link)
            .help("Opens Settings → Accounts")
            .selectionDisabled()
        Button(PanelModel.SetupText.checkNow) { actions.checkNow() }
            .buttonStyle(.link)
            .selectionDisabled()
    }
}

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
            MergeRequestsListContent(
                model: MergeRequestsListModel(MergeRequestsData(model, now: context.date), query: searchText),
                selection: $selection,
                actions: .live(model: model, router: router, openURL: openURL))
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

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
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
                if let link = model.link {
                    Section {
                        Link("All Merge Requests in GitLab", destination: link)
                            .buttonStyle(.link)
                            .selectionDisabled()
                    }
                }
            }
            .contextMenu(forSelectionType: MergeRequest.ID.self) { ids in
                if let row = model.row(ids.first) {
                    Button(row.openTitle) { actions.open(row.id) }
                    Divider()
                    Button("Copy Link") { actions.copy(row.id) }
                    if let newWorkItem = actions.newWorkItem {
                        Divider()
                        Button("New Follow-Up Item") { newWorkItem(.followUp(row.mergeRequest)) }
                    }
                }
            } primaryAction: { ids in
                if let row = model.row(ids.first) {
                    actions.open(row.id)
                }
            }
            .onKeyPress(.return) {
                guard let row = model.row(selection) else {
                    return .ignored
                }
                actions.open(row.id)
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
                } else if model.findsNothing {
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

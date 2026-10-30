import MenubarCore
import SwiftUI

/// The Work Items section's content column (Task 5.4, `docs/design/work-items.md`): the problem rows, the filter
/// summary, WI-01's sections and the link row, filtered by the window's search.
///
/// It reads the stores from the environment and draws a ``WorkItemsListContent`` from them, refreshed every 10 s.
public struct WorkItemsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Binding private var selection: WorkItem.ID?
    private let searchText: String

    /// - Parameters:
    ///   - selection: the selected work item, by its full reference
    ///   - searchText: the window's search text; empty shows everything
    public init(selection: Binding<WorkItem.ID?>, searchText: String) {
        _selection = selection
        self.searchText = searchText
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let list = WorkItemsListModel(WorkItemsData(model, now: context.date), query: searchText)
            WorkItemsListContent(
                model: list,
                selection: $selection,
                actions: .live(model: model, router: router, openURL: openURL),
                search: list.showsGitLabSearch
                    ? GitLabSearchRows.make(
                        kind: .workItem, text: searchText, shown: list.sections.flatMap(\.rows).map(\.workItem.reference),
                        model: model, now: context.date)
                    : .hidden)
        }
        // "In GitLab" follows the search field (WIN-07).
        .onChange(of: searchText, initial: true) {
            model.gitLabSearch.update(kind: .workItem, text: searchText)
        }
    }
}

/// The Work Items list drawn from plain values, for the window and the gallery.
struct WorkItemsListContent: View {
    let model: WorkItemsListModel
    @Binding var selection: WorkItem.ID?
    let actions: GitLabSectionActions
    /// the "In GitLab" section while the search has text (WIN-07)
    var search = GitLabSearchRows.hidden
    /// the "In GitLab" row that the arrow keys are on; the list's own selection stays, so the detail doesn't change
    @ViewState private var highlighted: WorkItem.ID?

    /// the list's selection with the "In GitLab" rows in it: the arrow keys reach them, and they open on a click or Return
    private var listSelection: Binding<WorkItem.ID?> {
        Binding(
            get: { search.row(reference: highlighted) != nil ? highlighted : selection },
            set: { newValue in
                if search.row(reference: newValue) != nil {
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
                if let note = model.tokenNote {
                    // MR-04 in the note look: the steps are in Merge Requests.
                    Text(verbatim: note)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                    Button("Show Merge Requests") { actions.showSection(.mergeRequests) }
                        .buttonStyle(.link)
                        .selectionDisabled()
                }
                if model.isPlaceholder {
                    SectionPlaceholderRows()
                }
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            WorkItemRowContent(row: row)
                                .tag(row.id)
                        }
                    } header: {
                        Text(verbatim: section.title)
                    }
                }
                GitLabSearchSection(search: search, tag: \.reference) { actions.follow($0.url) }
                if let link = model.link {
                    Section {
                        Link("All Work Items in GitLab", destination: link)
                            .buttonStyle(.link)
                            .selectionDisabled()
                    }
                }
            }
            .contextMenu(forSelectionType: WorkItem.ID.self) { ids in
                if let found = search.row(reference: ids.first) {
                    Button(found.openTitle) { actions.open(found.url) }
                    Divider()
                    Button("Copy Link") { actions.copy(found.url) }
                } else if let row = model.row(ids.first) {
                    Button(row.openTitle) { actions.open(row.workItem.webURL) }
                    Divider()
                    Button("Copy Link") { actions.copy(row.workItem.webURL) }
                }
            } primaryAction: { ids in
                // It shows in the detail already; ⌥ opens it in GitLab (the user, 2026-10-30).
                if let found = search.row(reference: ids.first) {
                    actions.follow(found.url)
                } else if let row = model.row(ids.first) {
                    actions.follow(row.workItem.webURL)
                }
            }
            .onKeyPress(.return) {
                if let found = search.row(reference: highlighted) {
                    actions.follow(found.url)
                    return .handled
                }
                guard let row = model.row(selection) else {
                    return .ignored
                }
                actions.follow(row.workItem.webURL)
                return .handled
            }
            .overlay {
                if let empty = model.empty {
                    ContentUnavailableView {
                        Label(WorkItemSections.emptyText, systemImage: "checklist")
                    } description: {
                        Text(verbatim: empty.summary)
                    } actions: {
                        Button("Filters…") { actions.openSettings(.gitLab) }
                        if let link = empty.link {
                            Link("All Work Items in GitLab", destination: link)
                        }
                    }
                } else if model.findsNothing, !search.isShown {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .task {
                // A restored selection comes into view.
                if let selection, model.row(selection) != nil {
                    proxy.scrollTo(selection)
                }
            }
        }
    }
}

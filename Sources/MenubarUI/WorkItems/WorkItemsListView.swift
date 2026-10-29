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
            WorkItemsListContent(
                model: WorkItemsListModel(WorkItemsData(model, now: context.date), query: searchText),
                selection: $selection,
                actions: .live(model: model, router: router, openURL: openURL))
        }
    }
}

/// The Work Items list drawn from plain values, for the window and the gallery.
struct WorkItemsListContent: View {
    let model: WorkItemsListModel
    @Binding var selection: WorkItem.ID?
    let actions: GitLabSectionActions

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
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
                if let summary = model.summary {
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                if let link = model.link {
                    Section {
                        Link("All Work Items in GitLab", destination: link)
                            .buttonStyle(.link)
                            .selectionDisabled()
                    }
                }
            }
            .contextMenu(forSelectionType: WorkItem.ID.self) { ids in
                if let row = model.row(ids.first) {
                    Button(row.openTitle) { actions.open(row.workItem.webURL) }
                    Divider()
                    Button("Copy Link") { actions.copy(row.workItem.webURL) }
                }
            } primaryAction: { ids in
                if let row = model.row(ids.first) {
                    actions.open(row.workItem.webURL)
                }
            }
            .onKeyPress(.return) {
                guard let row = model.row(selection) else {
                    return .ignored
                }
                actions.open(row.workItem.webURL)
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
                } else if model.findsNothing {
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

import Foundation
import MenubarCore

/// Everything the Work Items section shows, as plain values: what the stores hold at one moment. The public views
/// take it from the stores; the gallery and the tests build it from fixtures.
struct WorkItemsData: Sendable {
    /// the time the ages count from
    var now: Date
    var team: TeamValues
    /// `PipelinesStore.problem`: offline, the team values or Jenkins' own, for the app-wide rows
    var jenkinsProblem: Problem?
    /// where the app's update stands, for "Update failed" (APP-05)
    var update: UpdateState
    /// the work items, their markers, the gone filter labels and the filters, from `WorkItemsStore`
    var workItems: PanelData.WorkItems
    /// the related MRs of the work items, by reference (WI-05, OD-03)
    var related: RelatedMergeRequestsCache
    /// GitLab's label colors remembered from the work items and label searches, by title (WI-06)
    var labelColors: [String: String]
    /// my GitLab username, for "All Work Items in GitLab"; `nil` before GitLab answered
    var me: String?
    /// the MRs of the Merge Requests store's last load, which offer "Show in Merge Requests"
    var mergeRequestIDs: Set<MergeRequest.ID>

    /// Returns the section's values: the panel's, which the main window's shell takes too, and the detail's.
    ///
    /// - Parameters:
    ///   - panel: the stores' values, as ``PanelView`` takes them
    ///   - related: the related MRs of the work items
    ///   - labelColors: the remembered label colors
    ///   - me: my GitLab username; `nil` takes the one of the last MR load
    init(
        _ panel: PanelData, related: RelatedMergeRequestsCache = RelatedMergeRequestsCache(),
        labelColors: [String: String] = [:], me: String? = nil
    ) {
        now = panel.now
        team = panel.team
        jenkinsProblem = panel.jenkins.problem
        update = panel.update
        workItems = panel.workItems
        self.related = related
        self.labelColors = labelColors
        self.me = me ?? panel.mergeRequests.list?.username
        mergeRequestIDs = Set(panel.mergeRequests.list?.mergeRequests.map(\.id) ?? [])
    }

    /// Returns what the stores hold now.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - now: the time the ages count from
    @MainActor
    init(_ model: AppModel, now: Date) {
        let workItems = model.workItems
        self.init(
            PanelView.data(model, now: now), related: workItems.relatedMergeRequests, labelColors: workItems.labels.colors,
            me: model.pipelines.gitLabUsername)
    }

    var lists: WorkItemLists? { workItems.lists }
    var problem: Problem? { workItems.problem }
    var isLoading: Bool { workItems.isLoading }
    var filters: WorkItemFilters { workItems.filters }
    var missingLabels: [String] { workItems.missingLabels }

    /// whether the section shows its own data: not while the team values are missing (TEAM-03) or the GitLab token is
    /// (MR-04)
    var showsWorkItems: Bool {
        !MainWindowProblems.teamValuesMissing(jenkinsProblem) && problem != .noToken(.gitLab)
    }

    /// Returns the short reference of a work item: "#31", "web#34", and "&12" for an epic, which belongs to a group
    /// (WI-04).
    func shortReference(of item: WorkItem) -> String {
        item.isEpic ? "&\(item.iid ?? "")" : item.shortReference(project: team.gitLabProject)
    }

    /// Returns the related-MR marker of a work item (WI-05).
    func marker(of item: WorkItem) -> RelatedMergeRequestMarker? {
        workItems.markers[item.reference]
    }
}

/// What the Work Items list shows of a ``WorkItemsData``, after the search: the problem rows, MR-04's note, the filter
/// summary, WI-01's sections, the link row, or the empty state (`docs/design/work-items.md`, List).
struct WorkItemsListModel: Sendable {
    /// the red rows on top: the app-wide ones, the work items' MR-05 problem, then one per gone filter label (WI-06)
    var problems: [PanelModel.ProblemItem]
    /// "Needs the GitLab token, see Merge Requests" (MR-04), with "Show Merge Requests"
    var tokenNote: String?
    /// the filters in one line (WI-02); hidden while searching and in the empty state, whose description it is
    var summary: String?
    /// two placeholder rows: never loaded (OD-01)
    var isPlaceholder: Bool
    /// the sections that have rows after the search, committed first (WI-01)
    var sections: [PanelModel.Subsection<WorkItemRowModel>]
    /// "No work items match the filter", with the summary as its description
    var empty: Empty?
    /// "All Work Items in GitLab", the last row; `nil` while searching, without a token or while empty
    var link: URL?
    /// the search text, trimmed
    var query: String

    /// The empty state's description and its link.
    struct Empty: Hashable, Sendable {
        var summary: String
        var link: URL?
    }

    /// whether a search finds nothing, which shows the system's no-results view
    var findsNothing: Bool {
        !query.isEmpty && tokenNote == nil && !isPlaceholder && sections.isEmpty && empty == nil
    }

    /// Returns the row with an id.
    ///
    /// - Parameter id: the work item's full reference
    /// - Returns: the row, or `nil` when no section has it
    func row(_ id: WorkItem.ID?) -> WorkItemRowModel? {
        guard let id else {
            return nil
        }
        return sections.lazy.flatMap(\.rows).first { $0.id == id }
    }

    /// Returns what the list shows.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - query: the window's search text; empty shows everything
    init(_ data: WorkItemsData, query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        problems = MainWindowProblems.appWide(jenkins: data.jenkinsProblem, update: data.update)
        tokenNote = nil
        summary = nil
        isPlaceholder = false
        sections = []
        empty = nil
        link = nil
        // TEAM-03 shows alone: nothing can be asked without the values.
        guard !MainWindowProblems.teamValuesMissing(data.jenkinsProblem) else {
            return
        }
        if data.problem == .noToken(.gitLab) {
            tokenNote = PanelModel.SetupText.workItemsNote
            return
        }
        // Offline shows the cached work items without other problem rows (OD-05).
        let offline = data.jenkinsProblem == .offline
        if !offline {
            if let problem = data.problem {
                problems.append(PanelModel.problemItem(problem))
            }
            problems += data.missingLabels.map {
                PanelModel.ProblemItem(text: "Filter label \($0) is not in GitLab any more", pane: .gitLab)
            }
        }
        let gitLabLink = data.team.gitLab.map { GitLabLinks.workItems(gitLab: $0, filters: data.filters, me: data.me) }
        let searching = !query.isEmpty
        guard let lists = data.lists else {
            isPlaceholder = data.problem == nil && !offline && !searching
            summary = searching ? nil : data.filters.summary
            link = searching ? nil : gitLabLink
            return
        }
        let all = WorkItemSections(lists, committedLabel: data.team.committedLabel)
        let shared = WorkItemRowModel.sharedLabels(of: all.sections.flatMap(\.list.items))
        sections = all.sections.map { section in
            let rows = section.list.items
                .map { WorkItemRowModel($0, data: data, sharedLabels: shared) }
                .filter { $0.matches(query) }
            return PanelModel.Subsection(title: section.title, rows: rows)
        }
        .filter { !$0.rows.isEmpty }
        if all.isEmpty {
            empty = searching ? nil : Empty(summary: data.filters.summary, link: gitLabLink)
        } else if !searching {
            summary = data.filters.summary
            link = gitLabLink
        }
    }
}

/// A work item's row: the panel's row (marker, reference, slot, title) and a second line with what tells rows apart
/// (`docs/design/work-items.md`, Work item row).
struct WorkItemRowModel: Hashable, Sendable, Identifiable {
    var workItem: WorkItem
    var marker: RelatedMergeRequestMarker?
    /// "#31", "&12" or "web#34"
    var reference: String
    /// the slot label's value, like "Q1"
    var slot: String?
    /// the slot label itself, which the row draws as GitLab draws it; `nil` without a slot
    var slotLabel: LabelPillModel?
    /// "Task · Closed · design"; `nil` when nothing is left
    var secondLine: String?
    /// "Open Work Item #31"
    var openTitle: String

    var id: WorkItem.ID { workItem.id }

    /// - Parameters:
    ///   - item: the work item
    ///   - data: the section's values, for the team's labels, the filters and the related MRs
    ///   - sharedLabels: the labels every shown item has, which the second line leaves out; see ``sharedLabels(of:)``
    init(_ item: WorkItem, data: WorkItemsData, sharedLabels: Set<String> = []) {
        workItem = item
        marker = data.marker(of: item)
        reference = data.shortReference(of: item)
        slot = item.slot(prefix: data.team.slotLabelPrefix)
        slotLabel = item.slotLabel(prefix: data.team.slotLabelPrefix).map { LabelPillModel($0, colors: data.labelColors) }
        secondLine = Self.secondLine(of: item, team: data.team, filters: data.filters, sharedLabels: sharedLabels)
        openTitle = "Open Work Item \(reference)"
    }

    /// Returns line 2: the type unless it is an issue or the Type filter fixes it, "Closed" under "Open and closed"
    /// only, then the labels, without those every row has: the slot label, the committed label, the must-have
    /// labels of "all" mode, and the labels every shown item carries.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values, for the committed label and the slot prefix
    ///   - filters: the work item filters
    ///   - sharedLabels: the labels every shown item has
    /// - Returns: the parts joined with " · ", or `nil` when nothing is left
    static func secondLine(
        of item: WorkItem, team: TeamValues, filters: WorkItemFilters, sharedLabels: Set<String> = []
    ) -> String? {
        var parts: [String] = []
        if item.type != .issue, filters.type == .all {
            parts.append(WorkItemText.type(item.type))
        }
        if filters.state == .all, item.state == .closed {
            parts.append(WorkItemText.state(item.state))
        }
        var shared: Set<String> = sharedLabels.union([team.committedLabel])
        if filters.labelsMatch == .all {
            shared.formUnion(filters.withLabels)
        }
        let prefix = team.slotLabelPrefix
        let slotLabel = prefix.isEmpty ? nil : item.labels.first { $0.title.hasPrefix(prefix) }?.title
        parts += item.labels.map(\.title).filter { !shared.contains($0) && $0 != slotLabel }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Returns the labels every one of the shown items has, such as a team's routine group or status label: they tell
    /// nothing apart, so the second line leaves them out. One item shares nothing, since there is nothing to tell
    /// apart from.
    ///
    /// - Parameter items: the items the list or the flyout shows
    /// - Returns: the titles of the labels all of them carry; empty for fewer than two items
    static func sharedLabels(of items: [WorkItem]) -> Set<String> {
        guard items.count > 1 else {
            return []
        }
        return items.dropFirst().reduce(Set(items[0].labels.map(\.title))) { $0.intersection($1.labels.map(\.title)) }
    }

    /// Returns whether the row matches a search: its title, its reference, its slot or any label title, ignoring case
    /// (`docs/design/work-items.md`, Search; WIN-03).
    ///
    /// - Parameter query: the trimmed search text; empty matches
    func matches(_ query: String) -> Bool {
        PanelModel.matches(query, [workItem.title, reference, slot ?? ""] + workItem.labels.map(\.title))
    }
}

extension WorkItem {
    /// Returns the slot label: the first label that starts with the slot prefix (WI-04).
    ///
    /// - Parameter prefix: the slot label prefix from Team; empty means no slot
    /// - Returns: the label, or `nil`
    func slotLabel(prefix: String) -> Label? {
        prefix.isEmpty ? nil : labels.first { $0.title.hasPrefix(prefix) }
    }
}

/// The words of a work item's facts.
enum WorkItemText {
    /// "Issue", "Task", "Epic", "Incident"; others GitLab's value with `_` as spaces, first letter capital ("Test case")
    static func type(_ type: WorkItemType) -> String {
        capitalizedFirst(type.rawValue.lowercased().replacingOccurrences(of: "_", with: " "))
    }

    /// "Open", "Closed"; others GitLab's word, first letter capital
    static func state(_ state: WorkItemState) -> String {
        state == .opened ? "Open" : capitalizedFirst(state.rawValue.replacingOccurrences(of: "_", with: " "))
    }

    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What the Work Items detail shows of the selected item (`docs/design/work-items.md`, Detail): the header, the facts,
/// the label pills and the related merge requests. Built from the stores' values only, so selecting asks nothing.
struct WorkItemDetailModel: Sendable {
    var workItem: WorkItem
    var marker: RelatedMergeRequestMarker?
    /// "Open Work Item #31"
    var openTitle: String
    /// the slot label, drawn as GitLab draws it; `nil` when the item has no slot or Team has no slot prefix (WI-04)
    var slotLabel: LabelPillModel?
    /// "Open", "Closed"
    var state: String
    /// "Issue", "Task", "Epic"
    var type: String
    /// "5m ago"
    var updated: String
    /// the easter egg line under the last update (EGG-20); set by the view, `nil` for none
    var eggLine: String?
    /// every label in GitLab's order; empty shows "No labels"
    var labels: [LabelPillModel]
    var related: Related
    /// "GitLab lists at most 10 related merge requests", "Merge requests starting with [cascade] don't count for the
    /// marker"
    var relatedFooters: [String]

    /// What the related merge requests part shows.
    enum Related: Hashable, Sendable {
        /// the answer's MRs: open first, then merged, closed and others, then the ignored ones
        case rows([RelatedMergeRequestRow])
        /// an answer without MRs: "No merge request mentions this work item"
        case none
        /// no answer, a load runs: a small spinner in the part
        case loading
        /// no answer and no load (the request failed, offline)
        case unknown
        /// epics aren't asked (WI-05)
        case epic
    }

    static let noLabels = "No labels"
    static let noMergeRequests = "No merge request mentions this work item"
    static let mergeRequestsUnknown = "Merge requests unknown: GitLab is asked again at the next check"
    static let epicNote = "Related merge requests aren't looked up for epics"
    static let atMostTen = "GitLab lists at most 10 related merge requests"
    /// how many related MRs GitLab is asked for, `relatedMergeRequests(first: 10)` in
    /// `GitLabOperation.relatedMergeRequests(of:)`
    static let relatedLimit = 10

    /// Returns the detail of the selected work item.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - selection: the selected work item, by its full reference
    /// - Returns: the detail; `nil` without a selection, or when the item left the list, which shows a blank
    ///   detail
    init?(_ data: WorkItemsData, selection: WorkItem.ID?) {
        guard let selection, data.showsWorkItems, let item = data.lists?.all.first(where: { $0.id == selection }) else {
            return nil
        }
        let team = data.team
        workItem = item
        marker = data.marker(of: item)
        openTitle = "Open Work Item \(data.shortReference(of: item))"
        slotLabel = item.slotLabel(prefix: team.slotLabelPrefix).map { LabelPillModel($0, colors: data.labelColors) }
        state = WorkItemText.state(item.state)
        type = WorkItemText.type(item.type)
        updated = "\(GitLabText.age(since: item.updatedAt, now: data.now)) ago"
        labels = item.labels.map { LabelPillModel($0, colors: data.labelColors) }
        relatedFooters = []
        if item.isEpic {
            related = .epic
        } else if let entry = data.related.entries[item.reference] {
            let rows = RelatedMergeRequestRow.rows(entry.mergeRequests, data: data)
            related = rows.isEmpty ? .none : .rows(rows)
            if entry.mergeRequests.count >= Self.relatedLimit {
                relatedFooters.append(Self.atMostTen)
            }
            if rows.contains(where: \.isIgnored) {
                relatedFooters.append("Merge requests starting with \(team.ignoredMergeRequestPrefix) don't count for the marker")
            }
        } else {
            related = data.isLoading ? .loading : .unknown
        }
    }
}

/// A related merge request in the work item detail: its state's symbol, its title, "!14 · open", and "Show in Merge
/// Requests" while the Merge Requests store has it.
struct RelatedMergeRequestRow: Hashable, Sendable, Identifiable {
    var mergeRequest: RelatedMergeRequest
    var symbol: String
    /// whether the symbol is `.secondary` (closed and other states) rather than the label color
    var isSymbolSecondary: Bool
    /// "!14 · open", "web!8 · merged"
    var reference: String
    /// "Open Merge Request !14"
    var openTitle: String
    /// whether its title starts with Team's ignored prefix, like "[cascade] …": listed last, greyed (WI-05)
    var isIgnored: Bool
    /// whether the Merge Requests store's last load has it (same web URL)
    var showsInMergeRequests: Bool

    var id: URL { mergeRequest.webURL }

    /// Returns the rows of an answer: the counted MRs, open first, then merged, closed and others, each in GitLab's
    /// order; then the ignored ones in the same order.
    ///
    /// - Parameters:
    ///   - mergeRequests: the answer's MRs, in GitLab's order
    ///   - data: the section's values, for the team and the Merge Requests store's MRs
    /// - Returns: the rows
    static func rows(_ mergeRequests: [RelatedMergeRequest], data: WorkItemsData) -> [RelatedMergeRequestRow] {
        let rows = mergeRequests.map { RelatedMergeRequestRow($0, data: data) }
        return rows.enumerated()
            .sorted { ($0.element.isIgnored ? 1 : 0, $0.element.rank, $0.offset) < ($1.element.isIgnored ? 1 : 0, $1.element.rank, $1.offset) }
            .map(\.element)
    }

    init(_ mergeRequest: RelatedMergeRequest, data: WorkItemsData) {
        self.mergeRequest = mergeRequest
        let short = GitLabText.shortReference(mergeRequest.reference, project: data.team.gitLabProject)
        let word = mergeRequest.state == .opened ? "open" : mergeRequest.state.rawValue.lowercased()
        reference = "\(short) · \(word)"
        openTitle = "Open Merge Request \(short)"
        switch mergeRequest.state {
        case .opened: (symbol, isSymbolSecondary) = ("arrow.triangle.pull", false)
        case .merged: (symbol, isSymbolSecondary) = ("arrow.triangle.merge", false)
        case .closed: (symbol, isSymbolSecondary) = ("stop.circle", true)
        default: (symbol, isSymbolSecondary) = ("questionmark.circle", true)
        }
        let prefix = data.team.ignoredMergeRequestPrefix
        isIgnored = !prefix.isEmpty && mergeRequest.title.hasPrefix(prefix)
        showsInMergeRequests = data.mergeRequestIDs.contains(mergeRequest.webURL)
    }

    /// open, merged, closed, others
    private var rank: Int {
        switch mergeRequest.state {
        case .opened: 0
        case .merged: 1
        case .closed: 2
        default: 3
        }
    }
}

/// A label as a pill (`docs/design/work-items.md`, Label pills): its title, plain text (WI-04), and GitLab's color.
struct LabelPillModel: Hashable, Sendable, Identifiable {
    var title: String
    /// GitLab's color, `#rrggbb`; `nil` when not known
    var color: String?
    /// a scoped label's scope and value, split at its last `::`
    var scope: String?
    var value: String?

    var id: String { title }

    /// a scoped label's value, like "2026.51", else the title: what a slot pill shows
    var shortTitle: String { value ?? title }

    /// - Parameters:
    ///   - label: the label, with the color the work item came with
    ///   - colors: the remembered colors, for a label without one
    init(_ label: Label, colors: [String: String] = [:]) {
        title = label.title
        color = label.color ?? colors[label.title]
        let parts = Label.scopeAndValue(of: label.title)
        scope = parts?.scope
        value = parts?.value
    }
}

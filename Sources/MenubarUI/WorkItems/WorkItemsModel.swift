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
    /// which labels the rows' second line shows and how (WI-04)
    var rowLabels: WorkItemRowLabels { workItems.rowLabels }
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
    /// two placeholder rows: never loaded (OD-01)
    var isPlaceholder: Bool
    /// the sections that have rows after the search, committed first (WI-01)
    var sections: [PanelModel.Subsection<WorkItemRowModel>]
    /// "No work items match the filter", with the summary as its description
    var empty: Empty?
    /// the filters in one line, for the bar above the first section; `nil` without the team values or the token
    var filterSummary: String?
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

    /// whether the "In GitLab" search may show: GitLab is asked only with the team values and the token (WIN-07)
    var showsGitLabSearch: Bool {
        !query.isEmpty && tokenNote == nil
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
        filterSummary = nil
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
        filterSummary = data.filters.summary
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
            link = gitLabLink
        }
    }
}

/// A work item's row: the panel's row (marker, reference, slot, title) and a second line with what tells rows apart
/// (`docs/design/work-items.md`, Work item row).
struct WorkItemRowModel: Hashable, Sendable, Identifiable {
    var workItem: WorkItem
    var marker: RelatedMergeRequestMarker?
    /// the chip on line 2 for the item's merge request, like "!14 +1"; `nil` without a counted open or merged MR
    var mergeRequestChip: WorkItemMergeRequestChip?
    /// "#31", "&12" or "web#34"
    var reference: String
    /// the slot label's value, like "Q1"
    var slot: String?
    /// the slot label itself, which the row draws as GitLab draws it; `nil` without a slot
    var slotLabel: LabelPillModel?
    /// "Task · Closed · design"; `nil` when nothing is left
    var secondLine: String?
    /// "5m ago", at the right end of the row's first line
    var age: String
    /// "Open Work Item #31 in GitLab"
    var openTitle: String

    var id: WorkItem.ID { workItem.id }

    /// - Parameters:
    ///   - item: the work item
    ///   - data: the section's values, for the team's labels, the filters and the related MRs
    ///   - sharedLabels: the labels every shown item has, which the second line leaves out; see ``sharedLabels(of:)``
    init(_ item: WorkItem, data: WorkItemsData, sharedLabels: Set<String> = []) {
        workItem = item
        marker = data.marker(of: item)
        mergeRequestChip = WorkItemMergeRequestChip.make(
            data.related.shownMergeRequests(of: item) ?? [], marker: marker, project: data.team.gitLabProject,
            ignoredPrefix: data.team.ignoredMergeRequestPrefix)
        reference = data.shortReference(of: item)
        slot = item.slot(prefix: data.team.slotPrefix)
        slotLabel = item.slotLabel(prefix: data.team.slotPrefix).map { LabelPillModel($0, colors: data.labelColors) }
        secondLine = Self.secondLine(of: item, team: data.team, filters: data.filters, sharedLabels: sharedLabels,
            rowLabels: data.rowLabels)
        age = "\(GitLabText.age(since: item.updatedAt, now: data.now)) ago"
        openTitle = "Open Work Item \(reference) in GitLab"
    }

    /// Returns line 2: the type unless it is an issue or the Type filter fixes it, "Closed" under "Open and closed"
    /// only, then the labels, without those every row has: the slot label, the committed label, the must-have
    /// labels of "all" mode, and the labels every shown item carries; then the user's "Hide on rows" and "Show scoped
    /// labels by their value only" (WI-04), which touch this line only.
    ///
    /// - Parameters:
    ///   - item: the work item
    ///   - team: the team values, for the committed label and the slot prefix
    ///   - filters: the work item filters
    ///   - sharedLabels: the labels every shown item has
    ///   - rowLabels: which labels to hide and whether scoped ones show by their value
    /// - Returns: the parts joined with " · ", or `nil` when nothing is left
    static func secondLine(
        of item: WorkItem, team: TeamValues, filters: WorkItemFilters, sharedLabels: Set<String> = [],
        rowLabels: WorkItemRowLabels = WorkItemRowLabels()
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
        // The pill shows the slot; the due slot's label shows here only when it names another slot.
        var hidden: Set<String> = []
        if let label = item.slotLabel(prefix: team.slotPrefix) {
            hidden.insert(label.title)
        }
        if let prefix = team.dueSlotPrefix, let label = item.slotLabel(prefix: prefix),
            SlotPlan.dueSlot(of: item, team: team) == SlotPlan.slot(of: item, team: team) {
            hidden.insert(label.title)
        }
        parts += item.labels.map(\.title).filter { !shared.contains($0) && !hidden.contains($0) }
            .compactMap { rowLabels.text(of: $0) }
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

/// The chip on a work item row's second line for its merge requests (Task 7.x, the user, 2026-11-02: the symbol column
/// wasted the row's left): the first MR's reference, "!14", with "+1" for each further one, in the merge request green
/// whatever the state (the user, 2026-11-03). Only the MRs that count make it, the open ones first, then the merged ones;
/// closed MRs and the ignored prefix (cascade MRs) don't, as for the marker (WI-05).
struct WorkItemMergeRequestChip: Hashable, Sendable {
    /// "!14", "web!8 +2"; `nil` when only the marker is known
    var text: String?
    /// the MRs, one per line: "!14 · open · Rework the color tokens"
    var help: String

    /// The chip's text with the count: "!14" for one MR, "!14 +2" for three.
    static func text(first: String, count: Int) -> String {
        count > 1 ? "\(first) +\(count - 1)" : first
    }

    /// Returns the chip of a work item.
    ///
    /// - Parameters:
    ///   - mergeRequests: the MRs that count for the work item (its own, else all), in GitLab's order
    ///   - marker: the item's marker, for a chip when the MRs themselves are not known
    ///   - project: the team's project path, for the short reference
    ///   - ignoredPrefix: the ignored MR prefix from Team; empty counts every MR
    /// - Returns: the chip, or `nil` without a counted open or merged MR
    static func make(
        _ mergeRequests: [RelatedMergeRequest], marker: RelatedMergeRequestMarker?, project: String, ignoredPrefix: String
    ) -> WorkItemMergeRequestChip? {
        let counted = mergeRequests.filter {
            ($0.state == .opened || $0.state == .merged) && (ignoredPrefix.isEmpty || !$0.title.hasPrefix(ignoredPrefix))
        }
        let ordered = counted.filter { $0.state == .opened } + counted.filter { $0.state == .merged }
        guard let first = ordered.first else {
            return marker.map {
                WorkItemMergeRequestChip(text: nil, help: $0.text)
            }
        }
        let lines = ordered.map { request in
            let word = request.state == .merged ? "merged" : (isDraft(request.title) ? "draft" : "open")
            return ReferenceKind.tooltip(GitLabText.shortReference(request.reference, project: project), state: word, title: request.title)
        }
        return WorkItemMergeRequestChip(
            text: text(first: GitLabText.shortReference(first.reference, project: project), count: ordered.count),
            help: lines.joined(separator: "\n"))
    }

    /// Returns whether an MR title marks a draft, as GitLab does.
    static func isDraft(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return ["draft:", "[draft]", "(draft)", "wip:"].contains { lowered.hasPrefix($0) }
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
/// the label pills, the slot's dates and the related merge requests with their builds and the flags (SLOT-03). Built
/// from the stores' values only, so selecting asks nothing.
struct WorkItemDetailModel: Sendable {
    var workItem: WorkItem
    var marker: RelatedMergeRequestMarker?
    /// "Open Work Item #31 in GitLab"
    var openTitle: String
    /// "#31", "web#34", "&12"
    var shortReference: String
    /// the project's or the epic's group's name, the last part of its path: "project"
    var projectName: String
    /// who opened it; `nil` when GitLab didn't say
    var author: MergeRequest.Person?
    /// who it is assigned to; empty for nobody, and before GitLab was asked for them
    var assignees: [MergeRequest.Person]
    /// the slot's dates, when the slot label names a week (SLOT-01)
    var slot: Slot?
    /// what only the merge requests and builds reveal, each with its fix (SLOT-03); only for committed items of a shown
    /// slot
    var flags: [SlotFlag]

    /// The slot the item is planned for, with its dates.
    struct Slot: Hashable, Sendable {
        var name: SlotName
        var dates: SlotDates
        /// "Code freeze in 3 days", "Released 5 days ago"
        var countdown: String
        /// whether the release passed while the item is still open
        var isOverdue: Bool
        /// the time the steps count from
        var today: Date
    }
    /// the slot the item is in, by its slot label or its scheduled slot label (`SlotPlan.slot(of:team:)`); `nil` without
    /// one. "Show in Slots" appears with it.
    var slotName: SlotName?
    /// the due slot, the one the item is committed to, when it differs from ``slotName``; the Slot card says "due …"
    var dueSlot: SlotName?
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
    /// the header's facts panel: the scoped labels as lines, the rest behind "+N labels" (WI-04)
    var facts: WorkItemFacts
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
    ///   - reality: the item's merge requests with their builds and its flags, from `AppModel.slotItem(of:)`; `nil`
    ///     shows no builds and no flags
    ///   - calendar: the calendar whose days count for the slot's dates
    /// - Returns: the detail; `nil` without a selection, or when the item left the list, which shows a blank
    ///   detail
    init?(_ data: WorkItemsData, selection: WorkItem.ID?, reality: SlotItem? = nil, calendar: Calendar = .current) {
        guard let selection, data.showsWorkItems, let item = data.lists?.all.first(where: { $0.id == selection }) else {
            return nil
        }
        self.init(data, workItem: item, reality: reality, calendar: calendar)
    }

    /// Returns the detail of a work item that isn't in the lists, one opened under "Opened" (WIN-06). Its related merge
    /// requests are the ones in `data.related`, if any.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - workItem: the work item, as loaded for itself
    ///   - reality: the item's merge requests with their builds and its flags; `nil` shows none
    ///   - calendar: the calendar whose days count for the slot's dates
    init(_ data: WorkItemsData, workItem item: WorkItem, reality: SlotItem? = nil, calendar: Calendar = .current) {
        let team = data.team
        workItem = item
        marker = data.marker(of: item)
        shortReference = data.shortReference(of: item)
        openTitle = "Open Work Item \(shortReference) in GitLab"
        let path = item.reference.split(whereSeparator: { $0 == "#" || $0 == "&" }).first.map(String.init) ?? ""
        projectName = path.split(separator: "/").last.map(String.init) ?? path
        author = item.author
        assignees = item.assignees ?? []
        flags = reality?.id == item.id ? reality?.flags ?? [] : []
        slot = Self.slot(of: item, team: team, now: data.now, calendar: calendar)
        slotName = SlotPlan.slot(of: item, team: team)
        slotLabel = item.slotLabel(prefix: team.slotPrefix).map { LabelPillModel($0, colors: data.labelColors) }
        let due = SlotPlan.dueSlot(of: item, team: team)
        dueSlot = due == slotName ? nil : due
        state = WorkItemText.state(item.state)
        type = WorkItemText.type(item.type)
        updated = "\(GitLabText.age(since: item.updatedAt, now: data.now)) ago"
        labels = item.labels.map { LabelPillModel($0, colors: data.labelColors) }
        facts = WorkItemFacts(labels: labels, team: team)
        relatedFooters = []
        if item.isEpic {
            related = .epic
        } else if let entry = data.related.entries[item.reference] {
            let builds = reality?.id == item.id ? reality?.mergeRequests ?? [] : []
            let rows = RelatedMergeRequestRow.rows(entry.mergeRequests, of: item, data: data).map { row in
                var row = row
                row.build = builds.first { $0.id == row.id }?.build
                return row
            }
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

    /// Returns the slot of an item whose slot label names a week, with its dates from the team's rules.
    private static func slot(of item: WorkItem, team: TeamValues, now: Date, calendar: Calendar) -> Slot? {
        guard let name = SlotPlan.slot(of: item, team: team),
            let dates = SlotRules(team: team).dates(of: name, calendar: calendar)
        else {
            return nil
        }
        let isOverdue = item.state != .closed && dates.release < calendar.startOfDay(for: now)
        return Slot(
            name: name, dates: dates, countdown: dates.countdown(from: now, calendar: calendar), isOverdue: isOverdue, today: now)
    }

    /// the item's own merge requests that count, open first: those of the header's chips. When none is its own, every
    /// one that mentions it, as before
    var countedMergeRequests: [RelatedMergeRequestRow] {
        guard case .rows(let rows) = related else {
            return []
        }
        return rows.filter { $0.isOwn && !$0.isIgnored && $0.mergeRequest.state != .closed }
    }

    /// the rows of the card's first group: the item's own merge requests, or all of them when none is its own
    var ownMergeRequests: [RelatedMergeRequestRow] {
        guard case .rows(let rows) = related else {
            return []
        }
        return rows.filter(\.isOwn)
    }

    /// the rows of the card's quieter "Mentioned in" group: the merge requests that only mention the item; empty when
    /// none is its own
    var mentionedMergeRequests: [RelatedMergeRequestRow] {
        guard case .rows(let rows) = related else {
            return []
        }
        return rows.filter { !$0.isOwn }
    }

    /// how many merge requests "Mentioned in" shows at most before it is collapsed
    static let mentionedShownOpen = 2
}

/// A related merge request in the work item detail: its state's symbol, its title, "!14 · open", and "Show in Merge
/// Requests" while the Merge Requests store has it.
struct RelatedMergeRequestRow: Hashable, Sendable, Identifiable {
    var mergeRequest: RelatedMergeRequest
    /// "!14", "web!8": the reference as the chip shows it
    var reference: String
    /// "open", "merged", "closed": GitLab's word, for the tooltips
    var stateWord: String
    /// "Merged", "Closed": what the card's row says beside the chip; `nil` for an open one, which needs no word (the user,
    /// 2026-11-03: the state "only where it's needed and makes sense")
    var stateNote: String?
    /// "!14 · merged · Title", the tooltip of its chips and its row
    var help: String
    /// "Show Merge Request !14", which opens in the app
    var openTitle: String
    /// whether its title starts with Team's ignored prefix, like "[cascade] …": listed last, greyed (WI-05)
    var isIgnored: Bool
    /// whether it is the item's own MR, or counts as one because none is (see ``WorkItem/shownMergeRequests(from:)``),
    /// not one that only mentions the item
    var isOwn: Bool
    /// whether the Merge Requests store's last load has it (same web URL)
    var showsInMergeRequests: Bool
    /// the build the app knows of it (SLOT-03): Jenkins' `MR-<iid>` job, else GitLab's head pipeline of my MR
    var build: BuildReality?

    var id: URL { mergeRequest.webURL }

    /// Returns the rows of an answer: the item's own MRs first, then those that only mention it; in each group the
    /// counted MRs, open first, then merged, closed and others, each in GitLab's order; then the ignored ones in the same
    /// order.
    ///
    /// - Parameters:
    ///   - mergeRequests: the answer's MRs, in GitLab's order
    ///   - workItem: the work item, for which MRs are its own
    ///   - data: the section's values, for the team and the Merge Requests store's MRs
    /// - Returns: the rows
    static func rows(_ mergeRequests: [RelatedMergeRequest], of workItem: WorkItem, data: WorkItemsData) -> [RelatedMergeRequestRow] {
        let shown = Set(workItem.shownMergeRequests(from: mergeRequests).map(\.id))
        let rows = mergeRequests.map { RelatedMergeRequestRow($0, isOwn: shown.contains($0.id), data: data) }
        func key(_ row: RelatedMergeRequestRow) -> [Int] { [row.isOwn ? 0 : 1, row.isIgnored ? 1 : 0, row.rank] }
        return rows.enumerated()
            .sorted { key($0.element) == key($1.element) ? $0.offset < $1.offset : key($0.element).lexicographicallyPrecedes(key($1.element)) }
            .map(\.element)
    }

    init(_ mergeRequest: RelatedMergeRequest, isOwn: Bool = true, data: WorkItemsData) {
        self.mergeRequest = mergeRequest
        self.isOwn = isOwn
        let short = GitLabText.shortReference(mergeRequest.reference, project: data.team.gitLabProject)
        let word = mergeRequest.state == .opened ? "open" : mergeRequest.state.rawValue.lowercased()
        reference = short
        stateWord = word
        stateNote = mergeRequest.state == .opened ? nil : word.prefix(1).uppercased() + word.dropFirst()
        help = ReferenceKind.tooltip(short, state: word, title: mergeRequest.title)
        openTitle = "Show Merge Request \(short)"
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

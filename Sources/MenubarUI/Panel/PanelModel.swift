import Foundation
import MenubarCore

/// What the panel shows of a ``PanelData``, after the search: its problem rows, its build sections in order, one summary
/// row each for Merge Requests and Work Items, and the footer (APP-06, `docs/design/panel.md`). Pure, so the tests and
/// the gallery get the same answers as the panel.
public struct PanelModel: Sendable {
    /// A section of the content, in the order the panel shows them.
    public enum Section: String, Hashable, Sendable {
        case problems
        case myBuilds
        case watching
        case allBuilds
        case mergeRequests
        case workItems
    }

    /// the red rows on top: Jenkins, the team values, offline
    public var problems: [ProblemItem]
    /// My Builds; `nil` when it doesn't show
    public var myBuilds: BuildsSection?
    /// Watching, only while a watched build shows (WATCH-04)
    public var watching: [BuildRowModel]
    /// "All Builds in Jenkins"; `nil` when it doesn't show
    public var allBuilds: URL?
    /// the Merge Requests summary row; `nil` while searching, which finds builds only
    public var mergeRequests: Summary?
    /// the Work Items summary row; `nil` while searching
    public var workItems: Summary?
    public var footer: Footer
    /// the search text, trimmed; empty without a search
    public var query: String

    /// the sections that show, in their order
    public var sections: [Section] {
        var sections: [Section] = []
        if !problems.isEmpty { sections.append(.problems) }
        if myBuilds != nil { sections.append(.myBuilds) }
        if !watching.isEmpty { sections.append(.watching) }
        if allBuilds != nil { sections.append(.allBuilds) }
        if mergeRequests != nil { sections.append(.mergeRequests) }
        if workItems != nil { sections.append(.workItems) }
        return sections
    }

    /// whether a search finds nothing at all, which shows the system's no-results view
    public var findsNothing: Bool {
        !query.isEmpty && (myBuilds?.rows.count ?? 0) + watching.count == 0
    }

    /// the summary rows that show, in their order
    public var summaries: [Summary] {
        [mergeRequests, workItems].compactMap { $0 }
    }

    // MARK: - Parts

    /// A red problem row; it opens Settings at its pane when one fixes it.
    public struct ProblemItem: Hashable, Sendable, Identifiable {
        public var text: String
        /// the pane that fixes it; `nil` for a row that only informs
        public var pane: SettingsPane?
        public var id: String { text }

        /// "Opens Settings → Accounts", the tooltip of a linked row
        public var help: String? {
            pane.map { "Opens Settings → \($0.title)" }
        }
    }

    /// My Builds: rows, or the text without builds, or placeholders before the first check.
    public struct BuildsSection: Sendable {
        public var rows: [BuildRowModel]
        /// "No merge request builds by jdoe in Jenkins" or "No builds to show" (PIPE-06)
        public var note: String?
        /// two placeholder rows: no check has answered yet (OD-01)
        public var isPlaceholder: Bool
    }

    /// A titled list inside Merge Requests or Work Items, like "Review Requested" or "Committed (2)".
    public struct Subsection<Row: Hashable & Sendable & Identifiable>: Hashable, Sendable, Identifiable {
        public var title: String
        public var rows: [Row]
        public var id: String { title }
    }

    /// One summary row for a GitLab section: the logo, the title, what the section holds in a few words, and a chevron
    /// that opens the main window at that section.
    public struct Summary: Hashable, Sendable {
        public var section: MainWindowSection
        /// "Merge Requests" or "Work Items"
        public var title: String
        /// "2 open · 1 to review", "2 committed", "20 items"; `nil` while nothing is known yet
        public var text: String?
        /// whether the text is the work items' "N committed", which the row draws as a pill so the commitment stands out
        public var isCommitted: Bool
        /// the committed label's GitLab color, `#rrggbb`, for that pill; `nil` when not known
        public var tint: String?
        /// whether a load runs, for the spinner
        public var isLoading: Bool
        /// the problem's text, which shows as the red marker and the tooltip; `nil` without a problem (MR-05)
        public var problem: String?

        /// the tooltip: the problem, else the section
        public var help: String {
            problem ?? "Opens \(title) in the main window"
        }
    }

    /// The footer's rows that depend on the state (APP-06). It has no update row: the update is offered in the main
    /// window only (APP-05).
    public struct Footer: Hashable, Sendable {
        /// "Show 3 Hidden Builds" (HIDE-01)
        public var showHidden: String?
        /// whether a check runs: a spinner replaces the time
        public var isChecking: Bool
        /// "Last checked 10:42"
        public var lastChecked: String?
    }
}

extension PanelModel {
    /// The no-GitLab-token texts of MR-04.
    public enum SetupText {
        public static let needsToken = Problem.noToken(.gitLab).message
        public static let createToken = "1. Create the token in GitLab"
        public static let pasteToken = "2. Paste it in Settings → Accounts"
        public static let checkNow = "3. Check now"
        public static let workItemsNote = "Needs the GitLab token, see Merge Requests"
        /// what a summary row says without a token
        public static let summaryNeedsToken = "Needs a token"
    }

    /// Returns what the panel shows.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - query: the search text; empty shows everything
    public init(_ data: PanelData, query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        let jenkins = data.jenkins
        let offline = jenkins.problem == .offline
        let teamMissing = jenkins.problem == .teamValuesMissing
        footer = Self.footer(data)

        problems = jenkins.problemItem.map { [$0] } ?? []
        // TEAM-03: the team row alone; nothing can be asked without the values.
        guard !teamMissing else {
            myBuilds = nil
            watching = []
            allBuilds = nil
            mergeRequests = nil
            workItems = nil
            return
        }

        let jobURL = data.team.jenkinsJob
        let row = { (build: Build) in
            jenkins.row(build, now: data.now, jobURL: jobURL)
        }
        let mine = jenkins.mine.map(row).filter { Self.matches(query, $0.searchText) }
        watching = jenkins.watched.map(row).filter { Self.matches(query, $0.searchText) }
        if !jenkins.hasLoaded && jenkins.problem == nil {
            myBuilds = query.isEmpty ? BuildsSection(rows: [], note: nil, isPlaceholder: true) : nil
        } else if !mine.isEmpty {
            myBuilds = BuildsSection(rows: mine, note: nil, isPlaceholder: false)
        } else if query.isEmpty, let empty = jenkins.emptyState {
            myBuilds = BuildsSection(rows: [], note: empty.message, isPlaceholder: false)
        } else {
            // A problem without a cached job list shows the row alone (JERR-05), and a search hides the section.
            myBuilds = nil
        }
        allBuilds = query.isEmpty ? jobURL : nil

        // The summaries sit below the builds; a search is over builds only.
        mergeRequests = query.isEmpty ? Self.mergeRequests(data, offline: offline) : nil
        workItems = query.isEmpty ? Self.workItems(data, offline: offline) : nil
    }

    /// Returns the problem row of a problem, linked to the pane that fixes it.
    static func problemItem(_ problem: Problem) -> ProblemItem {
        ProblemItem(text: problem.message, pane: SettingsPane.pane(for: problem))
    }

    /// Returns whether a row's words contain the search text, ignoring case.
    static func matches(_ query: String, _ words: [String]) -> Bool {
        query.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func footer(_ data: PanelData) -> Footer {
        Footer(
            showHidden: PipelinesStore.showHiddenTitle(count: data.jenkins.hiddenCount), isChecking: data.jenkins.isChecking,
            lastChecked: data.jenkins.lastCheckedAt.map { Formatting.lastChecked($0) })
    }

    /// Returns the Merge Requests summary. Offline shows the cached counts without a problem or a spinner, since nothing
    /// loads (OD-05).
    private static func mergeRequests(_ data: PanelData, offline: Bool) -> Summary {
        let state = data.mergeRequests
        let needsToken = state.problem == .noToken(.gitLab)
        let problem = offline || needsToken ? nil : state.problem
        var text: String?
        if needsToken {
            text = SetupText.summaryNeedsToken
        } else if let list = state.list {
            let sections = MergeRequestSections(list.mergeRequests, me: list.username)
            text = sections.header.range(of: " · ").map { String(sections.header[$0.upperBound...]) } ?? "None open"
        }
        return Summary(
            section: .mergeRequests, title: "Merge Requests", text: text, isCommitted: false, tint: nil,
            isLoading: state.isLoading && !offline, problem: problem.map { problemItem($0).text })
    }

    /// Returns the Work Items summary: "N committed" when committed items exist, so the pill can stand out, otherwise
    /// the shown count.
    private static func workItems(_ data: PanelData, offline: Bool) -> Summary {
        let state = data.workItems
        let team = data.team
        let needsToken = state.problem == .noToken(.gitLab)
        let problem = offline || needsToken ? nil : state.problem
        var text: String?
        var isCommitted = false
        if needsToken {
            text = SetupText.summaryNeedsToken
        } else if let lists = state.lists {
            let sections = WorkItemSections(lists, committedLabel: team.committedLabel)
            if let gap = sections.header.range(of: " · ") {
                text = String(sections.header[gap.upperBound...])
                isCommitted = true
            } else if sections.isEmpty {
                text = "None match"
            } else {
                let count = lists.others?.count ?? 0
                let shown = lists.others?.items.count ?? 0
                text = (count > shown ? "\(shown) of \(count)" : "\(count)") + (count == 1 ? " item" : " items")
            }
        }
        // A missing filter label is a problem too (WI-06); the main window marks it the same way.
        var marker = problem.map { problemItem($0).text }
        if marker == nil, !offline, !needsToken, let label = state.missingLabels.first {
            marker = "Filter label \(label) is not in GitLab any more"
        }
        return Summary(
            section: .workItems, title: "Work Items", text: text, isCommitted: isCommitted,
            tint: isCommitted ? committedColor(state, committedLabel: team.committedLabel, slotPrefix: team.slotLabelPrefix) : nil,
            isLoading: state.isLoading && !offline, problem: marker)
    }

    /// Returns the GitLab color of the commitment: the committed label's, else the first committed item's slot label's.
    static func committedColor(_ state: PanelData.WorkItems, committedLabel: String, slotPrefix: String) -> String? {
        let items = state.lists?.committed?.items ?? []
        if let color = items.lazy.flatMap(\.labels).first(where: { $0.title == committedLabel && $0.color != nil })?.color
            ?? state.labelColors[committedLabel] {
            return color
        }
        guard !slotPrefix.isEmpty else {
            return nil
        }
        return items.lazy.flatMap(\.labels).first { $0.title.hasPrefix(slotPrefix) && $0.color != nil }?.color
    }
}

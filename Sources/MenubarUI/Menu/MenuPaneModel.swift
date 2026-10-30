import Foundation
import MenubarCore

/// What the menubar pane shows of a ``PanelData`` (APP-06, `docs/design/panel.md`): a problem row only while there is
/// one, then one overview row per area (Pipelines, Merge Requests, Work Items) that opens its flyout, then the footer.
/// Pure, so the tests and the gallery get the same answers as the pane.
struct MenuPaneModel: Sendable {
    /// the red row on top: Jenkins, the team values or offline; `nil` without a problem
    var problem: PanelModel.ProblemItem?
    /// the three areas in the sidebar's order; none while the team values are missing (TEAM-03)
    var areas: [MenuArea]
    var footer: Footer
    /// whether the easter eggs are on, for Option's Quit title (EGG-10)
    var easterEggs = false

    /// The footer's rows that depend on the state: Check Now's second line (APP-06, PIPE-07).
    struct Footer: Hashable, Sendable {
        /// whether a check runs: "Checking…" replaces the time
        var isChecking: Bool
        /// "Last checked 10:42"; `nil` before the first check
        var lastChecked: String?
        /// the easter egg line that replaces the time for 5 s while Check Now is mashed (EGG-09)
        var eggLine: String?

        /// Check Now's grey second line
        var subtitle: String? {
            isChecking ? "Checking…" : eggLine ?? lastChecked
        }
    }

    /// Returns what the pane shows.
    ///
    /// - Parameter data: the stores' values
    init(_ data: PanelData) {
        let jenkins = data.jenkins
        problem = jenkins.problemItem
        footer = Footer(isChecking: jenkins.isChecking, lastChecked: jenkins.lastCheckedAt.map { Formatting.lastChecked($0) })
        // TEAM-03: the team row alone; nothing can be asked without the values.
        guard jenkins.problem != .teamValuesMissing else {
            areas = []
            return
        }
        let offline = jenkins.problem == .offline
        areas = [Self.pipelines(data), Self.mergeRequests(data, offline: offline), Self.workItems(data, offline: offline)]
    }

    /// Returns the area of a section.
    func area(_ section: MainWindowSection) -> MenuArea? {
        areas.first { $0.section == section }
    }

    // MARK: - The summaries

    /// Pipelines: the builds that show by state, with the symbols and colors of the status icon, then the watched
    /// ones: "1 running · 2 failed · 1 watched". Its count is every build that shows, mine and watched. The Jenkins
    /// problem is the row on top, so the area has no marker of its own.
    static func pipelines(_ data: PanelData) -> MenuArea {
        let jenkins = data.jenkins
        var area = MenuArea(section: .pipelines)
        guard jenkins.hasLoaded || jenkins.problem != nil else {
            // Before the first check (OD-01).
            area.summary = [.note("Checking Jenkins…")]
            area.isLoading = true
            return area
        }
        let builds = jenkins.mine + jenkins.watched
        guard !builds.isEmpty else {
            // PIPE-06 in a few words; a problem without a cached job list has nothing to count (JERR-05).
            area.summary = [.note(jenkins.hasLoaded ? emptyText(jenkins.emptyState) : "Not checked yet")]
            return area
        }
        let states = builds.map(BuildState.init)
        let counted: [(BuildState, String)] = [
            (.running, "running"), (.failed, "failed"), (.unstable, "unstable"), (.successful, "passed"),
        ]
        for (state, word) in counted {
            let count = states.count { $0 == state }
            if count > 0 {
                area.summary.append(.count(symbol: state.symbol, tint: .build(state), text: "\(count) \(word)"))
            }
        }
        let others = states.count { ![.running, .failed, .unstable, .successful].contains($0) }
        if others > 0 {
            area.summary.append(.count(symbol: nil, tint: nil, text: "\(others) other"))
        }
        if !jenkins.watched.isEmpty {
            area.summary.append(.count(symbol: nil, tint: nil, text: "\(jenkins.watched.count) watched"))
        }
        area.count = builds.count
        return area
    }

    /// Returns PIPE-06's text short enough for a summary line: "No builds by jdoe", "No builds to show".
    static func emptyText(_ state: PipelinesEmptyState?) -> String {
        switch state {
        case .noJobs(let user)?: "No builds by \(user)"
        case .noBuilds?, nil: PipelinesEmptyState.noBuilds.message
        }
    }

    /// The MR-02 states that ask something of the author: a failed pipeline, conflicts, a rebase, requested changes.
    static let blockedKinds: Set<MergeRequestStatus.Kind> = [.pipelineFailed, .conflicts, .needsRebase, .changesRequested]

    /// Merge Requests: what asks something of me, in MR-02's colors: "1 to review · 1 ready to merge · 1 blocked";
    /// "2 open" when nothing does. Its count is every open MR the window lists.
    static func mergeRequests(_ data: PanelData, offline: Bool) -> MenuArea {
        let state = data.mergeRequests
        var area = MenuArea(section: .mergeRequests)
        let needsToken = state.problem == .noToken(.gitLab)
        area.isLoading = state.isLoading && !offline && !needsToken
        area.problem = offline || needsToken ? nil : state.problem.map { PanelModel.problemItem($0).text }
        if needsToken {
            area.summary = [.note(PanelModel.SetupText.summaryNeedsToken)]
            return area
        }
        guard let list = state.list else {
            area.summary = [.note(area.problem == nil ? "Loading…" : "Not loaded")]
            return area
        }
        let sections = MergeRequestSections(list.mergeRequests, me: list.username)
        let all = sections.yours + sections.reviewRequested + sections.reviewed
        guard !all.isEmpty else {
            area.summary = [.note("None open")]
            return area
        }
        let kinds = sections.yours.map { MergeRequestStatus.of($0).kind }
        let ready = kinds.count { $0 == .readyToMerge }
        let blocked = kinds.count { blockedKinds.contains($0) }
        if !sections.reviewRequested.isEmpty {
            area.summary.append(.count(
                symbol: "eye.circle.fill", tint: .gitLab(.orange), text: "\(sections.reviewRequested.count) to review"))
        }
        if ready > 0 {
            area.summary.append(.count(symbol: "checkmark.circle.fill", tint: .gitLab(.green), text: "\(ready) ready to merge"))
        }
        if blocked > 0 {
            area.summary.append(.count(symbol: "xmark.circle.fill", tint: .gitLab(.red), text: "\(blocked) blocked"))
        }
        if area.summary.isEmpty {
            area.summary = [.count(symbol: nil, tint: nil, text: "\(all.count) open")]
        }
        area.count = all.count
        return area
    }

    /// Work Items: the commitment first, the slot's value as its pill with its next date and "2 committed", then the rest:
    /// "2026.45 Code freeze in 3 days · 2 committed · 20 open".
    /// Its count is the committed items, or every item without a committed label (WIN-01's badge).
    static func workItems(_ data: PanelData, offline: Bool) -> MenuArea {
        let state = data.workItems
        let team = data.team
        var area = MenuArea(section: .workItems)
        let needsToken = state.problem == .noToken(.gitLab)
        area.isLoading = state.isLoading && !offline && !needsToken
        var marker = offline || needsToken ? nil : state.problem.map { PanelModel.problemItem($0).text }
        // A missing filter label is a problem too (WI-06); the main window marks it the same way.
        if marker == nil, !offline, !needsToken, let label = state.missingLabels.first {
            marker = "Filter label \(label) is not in GitLab any more"
        }
        area.problem = marker
        if needsToken {
            area.summary = [.note(PanelModel.SetupText.summaryNeedsToken)]
            return area
        }
        guard let lists = state.lists else {
            area.summary = [.note(marker == nil ? "Loading…" : "Not loaded")]
            return area
        }
        let others = lists.others?.count ?? 0
        let rest = state.filters.state == .opened ? "open" : (team.committedLabel.isEmpty ? "items" : "not committed")
        if team.committedLabel.isEmpty {
            area.summary = others == 0 ? [.note("None match")] : [.count(symbol: nil, tint: nil, text: "\(others) \(rest)")]
            area.count = others > 0 ? others : nil
            return area
        }
        let committed = lists.committed?.count ?? 0
        if committed > 0 {
            if let slot = slot(of: lists.committed?.items ?? [], prefix: team.slotLabelPrefix, colors: state.labelColors) {
                area.summary.append(.pill(slot))
                if let countdown = countdown(of: slot, team: team, now: data.now) {
                    area.summary.append(.note(countdown))
                }
            }
            area.summary.append(.count(symbol: nil, tint: nil, text: "\(committed) committed"))
        }
        if others > 0 {
            area.summary.append(.count(symbol: nil, tint: nil, text: "\(others) \(rest)"))
        }
        if area.summary.isEmpty {
            area.summary = [.note("None match")]
        }
        area.count = committed > 0 ? committed : nil
        return area
    }

    /// Returns the next date of the committed slot, the Slots section's countdown: "Code freeze in 3 days".
    ///
    /// - Returns: the text; `nil` when the label isn't a slot name with dates
    static func countdown(of slot: LabelPillModel, team: TeamValues, now: Date, calendar: Calendar = .current) -> String? {
        guard let name = SlotName(label: slot.title, prefix: team.slotLabelPrefix),
            let dates = SlotRules(team: team).dates(of: name, calendar: calendar)
        else { return nil }
        return dates.countdown(from: now, calendar: calendar)
    }

    /// Returns the slot of the commitment: the slot label most committed items have, the first one on a tie (WI-04).
    ///
    /// - Parameters:
    ///   - items: the committed work items
    ///   - prefix: the slot label prefix from Team; empty means no slot
    ///   - colors: the remembered label colors, for a label that came without one
    /// - Returns: the slot label as a pill; `nil` when no item has a slot
    static func slot(of items: [WorkItem], prefix: String, colors: [String: String]) -> LabelPillModel? {
        let labels = items.compactMap { $0.slotLabel(prefix: prefix) }
        var counts: [String: Int] = [:]
        for label in labels {
            counts[label.title, default: 0] += 1
        }
        let most = counts.values.max() ?? 0
        return labels.first { counts[$0.title] == most }.map { LabelPillModel($0, colors: colors) }
    }
}

/// One area's overview row: the sidebar's symbol and title, a grey summary line in parts, the count on the right, and
/// a flyout with the area's list.
struct MenuArea: Hashable, Sendable, Identifiable {
    var section: MainWindowSection
    /// the grey line, in parts joined with " · "
    var summary: [MenuSummaryPart] = []
    /// the headline count on the right; `nil` shows none
    var count: Int?
    /// whether a load runs: a small spinner takes the count's place
    var isLoading = false
    /// the problem's text, which shows as the red marker and its tooltip; `nil` without one (MR-05)
    var problem: String?

    var id: MainWindowSection { section }

    /// "Pipelines", the sidebar item's title
    var title: String { section.title }

    /// the sidebar item's SF Symbol
    var symbol: String { section.systemImage }

    /// the summary as plain text, the pill as its value: what VoiceOver reads and the tests check
    var summaryText: String {
        summary.map(\.text).joined(separator: " · ")
    }
}

/// A part of an area's summary line.
enum MenuSummaryPart: Hashable, Sendable {
    /// a count, with a small symbol in its color: "1 running"
    case count(symbol: String?, tint: MenuTint?, text: String)
    /// a quiet note instead of counts: "Loading…", "Needs a token"
    case note(String)
    /// a label pill, the slot's value
    case pill(LabelPillModel)

    var text: String {
        switch self {
        case .count(_, _, let text), .note(let text): text
        case .pill(let label): label.shortTitle
        }
    }
}

/// A symbol's color in the pane and the flyouts: the build states' (`BuildState.color`), GitLab's (MR-02), or
/// `.secondary`.
enum MenuTint: Hashable, Sendable {
    case build(BuildState)
    case gitLab(MergeRequestStatus.Color)
    case secondary
}

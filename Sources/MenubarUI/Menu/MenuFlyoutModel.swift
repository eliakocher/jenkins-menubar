import Foundation
import MenubarCore

/// What an area's flyout lists, beside the pane (APP-06, `docs/design/panel.md`): one concept for all three areas.
/// The window's sections under their headers (My Builds and Watching; the MR-01 sections; Committed and Not
/// Committed), one rich row per entry, at most ``cap`` entries, then "Show All N in Window" or "Show in Window" and the
/// area's link. A note stands in for the entries when there are none, and placeholders before the first load (OD-01).
///
/// Built from the window's own row models (`BuildRowModel`, `MergeRequestRowModel`, `WorkItemRowModel`), so the pane
/// and the window tell the same story. Pure, so the tests and the gallery get the same answers as the flyout.
struct MenuFlyout: Sendable {
    /// the most entries a flyout lists; the rest is in the window
    static let cap = 20

    var area: MainWindowSection
    /// the sections that have entries after the cap, in the window's order
    var sections: [Section]
    /// a quiet text instead of entries: PIPE-06's, "No open merge requests", MR-04's; `nil` with entries
    var note: String?
    /// two placeholder rows: never loaded (OD-01)
    var isPlaceholder: Bool
    /// how many entries there are before the cap
    var total: Int
    /// the rows under the entries, in order: Pipelines' "Watch a Build…" and "Show 3 Hidden Builds", "Show in
    /// Window", the link
    var commands: [Command]

    /// A section of the flyout, like "Review Requested".
    struct Section: Hashable, Sendable, Identifiable {
        var title: String
        /// the count after the title, "3" or "20 of 45"
        var count: String
        var entries: [MenuEntry]

        var id: String { title }
    }

    /// A row under the entries.
    enum Command: Hashable, Sendable, Identifiable {
        /// "Show in Window", or "Show All N in Window" when the cap cut entries: the main window at the area
        case showInWindow(all: Int?)
        /// "Watch a Build…" (WATCH-01), Pipelines' own action, ⌘L also on the pane
        case watchBuild
        /// "Show 3 Hidden Builds" (HIDE-01)
        case showHidden(String)
        /// "All Builds in Jenkins", "All Merge Requests in GitLab": the area in the browser
        case link(String, URL)
        /// "Open Settings…" at a pane, which fixes the note (MR-04)
        case settings(SettingsPane)

        var title: String {
            switch self {
            case .showInWindow(let all?): "Show All \(all) in Window"
            case .showInWindow(nil): "Show in Window"
            case .watchBuild: "Watch a Build…"
            case .showHidden(let title), .link(let title, _): title
            case .settings: "Open Settings…"
            }
        }

        var id: String { title }
    }

    /// A row the keyboard and the pointer highlight, in their order: the entries, then the commands.
    enum Item: Hashable, Sendable {
        case entry(MenuEntry.ID)
        case command(Command)
    }

    /// the entries that show, in order
    var entries: [MenuEntry] {
        sections.flatMap(\.entries)
    }

    /// whether the entries keep a symbol column: only when one of them has a symbol, so a flyout of open work items
    /// without markers starts its text at the rows' edge
    var hasSymbolColumn: Bool {
        entries.contains { $0.symbol != nil }
    }

    /// the rows the keyboard moves over, in order
    var items: [Item] {
        entries.map { .entry($0.id) } + commands.map(Item.command)
    }

    /// Returns the flyout of an area.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - area: the area
    init(_ data: PanelData, area: MainWindowSection) {
        self.area = area
        sections = []
        note = nil
        isPlaceholder = false
        total = 0
        commands = []
        guard data.jenkins.problem != .teamValuesMissing else {
            return
        }
        // The window's other sections have no flyout.
        if area == .pipelines {
            fillPipelines(data)
        } else if area == .mergeRequests {
            fillMergeRequests(data)
        } else if area == .workItems {
            fillWorkItems(data)
        }
    }

    /// My Builds and Watching, the hidden builds, the window and Jenkins (PIPE-02, WATCH-04, HIDE-01).
    private mutating func fillPipelines(_ data: PanelData) {
        let list = PipelinesListModel(PipelinesData(panel: data))
        let section = { (title: String, rows: [BuildRowModel]) in
            Section(title: title, count: String(rows.count), entries: rows.map { MenuEntry(build: $0, now: data.now) })
        }
        var all: [Section] = []
        switch list.myBuilds {
        case .rows(let rows)?:
            all.append(section("My Builds", rows))
        case .placeholder?:
            isPlaceholder = true
        case .note(let text)?:
            note = text
        case nil:
            break
        }
        let watched: [BuildRowModel] = list.watching.compactMap {
            if case .build(let row) = $0 { row } else { nil }
        }
        if !watched.isEmpty {
            all.append(section("Watching", watched))
        }
        if let empty = list.empty {
            note = empty.title
        } else if all.isEmpty, !isPlaceholder, note == nil, data.jenkins.problem != nil {
            // JERR-05: the problem row on the pane says why.
            note = "Nothing checked yet"
        }
        cap(all)
        // The user, 2026-10-29: Watch a Build… belongs to Pipelines, not the pane's footer.
        commands.append(.watchBuild)
        if let hidden = list.showHiddenTitle ?? list.empty?.showHiddenTitle {
            commands.append(.showHidden(hidden))
        }
        commands.append(.showInWindow(all: total > Self.cap ? total : nil))
        if let url = list.allBuilds ?? list.empty?.allBuilds {
            commands.append(.link("All Builds in Jenkins", url))
        }
    }

    /// The MR-01 sections, MR-04's setup, the window and GitLab.
    private mutating func fillMergeRequests(_ data: PanelData) {
        let list = MergeRequestsListModel(MergeRequestsData(data))
        if let setup = list.setup {
            note = PanelModel.SetupText.needsToken
            commands = [.settings(.accounts)]
            if let url = setup.newTokenURL {
                commands.append(.link("Create a Token in GitLab", url))
            }
            return
        }
        isPlaceholder = list.isPlaceholder
        if list.showsEmpty {
            note = MergeRequestSections.emptyText
        }
        cap(list.sections.map { section in
            Section(title: section.title, count: String(section.rows.count), entries: section.rows.map {
                MenuEntry(mergeRequest: $0, now: data.now)
            })
        })
        commands.append(.showInWindow(all: total > Self.cap ? total : nil))
        if let url = list.link ?? list.emptyLink {
            commands.append(.link("All Merge Requests in GitLab", url))
        }
    }

    /// Committed and Not Committed (WI-01), MR-04's note, the window and GitLab.
    private mutating func fillWorkItems(_ data: PanelData) {
        let workItems = WorkItemsData(data, labelColors: data.workItems.labelColors)
        let list = WorkItemsListModel(workItems)
        if list.tokenNote != nil {
            note = PanelModel.SetupText.needsToken
            commands = [.settings(.accounts)]
            return
        }
        isPlaceholder = list.isPlaceholder
        if list.empty != nil {
            note = WorkItemSections.emptyText
        }
        if let lists = workItems.lists {
            let sections = WorkItemSections(lists, committedLabel: workItems.team.committedLabel).sections
            let shared = WorkItemRowModel.sharedLabels(of: sections.flatMap(\.list.items))
            cap(sections.map { section in
                Section(title: section.kind.title, count: section.countText, entries: section.list.items.map {
                    MenuEntry(workItem: WorkItemRowModel($0, data: workItems, sharedLabels: shared), now: data.now)
                })
            })
        }
        commands.append(.showInWindow(all: total > Self.cap ? total : nil))
        if let url = list.link ?? list.empty?.link {
            commands.append(.link("All Work Items in GitLab", url))
        }
    }

    /// Keeps the first ``cap`` entries, section by section, and counts them all.
    private mutating func cap(_ all: [Section]) {
        total = all.reduce(0) { $0 + $1.entries.count }
        var room = Self.cap
        sections = all.compactMap { section in
            guard room > 0 else {
                return nil
            }
            var kept = section
            kept.entries = Array(section.entries.prefix(room))
            room -= kept.entries.count
            return kept
        }
    }

    /// Returns the entry with an id.
    func entry(_ id: MenuEntry.ID) -> MenuEntry? {
        entries.first { $0.id == id }
    }
}

/// Where "Show in Window" goes: the main window's section with the entry selected (WIN-05).
enum MenuSelection: Hashable, Sendable {
    /// a build, by its job (`MainWindowSelection.pipelines`)
    case build(job: String)
    case mergeRequest(MergeRequest.ID)
    case workItem(WorkItem.ID)

    /// the section that shows it
    var section: MainWindowSection {
        switch self {
        case .build: .pipelines
        case .mergeRequest: .mergeRequests
        case .workItem: .workItems
        }
    }
}

/// Where a click on a flyout entry goes (the user, 2026-10-30): into the main window, or with ⌥ to the browser.
enum MenuEntryDestination: Hashable, Sendable {
    /// the main window's section with the entry selected
    case window(MenuSelection)
    /// Jenkins or GitLab in the browser
    case browser(URL)
}

/// One entry of a flyout: the colored status symbol, the title (cut by width), the grey line that tells entries apart,
/// and for a running build its progress; a work item's slot as its pill before the grey line.
struct MenuEntry: Hashable, Sendable, Identifiable {
    /// What the entry stands for, with the window's row model, for its context menu.
    enum Kind: Hashable, Sendable {
        case build(BuildRowModel)
        case mergeRequest(MergeRequestRowModel)
        case workItem(WorkItemRowModel)
    }

    var kind: Kind
    var title: String
    /// the grey second line
    var subtitle: String
    /// `nil` leaves the column empty: an open work item without a related MR, which every such item would share
    var symbol: String?
    /// the symbol's color; `nil` for the label color
    var tint: MenuTint?
    /// a running build's progress (PIPE-02)
    var progress: BuildRowModel.Progress?
    /// a work item's slot, its value as a pill (WI-04)
    var pill: LabelPillModel?
    /// the page ⌥-click and "Open …" open: the build in Jenkins, the MR or the work item in GitLab; `nil` has none
    var url: URL?
    /// the context menu's first item, "Open Build #7", "Open Merge Request !21"
    var openTitle: String
    /// where "Show in Window" goes
    var selection: MenuSelection
    /// a rebuild that failed, after the red marker (PIPE-09)
    var problem: String?
    var id: String

    /// A build: the state's symbol and color, the title, and "!12 #7 · build, tests · 5m of ~25m" while it runs or
    /// "!16 #3 · failed: tests, deploy · 30m ago" once finished (PIPE-02, PIPE-03, WATCH-04).
    init(build row: BuildRowModel, now: Date) {
        kind = .build(row)
        title = row.title
        subtitle = Self.subtitle(of: row, now: now)
        symbol = row.state.symbol
        tint = row.state.color == nil ? nil : .build(row.state)
        progress = row.rebuild == nil ? row.progress : nil
        pill = nil
        url = row.buildPage?.url
        openTitle = row.buildPage?.title ?? "Open Build #\(row.build.number)"
        selection = .build(job: row.build.jobKey)
        problem = row.rebuild?.failure
        id = "build:\(row.build.id)"
    }

    /// A merge request: MR-02's badge symbol in GitLab's color, the title, and "!12 · Pipeline failed · 1 of 2
    /// approved · 2h ago" (MR-03). The section's header says "Review Requested", so the line leaves it out.
    init(mergeRequest row: MergeRequestRowModel, now: Date) {
        let mergeRequest = row.mergeRequest
        kind = .mergeRequest(row)
        title = mergeRequest.title
        subtitle = Self.subtitle(of: row, now: now)
        symbol = row.status.symbol
        tint = .gitLab(row.status.color)
        progress = nil
        pill = nil
        url = mergeRequest.webURL
        openTitle = row.openTitle
        selection = .mergeRequest(mergeRequest.id)
        problem = nil
        id = "mr:\(mergeRequest.id.absoluteString)"
    }

    /// A work item: its related-MR marker, a check when closed, else none; the title; the slot's value as a pill, then "#31 · Task ·
    /// design · 3d ago" (WI-04, WI-05), its age as the MRs' (MR-03).
    init(workItem row: WorkItemRowModel, now: Date) {
        let item = row.workItem
        kind = .workItem(row)
        title = item.displayTitle
        let age = "\(GitLabText.age(since: item.updatedAt, now: now)) ago"
        subtitle = ([row.reference] + [row.secondLine].compactMap { $0 } + [age]).joined(separator: " · ")
        switch row.marker {
        case .open?:
            symbol = WorkItemRowStyle.symbol(of: .open)
            tint = .gitLab(.blue)
        case .merged?:
            symbol = WorkItemRowStyle.symbol(of: .merged)
            tint = .gitLab(.green)
        case nil:
            // Open is what every listed item is: no marker (the user, 2026-10-29). Closed still says something.
            symbol = item.state == .closed ? "checkmark.circle" : nil
            tint = .secondary
        }
        progress = nil
        pill = row.slotLabel
        url = item.webURL
        openTitle = row.openTitle
        selection = .workItem(item.id)
        problem = nil
        id = "wi:\(item.id)"
    }

    /// Returns where a click or Return on the entry goes: the app's own window, or with ⌥ the page in the browser.
    /// An entry without a page has no browser to go to, so ⌥ shows it in the window too.
    ///
    /// - Parameter option: whether ⌥ is held
    func destination(option: Bool) -> MenuEntryDestination {
        if option, let url {
            return .browser(url)
        }
        return .window(selection)
    }

    /// Returns a build's grey line: the reference (with "by Sam Lee" for a watched build), then while it runs the
    /// running stages and the time against the estimate, once finished what went wrong and how long ago. A rebuild
    /// says so instead of the time (PIPE-09).
    static func subtitle(of row: BuildRowModel, now: Date) -> String {
        let build = row.build
        var parts = [row.reference]
        if build.isRunning {
            if !build.runningStages.isEmpty {
                parts.append(build.runningStages.joined(separator: ", "))
            }
            parts.append(runningTime(build, now: now))
        } else {
            if let failed = build.failedStages, !failed.isEmpty, row.state != .successful {
                parts.append("failed: " + failed.joined(separator: ", "))
            } else if let tests = Formatting.failedTests(build.testCounts) {
                parts.append(tests)
            } else if case .aborted = row.state {
                parts.append("aborted")
            } else if case .other(let result) = row.state {
                parts.append(result.lowercased().replacingOccurrences(of: "_", with: " "))
            }
            parts.append("\(Formatting.age(since: build.finishedAt ?? now, now: now)) ago")
        }
        if let rebuild = row.rebuild, rebuild.failure == nil {
            parts.append(rebuild.text)
        }
        return parts.joined(separator: " · ")
    }

    /// "5m of ~25m" against Jenkins' estimate, "5m elapsed" without one (PIPE-02).
    static func runningTime(_ build: Build, now: Date) -> String {
        let elapsed = short(build.elapsed(at: now))
        guard let estimate = build.estimatedDuration, estimate > 0 else {
            return "\(elapsed) elapsed"
        }
        return "\(elapsed) of ~\(short(estimate))"
    }

    /// A duration in whole minutes, "5m", or hours and minutes from an hour on, "1h05m".
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        guard minutes >= 60 else {
            return "\(minutes)m"
        }
        let rest = minutes % 60
        return "\(minutes / 60)h" + (rest < 10 ? "0" : "") + "\(rest)m"
    }

    /// Returns an MR's grey line: its short reference, its status without "Review requested", the author when it isn't
    /// me, the approvals when the status doesn't say them, and its age.
    static func subtitle(of row: MergeRequestRowModel, now: Date) -> String {
        let mergeRequest = row.mergeRequest
        let status = MergeRequestStatus.of(mergeRequest)
        var parts = [row.shortReference, status.text]
        let reviewers = mergeRequest.reviewers
        if !reviewers.isEmpty, ![.notApproved, .readyToMerge].contains(status.kind) {
            parts.append("\(reviewers.count { $0.approved }) of \(reviewers.count) approved")
        }
        if !row.isMine, !mergeRequest.author.name.isEmpty {
            parts.append("by \(mergeRequest.author.name)")
        }
        parts.append("\(GitLabText.age(since: mergeRequest.updatedAt, now: now)) ago")
        return parts.joined(separator: " · ")
    }
}

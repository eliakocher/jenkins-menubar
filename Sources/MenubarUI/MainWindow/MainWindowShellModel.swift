import Foundation
import MenubarCore

/// What the main window's shell shows of the stores (`docs/design/main-window.md`): the sidebar's counts and problem
/// markers, the subtitle, whether a check or a load runs, and where the update stands. Pure, so the gallery and the
/// tests get the same answers as the window.
public struct MainWindowShellModel: Hashable, Sendable {
    /// each section's count, exact; a section at 0 has none (WIN-01)
    public var badges: [MainWindowSection: Int]
    /// the sections with a problem of their own, with the marker's tooltip, "Jenkins problem" or "GitLab problem"
    public var markers: [MainWindowSection: String]
    /// "Last checked 10:42" for what the shown section shows; `nil` before the first check or load
    public var subtitle: String?
    /// whether a check, or a GitLab load of the shown section, runs: a spinner takes Check Now's place (JERR-07)
    public var isBusy: Bool
    /// where the app's update stands (APP-05), for the toolbar's update item
    public var update: UpdateState
    /// "Show 3 Hidden Builds" for the Builds menu; `nil` when nothing is hidden by hand (HIDE-01)
    public var showHiddenTitle: String?
    /// the work item filters, for the gallery's filter menu in the toolbar
    public var workItemFilters: WorkItemFilters

    /// Returns what the shell shows.
    ///
    /// - Parameters:
    ///   - data: the stores' values, as the panel takes them
    ///   - section: the shown section
    ///   - activitySubtitle: Activity's subtitle, "182 entries" or "12 of 182 entries" (LOG-04); `nil` for none
    ///   - workspacesSubtitle: Workspaces' subtitle, "4 checkouts · 2 free" (WS-01); `nil` for none
    ///   - workspacesBusy: whether git reads the checkouts
    public init(
        _ data: PanelData, section: MainWindowSection, activitySubtitle: String? = nil, workspacesSubtitle: String? = nil,
        workspacesBusy: Bool = false
    ) {
        update = data.update
        workItemFilters = data.workItems.filters
        showHiddenTitle = PipelinesStore.showHiddenTitle(count: data.jenkins.hiddenCount)
        let jenkins = data.jenkins
        let mergeRequests = data.mergeRequests
        let workItems = data.workItems
        isBusy = jenkins.isChecking
            || (section == .mergeRequests && mergeRequests.isLoading)
            || ((section == .workItems || section == .slots) && workItems.isLoading)
            || (section == .workspaces && workspacesBusy)
        // TEAM-03: the team row alone, without counts or times.
        guard jenkins.problem != .teamValuesMissing else {
            badges = [:]
            markers = [:]
            subtitle = nil
            return
        }

        let offline = jenkins.problem == .offline
        let mergeRequestsNeedToken = mergeRequests.problem == .noToken(.gitLab)
        let workItemsNeedToken = workItems.problem == .noToken(.gitLab)

        var badges: [MainWindowSection: Int] = [:]
        badges[.pipelines] = (jenkins.mine + jenkins.watched).count { $0.isRunning }
        if let list = mergeRequests.list, !mergeRequestsNeedToken {
            badges[.mergeRequests] = MergeRequestSections(list.mergeRequests, me: list.username).reviewRequested.count
        }
        if let lists = workItems.lists, !workItemsNeedToken {
            // Without a committed label, every shown work item counts (WIN-01).
            let counted = data.team.committedLabel.isEmpty ? lists.others : lists.committed
            badges[.workItems] = counted?.items.count ?? 0
        }
        self.badges = badges.filter { $0.value > 0 }

        // Offline is an app-wide row: it marks no section (OD-05). A missing GitLab token is a setup step, not a
        // problem (MR-04).
        var markers: [MainWindowSection: String] = [:]
        if !offline {
            if jenkins.problem != nil {
                markers[.pipelines] = "Jenkins problem"
            }
            if mergeRequests.problem != nil, !mergeRequestsNeedToken {
                markers[.mergeRequests] = "GitLab problem"
            }
            if (workItems.problem != nil && !workItemsNeedToken) || (!workItemsNeedToken && !workItems.missingLabels.isEmpty) {
                markers[.workItems] = "GitLab problem"
            }
        }
        self.markers = markers

        switch section {
        case .pipelines:
            subtitle = jenkins.lastCheckedAt.map { Formatting.lastChecked($0) }
        case .mergeRequests:
            subtitle = mergeRequestsNeedToken ? nil : mergeRequests.lastLoadAt.map { Formatting.lastChecked($0) }
        case .workItems:
            subtitle = workItemsNeedToken ? nil : workItems.lastLoadAt.map { Formatting.lastChecked($0) }
        case .activity:
            subtitle = activitySubtitle
        case .workspaces:
            subtitle = workspacesSubtitle
        case .slots:
            subtitle = workItemsNeedToken ? nil : workItems.lastLoadAt.map { Formatting.lastChecked($0) }
        }
    }

    /// whether the toolbar's update item shows: "Update Ready — Rebuild", "Rebuilding…", or "Relaunching…" once the new
    /// app is installed (APP-05, `update-row.md`)
    public var showsUpdateItem: Bool {
        switch update {
        case .updateReady, .rebuilding, .failed, .installed: true
        case .upToDate: false
        }
    }
}

/// The GitLab surfaces the main window shows, for `Scheduler.setVisible(_:)` (OD-02, WIN-02).
public enum MainWindowSurfaces {
    /// the name the window reports its surfaces under
    public static let host = "main-window"

    /// Returns the surfaces the open window shows: the selected section's, and while the window is on screen (not
    /// minimized or covered) Merge Requests and Work Items too, whose sidebar badges keep loading (the user's decision,
    /// 2026-10-29).
    ///
    /// - Parameters:
    ///   - section: the selected section
    ///   - isOnScreen: whether some of the window can be seen
    /// - Returns: the surfaces
    public static func shown(section: MainWindowSection, isOnScreen: Bool) -> Set<Surface> {
        if isOnScreen {
            return [.mergeRequests, .workItems]
        }
        switch section {
        case .mergeRequests: return [.mergeRequests]
        case .workItems: return [.workItems]
        // A workspace's row shows its merge request and work item (WS-04).
        case .workspaces: return [.mergeRequests, .workItems]
        // The slots join the work items with their merge requests and builds (SLOT-03).
        case .slots: return [.mergeRequests, .workItems]
        case .pipelines, .activity: return []
        }
    }
}

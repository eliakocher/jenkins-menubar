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
    /// the sections with something new to look at, which the sidebar marks with a small accent dot: Digest while a digest
    /// was written that it hasn't shown yet
    public var unread: Set<MainWindowSection>
    /// the sections that wear the gift: Inbox while the update's "What's New" waits, unopened
    public var gifts: Set<MainWindowSection>
    /// "Last checked 10:42" for what the shown section shows; `nil` before the first check or load
    public var subtitle: String?
    /// whether a check or load of the shown section runs: a spinner takes Reload's place (JERR-07)
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
    ///   - slotsBusy: whether the slot labels or the slot items load
    ///   - digestSubtitle: Digest's subtitle, "Written Mon 10:42"; `nil` for none
    ///   - digestBusy: whether Claude writes the digest
    ///   - digestUnread: whether a digest was written that the Digest section hasn't shown yet
    ///   - inbox: what the Inbox adds: its badge, its problem and its subtitle (Task 7.03)
    public init(
        _ data: PanelData, section: MainWindowSection, activitySubtitle: String? = nil, workspacesSubtitle: String? = nil,
        workspacesBusy: Bool = false, slotsBusy: Bool = false, digestSubtitle: String? = nil, digestBusy: Bool = false,
        digestUnread: Bool = false, inbox: InboxShell = InboxShell()
    ) {
        unread = digestUnread ? [.digest] : []
        gifts = inbox.hasUnreadWhatsNew ? [.inbox] : []
        update = data.update
        workItemFilters = data.workItems.filters
        showHiddenTitle = PipelinesStore.showHiddenTitle(count: data.jenkins.hiddenCount)
        let jenkins = data.jenkins
        let mergeRequests = data.mergeRequests
        let workItems = data.workItems
        // Reload loads the shown section only, so only its work shows (the user, 2026-10-30).
        isBusy = (section == .pipelines && jenkins.isChecking)
            || (section == .mergeRequests && mergeRequests.isLoading)
            || (section == .workItems && workItems.isLoading)
            || (section == .slots && (workItems.isLoading || slotsBusy))
            || (section == .workspaces && workspacesBusy)
            || (section == .digest && digestBusy)
            || (section == .inbox && inbox.isBusy)
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
        badges[.inbox] = inbox.badge
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
            if let problem = inbox.problem, problem != .noToken(.gitLab) {
                markers[.inbox] = "GitLab problem"
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
            // Short, like the others: the filters moved into the list's own bar (WIN-04), since a long subtitle ran over
            // the list column's edge (the user, 2026-11-02).
            subtitle = workItemsNeedToken
                ? nil
                : Self.workItemsSubtitle(
                    count: workItems.lists.map {
                        WorkItemSections($0, committedLabel: data.team.committedLabel).sections.reduce(0) { $0 + $1.list.items.count }
                    },
                    lastLoadAt: workItems.lastLoadAt)
        case .activity:
            subtitle = activitySubtitle
        case .workspaces:
            subtitle = workspacesSubtitle
        case .slots:
            subtitle = workItemsNeedToken ? nil : workItems.lastLoadAt.map { Formatting.lastChecked($0) }
        case .digest:
            subtitle = digestSubtitle
        case .inbox:
            subtitle = inbox.subtitle
        }
    }

    /// Returns the Work Items subtitle: how many items show and the check time, "12 items · checked 14:29". The filters
    /// are the list's own bar, not the title: a long subtitle ran over the list column's edge (WIN-04).
    ///
    /// - Parameters:
    ///   - count: how many work items the list shows; `nil` before the first load
    ///   - lastLoadAt: when the last load ended; `nil` before the first
    /// - Returns: the text, empty before anything is known
    static func workItemsSubtitle(count: Int?, lastLoadAt: Date?) -> String {
        var parts: [String] = []
        if let count {
            parts.append(count == 1 ? "1 item" : "\(count) items")
        }
        if let lastLoadAt {
            parts.append(Formatting.lastChecked(lastLoadAt).replacing("Last checked", with: "checked"))
        }
        return parts.joined(separator: " · ")
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

/// What the Inbox adds to the main window's shell, from the store: the sidebar's badge, the problem that marks the row,
/// the subtitle and whether a load runs. The window reads only these, never the rows, so a change of the to-dos draws
/// the Inbox list and the badge, not the window.
public struct InboxShell: Hashable, Sendable {
    /// the sidebar's count (`InboxStore.badgeCount`)
    public var badge: Int
    /// the problem of the last load; the missing token is no problem but a setup step (MR-04)
    public var problem: Problem?
    /// "Checked 14:29", for the shown Inbox
    public var subtitle: String?
    /// whether a load runs
    public var isBusy: Bool
    /// whether the update's "What's New" waits unopened: the row wears the gift
    public var hasUnreadWhatsNew: Bool

    public init(
        badge: Int = 0, problem: Problem? = nil, subtitle: String? = nil, isBusy: Bool = false, hasUnreadWhatsNew: Bool = false
    ) {
        self.hasUnreadWhatsNew = hasUnreadWhatsNew
        self.badge = badge
        self.problem = problem
        self.subtitle = subtitle
        self.isBusy = isBusy
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
        case .pipelines, .activity, .digest, .inbox: return []
        }
    }
}

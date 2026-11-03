import Foundation
import MenubarCore

/// The main window's sections are the sidebar's items, named as in their `megamonitor://open/<section>` links
/// (`docs/design/main-window.md`, WIN-01).
public typealias MainWindowSection = AppRoute.Section

extension AppRoute.Section {
    /// "Pipelines": the sidebar item, the window's title and the View menu's item
    public var title: String {
        switch self {
        case .pipelines: "Pipelines"
        case .inbox: "Inbox"
        case .mergeRequests: "Merge Requests"
        case .workItems: "Work Items"
        case .activity: "Activity"
        case .workspaces: "Workspaces"
        case .slots: "Slots"
        case .digest: "Digest"
        }
    }

    /// the sidebar item's SF Symbol
    public var systemImage: String {
        switch self {
        case .pipelines: "hammer"
        case .inbox: "tray"
        case .mergeRequests: "arrow.triangle.pull"
        case .workItems: "checklist"
        case .activity: "clock.arrow.circlepath"
        case .workspaces: "arrow.triangle.branch"
        case .slots: "calendar.badge.clock"
        case .digest: "sparkles.rectangle.stack"
        }
    }

    /// Returns the sections the sidebar lists, in the order of ⌘1 and on (the user's, else the default): all of them, but Digest only while the Claude
    /// features are on (AI-04). The shown section stays listed, so the sidebar never selects an item it doesn't have:
    /// a link or a restart can land on Digest while Claude is off or `claude` isn't found yet.
    ///
    /// - Parameters:
    ///   - claudeIsOffered: whether the Claude features are on and `claude` is installed
    ///   - shown: the section the window shows
    ///   - order: the user's order of the sections, as the preference ``SectionOrder/key`` keeps it; empty is the default.
    ///     A hidden section keeps its place in it, and ⌘1 and on follow what the sidebar lists.
    /// - Returns: the sections
    public static func sidebarSections(
        claudeIsOffered: Bool, shown: MainWindowSection, order: String = ""
    ) -> [MainWindowSection] {
        SectionOrder.merged(stored: order).filter { $0 != .digest || claudeIsOffered || shown == .digest }
    }

    /// whether the toolbar's section group has items here, besides the shell's Open in and Reload: Watch a Build in
    /// Pipelines, the filter menu in Work Items, Finder, Clear and the inspector in Activity, Slots Settings in Slots
    public var hasToolbarItems: Bool {
        switch self {
        case .pipelines, .workItems, .activity, .slots: true
        case .inbox, .mergeRequests, .workspaces, .digest: false
        }
    }

    /// whether the section's list uses the whole window, with no detail column: Activity, Slots, Digest and the Inbox, whose
    /// rows open their target under "Opened" or in its own section
    public var isFullWidth: Bool {
        switch self {
        case .activity, .slots, .digest, .inbox: true
        case .pipelines, .mergeRequests, .workItems, .workspaces: false
        }
    }

    /// whether the search field is there: every section has it, Digest too (it marks the matches in the digest), so the
    /// toolbar's items never move when the section changes (the user, 2026-11-02)
    public var isSearchable: Bool {
        true
    }

    /// the search field's prompt, which names what it searches (WIN-03)
    public var searchPrompt: String {
        switch self {
        case .pipelines: "Search builds"
        case .inbox: "Search inbox"
        case .mergeRequests: "Search merge requests"
        case .workItems: "Search work items"
        case .activity: "Search activity"
        case .workspaces: "Search workspaces"
        case .slots: "Search slots"
        case .digest: "Search digest"
        }
    }

    /// what the detail column says without a selection, like "No Build Selected"
    public var noSelectionTitle: String {
        switch self {
        case .pipelines: "No Build Selected"
        case .inbox: "No To-Do Selected"
        case .mergeRequests: "No Merge Request Selected"
        case .workItems: "No Work Item Selected"
        case .activity: "No Entry Selected"
        case .workspaces: "No Workspace Selected"
        case .slots: "No Slot Selected"
        case .digest: "No Digest Yet"
        }
    }
}

/// What each section of the main window has selected, by the rows' stable ids, so a selection survives checks and
/// loads (`docs/design/main-window.md`, "What the sections share"). Each section keeps its own: switching back finds it.
public struct MainWindowSelection: Hashable, Sendable {
    /// the selected job in Pipelines (`Build.job`, or `WatchedJob.job` for a WAITING one)
    public var pipelines: String?
    /// the selected merge request, by its web URL
    public var mergeRequests: MergeRequest.ID?
    /// the selected work item, by its full reference
    public var workItems: WorkItem.ID?
    /// the selected log entries; Activity is the one section with multiple selection
    public var activity: Set<ActivityItem.ID>
    /// the selected checkout, by its path (WS-01)
    public var workspaces: Checkout.ID?
    /// the selected work item in Slots, by its full reference; its detail is Work Items' (SLOT-09)
    public var slots: WorkItem.ID?

    public init(
        pipelines: String? = nil, mergeRequests: MergeRequest.ID? = nil, workItems: WorkItem.ID? = nil,
        activity: Set<ActivityItem.ID> = [], workspaces: Checkout.ID? = nil, slots: WorkItem.ID? = nil
    ) {
        self.pipelines = pipelines
        self.mergeRequests = mergeRequests
        self.workItems = workItems
        self.activity = activity
        self.workspaces = workspaces
        self.slots = slots
    }

    // MARK: - Kept in UserDefaults (WIN-05)

    /// the key of the main window's section
    static let sectionKey = "mainWindow.section"

    /// Returns the key of a section's selection, like `mainWindow.selection.work-items`.
    static func key(of section: MainWindowSection) -> String {
        "mainWindow.selection.\(section.rawValue)"
    }

    /// Reads the selections kept in UserDefaults.
    ///
    /// - Parameter defaults: the preferences' suite
    init(defaults: UserDefaults) {
        pipelines = defaults.string(forKey: Self.key(of: .pipelines))
        mergeRequests = defaults.string(forKey: Self.key(of: .mergeRequests)).flatMap { URL(string: $0) }
        workItems = defaults.string(forKey: Self.key(of: .workItems))
        activity = defaults.string(forKey: Self.key(of: .activity)).map { [$0] } ?? []
        workspaces = defaults.string(forKey: Self.key(of: .workspaces))
        slots = defaults.string(forKey: Self.key(of: .slots))
    }

    /// Keeps the selections in UserDefaults. Activity's is kept only while one entry is selected (`main-window.md`,
    /// Restored).
    ///
    /// - Parameter defaults: the preferences' suite
    func save(to defaults: UserDefaults) {
        let values: [(MainWindowSection, String?)] = [
            (.pipelines, pipelines),
            (.mergeRequests, mergeRequests?.absoluteString),
            (.workItems, workItems),
            (.activity, activity.count == 1 ? activity.first : nil),
            (.workspaces, workspaces),
            (.slots, slots),
        ]
        for (section, value) in values {
            if let value {
                defaults.set(value, forKey: Self.key(of: section))
            } else {
                defaults.removeObject(forKey: Self.key(of: section))
            }
        }
    }
}

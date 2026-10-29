import Foundation
import MenubarCore

/// The main window's sections are the sidebar's items, named as in their `menubar-monitor://open/<section>` links
/// (`docs/design/main-window.md`, WIN-01).
public typealias MainWindowSection = AppRoute.Section

extension AppRoute.Section {
    /// "Pipelines": the sidebar item, the window's title and the View menu's item
    public var title: String {
        switch self {
        case .pipelines: "Pipelines"
        case .mergeRequests: "Merge Requests"
        case .workItems: "Work Items"
        case .activity: "Activity"
        case .workspaces: "Workspaces"
        case .slots: "Slots"
        }
    }

    /// the sidebar item's SF Symbol
    public var systemImage: String {
        switch self {
        case .pipelines: "hammer"
        case .mergeRequests: "arrow.triangle.pull"
        case .workItems: "checklist"
        case .activity: "clock.arrow.circlepath"
        case .workspaces: "arrow.triangle.branch"
        case .slots: "calendar.badge.clock"
        }
    }

    /// the search field's prompt, which names what it searches (WIN-03)
    public var searchPrompt: String {
        switch self {
        case .pipelines: "Search builds"
        case .mergeRequests: "Search merge requests"
        case .workItems: "Search work items"
        case .activity: "Search activity"
        case .workspaces: "Search workspaces"
        case .slots: "Search slots"
        }
    }

    /// what the detail column says without a selection, like "No Build Selected"
    public var noSelectionTitle: String {
        switch self {
        case .pipelines: "No Build Selected"
        case .mergeRequests: "No Merge Request Selected"
        case .workItems: "No Work Item Selected"
        case .activity: "No Entry Selected"
        case .workspaces: "No Workspace Selected"
        case .slots: "No Slot Selected"
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

    public init(
        pipelines: String? = nil, mergeRequests: MergeRequest.ID? = nil, workItems: WorkItem.ID? = nil,
        activity: Set<ActivityItem.ID> = [], workspaces: Checkout.ID? = nil
    ) {
        self.pipelines = pipelines
        self.mergeRequests = mergeRequests
        self.workItems = workItems
        self.activity = activity
        self.workspaces = workspaces
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

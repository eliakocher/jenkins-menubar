import Foundation
import MenubarCore
import Observation

/// Where a view sends people outside itself: the main window, the Watch a Build… sheet on it, or Settings.
///
/// The views can't open windows themselves: the app hands them a ``WindowRouter`` whose closure opens them with the
/// activation helper of Task 0.11 (`docs/decisions.md`).
public enum WindowRoute: Hashable, Sendable {
    /// the main window
    case main
    /// the main window, then the Watch a Build… sheet on it, with the request's text and reason (Task 4.6)
    case watch(WatchRequest)
    /// Settings at a pane; `nil` keeps the pane Settings shows
    case settings(pane: SettingsPane?)
}

/// What the Watch a Build… sheet opens with: an empty field, or a link and why watching it was refused (APP-03, the
/// `watch-sheet` spec's decision Q2).
public struct WatchRequest: Hashable, Sendable, Identifiable {
    /// a new one for every request, so an open sheet notices a route that repeats the same text
    public var id: UUID
    /// the text for the field; `nil` leaves it empty
    public var text: String?
    /// why watching the text was refused, shown under the field; `nil` for none
    public var reason: String?
    /// the refusal itself, when known: the sheet then shows it as it would have after a Return, with "Open Settings…"
    /// for a token or the team values, and one of mine as a note rather than a problem
    public var refusal: WatchRefusal?
    /// the project the sheet starts with, as for an MR's builds; `nil` keeps the sheet's (plan Phase 13)
    public var project: ProjectID?

    public init(id: UUID = UUID(), text: String? = nil, reason: String? = nil) {
        self.id = id
        self.text = text
        self.reason = reason
    }

    /// A request for a refused text.
    ///
    /// - Parameters:
    ///   - text: the text that was refused
    ///   - refusal: why
    public init(id: UUID = UUID(), text: String, refusal: WatchRefusal) {
        self.id = id
        self.text = text
        self.reason = refusal.message
        self.refusal = refusal
    }

    /// whether the request carries a refusal, which replaces the text and the status of a sheet that is open already
    public var isRefusal: Bool { reason != nil || refusal != nil }
}

/// Opens the main window, the Watch a Build… sheet and Settings for the views, and holds the app-level state they
/// share across scenes.
///
/// The app builds one and puts it into every scene's environment with
/// ``SwiftUICore/View/appEnvironment(_:router:)``; the views read it with `@Environment(WindowRouter.self)`. Actions
/// in the panel call ``open(_:)`` and then `dismiss()`, because opening a window doesn't close the panel (Task 0.10).
@Observable
@MainActor
public final class WindowRouter {
    /// the app-level watch request: while it is set, the main window shows the Watch a Build… sheet, which clears it
    /// when it closes
    public var watchRequest: WatchRequest?

    /// the main window's section, the sidebar's selection (WIN-01); a route sets it before the window opens. Kept in
    /// UserDefaults, so it comes back when the window opens again and after a restart (WIN-05).
    public var section: MainWindowSection = .pipelines {
        didSet {
            if section != oldValue {
                defaults?.set(section.rawValue, forKey: MainWindowSelection.sectionKey)
            }
        }
    }

    /// each section's selected rows, by their stable ids; the main window's columns bind to them. Kept in UserDefaults
    /// with the section (WIN-05).
    public var selection = MainWindowSelection() {
        didSet {
            if selection != oldValue, let defaults {
                selection.save(to: defaults)
            }
        }
    }

    /// grows by one whenever the shown section's list should take the keyboard focus: after ⌘1 to ⌘4, a "Show in …"
    /// button, or Hide and Stop Watching in a detail (`main-window.md`, Keyboard)
    public private(set) var listFocusRequest = 0

    /// grows by one whenever the window's search field should take the keyboard focus: Edit › Find… (⌘F)
    public private(set) var searchFocusRequest = 0

    /// Opens the rebuilt app and quits, after "Update Ready — Rebuild" installed it (APP-05). The app sets it; until
    /// then the new app is installed but not opened.
    @ObservationIgnored public var onRebuilt: (@MainActor (URL) -> Void)?

    @ObservationIgnored private let opener: @MainActor (WindowRoute) -> Void
    /// where the section and the selections are kept; `nil` keeps them in memory only
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var surfacesByHost: [String: Set<Surface>] = [:]
    /// the calls to the scheduler, in the order the hosts made them
    @ObservationIgnored private var reports: Task<Void, Never>?

    /// Creates the router.
    ///
    /// - Parameters:
    ///   - defaults: where the main window's section and selections are kept (WIN-05), the preferences' suite; `nil`
    ///     keeps them in memory only
    ///   - open: opens a route: sets the regular activation policy, opens the main window or Settings, then activates
    ///     the app (Task 0.11). For ``WindowRoute/watch(_:)`` it opens the main window; the request is stored already.
    public init(defaults: UserDefaults? = nil, open: @escaping @MainActor (WindowRoute) -> Void) {
        self.defaults = defaults
        opener = open
        if let defaults {
            section = defaults.string(forKey: MainWindowSelection.sectionKey).flatMap(MainWindowSection.init(rawValue:))
                ?? .pipelines
            selection = MainWindowSelection(defaults: defaults)
        }
    }

    /// Opens a route. For ``WindowRoute/watch(_:)``, it stores the request first, so the main window shows the sheet
    /// as soon as it appears.
    ///
    /// - Parameter route: what to open
    public func open(_ route: WindowRoute) {
        if case .watch(let request) = route {
            watchRequest = request
        }
        opener(route)
    }

    /// Opens the main window at a section, or brings it forward there: `menubar-monitor://open/<section>` (APP-03), and
    /// the View menu's ⌘1 to ⌘4 while another window is key.
    ///
    /// - Parameter section: the section to show
    public func open(_ section: MainWindowSection) {
        self.section = section
        open(.main)
    }

    /// Shows a build in Pipelines, as the merge request detail's "Show in Pipelines" does: the section changes as on
    /// ⌘1, which clears the search, and the build's job is selected. The window is open already.
    ///
    /// - Parameter job: the build's job, `Build.job`
    public func showInPipelines(job: String) {
        selection.pipelines = job
        section = .pipelines
        focusList()
    }

    /// Shows a merge request in Merge Requests, as the work item detail's "Show in Merge Requests" does: the section
    /// changes as on ⌘2, which clears the search, and the merge request is selected. The window is open already.
    ///
    /// - Parameter mergeRequest: the merge request's id, its web URL
    public func showInMergeRequests(_ mergeRequest: MergeRequest.ID) {
        selection.mergeRequests = mergeRequest
        section = .mergeRequests
        focusList()
    }

    /// Shows a checkout in Workspaces, as the tag on a merge request or a build does (WS-07): the section changes as on
    /// ⌘5, and the checkout is selected. The window is open already.
    ///
    /// - Parameter checkout: the checkout's id, its path
    public func showInWorkspaces(_ checkout: Checkout.ID) {
        selection.workspaces = checkout
        section = .workspaces
        focusList()
    }

    /// Asks the shown section's list to take the keyboard focus, as after ⌘1 to ⌘4 (`main-window.md`, Keyboard).
    public func focusList() {
        listFocusRequest += 1
    }

    /// Asks the main window's search field to take the keyboard focus (Edit › Find…, ⌘F; WIN-05).
    public func focusSearch() {
        searchFocusRequest += 1
    }

    /// Notes the GitLab surfaces one host shows, such as the panel or the main window, and returns those that all
    /// hosts show together, for `Scheduler.setVisible(_:)`, which wants every surface shown anywhere (OD-02).
    ///
    /// - Parameters:
    ///   - surfaces: what the host shows now; empty when it disappears
    ///   - host: the host's name, like `panel`
    /// - Returns: the surfaces any host shows
    public func surfaces(_ surfaces: Set<Surface>, shownBy host: String) -> Set<Surface> {
        surfacesByHost[host] = surfaces.isEmpty ? nil : surfaces
        return surfacesByHost.values.reduce(into: []) { $0.formUnion($1) }
    }

    /// Notes the GitLab surfaces one host shows and tells the scheduler those that all hosts show, after the reports
    /// before it, so that closing the panel never overtakes opening it (OD-02).
    ///
    /// - Parameters:
    ///   - surfaces: what the host shows now; empty when it disappears
    ///   - host: the host's name, like `panel`
    ///   - scheduler: the app's scheduler
    public func report(_ surfaces: Set<Surface>, shownBy host: String, to scheduler: Scheduler) {
        let shown = self.surfaces(surfaces, shownBy: host)
        let previous = reports
        reports = Task {
            await previous?.value
            await scheduler.setVisible(shown)
        }
    }
}

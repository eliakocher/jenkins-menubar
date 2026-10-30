import Foundation
import MenubarCore

/// Back and Forward in the main window (WIN-08, the user, 2026-10-30: "like in a browser").
///
/// Every way into the window goes through the router's section, selections and "Opened" item: the sidebar, a click on a
/// row, a chip, a link, the menu bar pane's flyouts, the alert and the search. The router notes each change as a visit,
/// so none of those paths has to know about the history. Scrolling, tabs and what happens inside a card change none of
/// the three, and so note nothing.
extension WindowRouter {
    /// the place the window shows now: the item under "Opened", else the section with the selected row
    var navigationLocation: NavigationLocation {
        if let opened {
            // The section behind an opened item is no part of the place: the same item is one place.
            return NavigationLocation(section: .pipelines, opened: opened)
        }
        let item: String? =
            switch section {
            case .pipelines: selection.pipelines
            case .mergeRequests: selection.mergeRequests?.absoluteString
            case .workItems: selection.workItems
            case .workspaces: selection.workspaces
            // Activity's entries come and go with the log, and Slots has no selection.
            case .activity, .slots: nil
            }
        return NavigationLocation(section: section, item: item)
    }

    /// Notes where the window is now as a visit, unless Back or Forward moved it, or the place is the one shown already.
    /// Clearing the selection of the shown section is no navigation either (Hide, Stop Watching): a browser has no such
    /// page to go back to.
    func noteNavigation() {
        guard !isRestoringNavigation else {
            return
        }
        let location = navigationLocation
        let shown = history.current
        if location.opened == nil, location.item == nil, shown.opened == nil, shown.section == location.section,
            shown.item != nil
        {
            return
        }
        history.visit(location)
    }

    /// Starts listening for the mouse's back and forward buttons and for ⌘← and ⌘→, once for the app; the main window
    /// calls it when it appears.
    ///
    /// - Parameter model: the app's model, which says what still exists
    func startNavigationInput(model: AppModel) {
        navigationInput.start(goBack: { [weak self] in self?.goBack(model: model) }, goForward: { [weak self] in self?.goForward(model: model) })
    }

    /// Goes back to the nearest place that still exists, as ⌘[ and the mouse's back button do.
    ///
    /// - Parameter model: the app's model, which says what still exists
    func goBack(model: AppModel) {
        let resolver = NavigationResolver(model)
        if let location = history.back(isValid: resolver.exists) {
            restore(location)
        }
    }

    /// Goes forward to the nearest place that still exists, as ⌘] and the mouse's forward button do.
    ///
    /// - Parameter model: the app's model, which says what still exists
    func goForward(model: AppModel) {
        let resolver = NavigationResolver(model)
        if let location = history.forward(isValid: resolver.exists) {
            restore(location)
        }
    }

    /// Goes to a place of the Back or Forward menu.
    ///
    /// - Parameters:
    ///   - location: the place
    ///   - model: the app's model, which says whether it still exists
    func jump(to location: NavigationLocation, model: AppModel) {
        guard NavigationResolver(model).exists(location), history.jump(to: location) else {
            return
        }
        restore(location)
    }

    /// Shows a place again without noting a visit: the section and its selection, or the item under "Opened". The search
    /// is cleared and the list scrolls to the row, as when a row is revealed from outside.
    private func restore(_ location: NavigationLocation) {
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }
        if let id = location.opened {
            opened = id
        } else {
            switch location.section {
            case .pipelines: selection.pipelines = location.item
            case .mergeRequests: selection.mergeRequests = location.item.flatMap { URL(string: $0) }
            case .workItems: selection.workItems = location.item
            case .workspaces: selection.workspaces = location.item
            case .activity, .slots: break
            }
            section = location.section
        }
        revealRequest += 1
    }
}

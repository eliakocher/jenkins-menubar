import Foundation

/// Where a link to Jenkins or GitLab goes (WIN-06, APP-09): the user's rule is to stay in the app, so the browser only
/// gets what the app has no page for, and every link while ⌥ is held. Pure, so one function decides for the link
/// router, the rows, the chips, the banners and the glass alert alike.
public enum LinkDecision: Hashable, Sendable {
    /// the item's section with the item selected: it is in my lists
    case list
    /// under "Opened", for the time: a merge request, work item or build outside my lists
    case opened
    /// the real browser
    case browser

    /// Decides.
    ///
    /// - A link with ⌥ held goes to the browser, whatever it is.
    /// - A GitLab pipeline, a Jenkins job outside my lists and any other link have no page in the app: the browser.
    /// - A build, merge request or work item shows in its list when it is there, else under "Opened" while the app can
    ///   load it.
    ///
    /// - Parameters:
    ///   - route: what ``LinkRouter`` made of the link
    ///   - optionHeld: whether ⌥ is held
    ///   - isListed: whether the item is in my lists (a build counts with its number)
    ///   - canOpen: whether the app can load the item itself: the GitLab or Jenkins URL of its project is in Team
    /// - Returns: the place
    public static func decide(_ route: LinkRoute, optionHeld: Bool, isListed: Bool, canOpen: Bool) -> LinkDecision {
        guard !optionHeld else {
            return .browser
        }
        switch route {
        case .browser, .pipeline:
            return .browser
        case .jenkinsJob:
            return isListed ? .list : .browser
        case .jenkinsBuild, .mergeRequest, .workItem:
            if isListed {
                return .list
            }
            return canOpen ? .opened : .browser
        }
    }
}

import AppKit
import MenubarCore
import SwiftUI

extension WindowRouter {
    /// Opens a link to a build, merge request or work item in the main window, in its list or under "Opened" (WIN-06),
    /// for the links inside the app: Markdown, related merge requests, chips and rows. ⌥ held means the browser, so it
    /// does nothing.
    ///
    /// - Parameters:
    ///   - url: the link
    ///   - model: the app's model
    /// - Returns: whether the link was one of the app's builds, merge requests or work items and is shown; `false` leaves it
    ///   to the caller, who opens the browser
    @discardableResult
    public func openItemLink(_ url: URL, model: AppModel) -> Bool {
        let route = LinkRouter(projects: model.team.projects()).route(url)
        guard
            let destination = model.destination(
                for: route, link: url, optionHeld: NSEvent.modifierFlags.contains(.option))
        else {
            return false
        }
        show(destination)
        return true
    }

    /// Follows a link inside the app (the user, 2026-10-30): a build, merge request or work item shows in the main window,
    /// and what the app has no page for, ⌥ held, goes to the browser.
    ///
    /// - Parameters:
    ///   - url: the link
    ///   - model: the app's model
    ///   - fallback: the environment's action that opens a web page, for a router without the app's browser opener
    func follow(_ url: URL, model: AppModel, fallback: OpenURLAction) {
        if !openItemLink(url, model: model) {
            browse(url, fallback: fallback)
        }
    }

    /// Opens a page in the real browser, never in this app, also while it is the Mac's default browser: the menu bar's
    /// "Open in Browser" and the commands that have no view environment.
    ///
    /// - Parameter url: the page
    func browse(_ url: URL) {
        if let openInBrowser {
            openInBrowser(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a page in the real browser, never in this app, also while it is the Mac's default browser.
    ///
    /// - Parameters:
    ///   - url: the page
    ///   - fallback: the environment's action that opens a web page, for a router without the app's browser opener (the
    ///     gallery)
    func browse(_ url: URL, fallback: OpenURLAction) {
        if let openInBrowser {
            openInBrowser(url)
        } else {
            fallback(url)
        }
    }
}

/// What a link in Markdown does when it leads to a merge request or work item: the main window sets it to open the item
/// in the app (WIN-06). The default leaves every link to the system.
struct OpenItemLink: Sendable {
    var handle: @MainActor @Sendable (URL) -> Bool

    static let none = OpenItemLink { _ in false }
}

private struct OpenItemLinkKey: EnvironmentKey {
    static let defaultValue = OpenItemLink.none
}

extension EnvironmentValues {
    var openItemLink: OpenItemLink {
        get { self[OpenItemLinkKey.self] }
        set { self[OpenItemLinkKey.self] = newValue }
    }
}

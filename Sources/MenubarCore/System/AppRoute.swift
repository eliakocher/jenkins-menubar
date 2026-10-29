import Foundation

/// A `menubar-monitor://` link, which other apps, the terminal and the browser can open (APP-03).
///
/// - `menubar-monitor://settings/<pane>`: Settings at that pane, its name in lowercase, like `gitlab`; an unknown pane
///   opens General.
/// - `menubar-monitor://watch?target=<link>`: watches the link as WATCH-01 does; a refusal opens the main window with
///   the Watch a Build… sheet.
/// - `menubar-monitor://open/<section>`: the main window at that section.
///
/// Any other link of the scheme opens the main window.
public enum AppRoute: Hashable, Sendable {
    case settings(SettingsPane)
    /// the link to watch, as given; empty when the link had none, which the watch sheet then refuses
    case watch(target: String)
    case open(Section)
    case mainWindow

    /// A section of the main window's sidebar, named as in its link.
    public enum Section: String, Hashable, Sendable, CaseIterable {
        case pipelines
        case mergeRequests = "merge-requests"
        case workItems = "work-items"
        case activity
        /// the local checkouts of Settings → Repositories (WS-01)
        case workspaces
        /// the release slots with their committed work items (SLOT-02)
        case slots
    }

    /// Reads a link.
    ///
    /// - Parameter url: the link, like `menubar-monitor://settings/team`
    /// - Returns: nil for a link of another scheme
    public init?(url: URL) {
        guard url.scheme?.lowercased() == AppIdentity.urlScheme else {
            return nil
        }
        let name = url.pathComponents.first { $0 != "/" }?.lowercased()
        switch url.host(percentEncoded: false)?.lowercased() {
        case "settings":
            self = .settings(SettingsPane.allCases.first { $0.rawValue.lowercased() == name } ?? .general)
        case "watch":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            self = .watch(target: items.first { $0.name == "target" }?.value ?? "")
        case "open":
            self = name.flatMap(Section.init(rawValue:)).map(AppRoute.open) ?? .mainWindow
        default:
            self = .mainWindow
        }
    }

    /// the link that leads here
    public var url: URL {
        var components = URLComponents()
        components.scheme = AppIdentity.urlScheme
        switch self {
        case .settings(let pane):
            components.host = "settings"
            components.path = "/\(pane.rawValue.lowercased())"
        case .watch(let target):
            components.host = "watch"
            components.queryItems = [URLQueryItem(name: "target", value: target)]
        case .open(let section):
            components.host = "open"
            components.path = "/\(section.rawValue)"
        case .mainWindow:
            components.host = "open"
        }
        // Every part above is valid in a URL, so this never fails.
        return components.url!
    }
}

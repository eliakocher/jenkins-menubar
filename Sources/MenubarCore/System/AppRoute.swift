import Foundation

/// A `megamonitor://` link, which other apps, the terminal and the browser can open (APP-03). The former
/// `menubar-monitor://` links work too.
///
/// - `megamonitor://settings/<pane>`: Settings at that pane, its name in lowercase, like `gitlab`; an unknown pane
///   opens General.
/// - `megamonitor://watch?target=<link>`: watches the link as WATCH-01 does; a refusal opens the main window with
///   the Watch a Build… sheet.
/// - `megamonitor://open/<section>`: the main window at that section.
/// - `megamonitor://import?url=<https link>`: Settings → Team with the import of that team file (TEAM-02). It only
///   asks for the import: Settings fetches the file and shows its preview, and nothing is applied before the user
///   confirms, and confirms a changed server host by name. Only an `https` link in exactly one `url` parameter counts
///   (a second `url`, or none, is ambiguous and refused); every other parameter is ignored. A refused link opens the
///   main window like any unknown one.
///
/// Any other link of the scheme opens the main window.
public enum AppRoute: Hashable, Sendable {
    case settings(SettingsPane)
    /// the link to watch, as given; empty when the link had none, which the watch sheet then refuses
    case watch(target: String)
    case open(Section)
    /// the https link of a team file to preview in Settings → Team, as the link had it (TEAM-02); never applied by
    /// the route itself
    case importTeamFile(link: URL)
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
        /// the daily digest Claude writes (AI-04), shown only while the Claude features are on
        case digest
    }

    /// Reads a link.
    ///
    /// - Parameter url: the link, like `megamonitor://settings/team`
    /// - Returns: nil for a link of another scheme
    public init?(url: URL) {
        // The former scheme too, so links written before the rename keep working.
        guard let scheme = url.scheme?.lowercased(), AppIdentity.urlSchemes.contains(scheme) else {
            return nil
        }
        let name = url.pathComponents.first { $0 != "/" }?.lowercased()
        switch url.host(percentEncoded: false)?.lowercased() {
        case "settings":
            self = .settings(name.flatMap(SettingsPane.init(name:)) ?? .general)
        case "watch":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            self = .watch(target: items.first { $0.name == "target" }?.value ?? "")
        case "import":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // One `url` only: two of them leave it open which one a reader would take.
            if items.filter({ $0.name == "url" }).count == 1, let link = TeamFileImport.fileLink(fromShareLink: url) {
                self = .importTeamFile(link: link)
            } else {
                self = .mainWindow
            }
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
        case .importTeamFile(let link):
            components.host = "import"
            components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        case .mainWindow:
            components.host = "open"
        }
        // Every part above is valid in a URL, so this never fails.
        return components.url!
    }
}

extension AppRoute {
    /// Hands an import link's team file to Settings → Team, which fetches it and shows the preview. This is all the
    /// route does: it applies nothing and fetches nothing itself.
    ///
    /// - Parameter settings: the settings the Team pane reads the waiting link from
    /// - Returns: whether the route was an import link
    @MainActor
    @discardableResult
    public func requestTeamFileImport(on settings: SettingsStore) -> Bool {
        guard case .importTeamFile(let link) = self else { return false }
        settings.requestTeamFileImport(link)
        return true
    }
}

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
/// - `megamonitor://item?url=<https link>&card=<card>`: a build, merge request or work item of that link in the app, as a
///   click on it does, and with `card` (`claude`, `discussion`, `failed-tests` or `console-log`) its page scrolled to
///   that card. Only an `http` or `https` link in exactly one `url` parameter counts; an unknown `card` shows the page
///   from the top; a refused link opens the main window.
///
/// - `megamonitor://whats-new?from=<version>&to=<version>`: the main window with the "What's New" sheet: the changelog's
///   versions after `from` up to `to`. Either can be left out; without both it shows the whole changelog.
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
    /// a build, merge request or work item by its web link, with the card of its page to bring into view
    case openItem(link: URL, card: DetailCardID?)
    case mainWindow
    /// the "What's New" sheet on the main window: the changelog's versions after `from` up to `to`; nil for no end
    case whatsNew(from: String?, to: String?)

    /// A section of the main window's sidebar, named as in its link.
    public enum Section: String, Hashable, Sendable, CaseIterable {
        case pipelines
        /// GitLab's To-Do List with Snooze, and the changes of my merge requests (Task 7.03, INBOX-02); second, so ⌘1
        /// stays Pipelines
        case inbox
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
        case "item":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let links = items.filter { $0.name == "url" }
            if links.count == 1, let text = links[0].value, let link = URL(string: text),
                ["http", "https"].contains(link.scheme?.lowercased()), link.host(percentEncoded: false)?.isEmpty == false
            {
                let card = items.first { $0.name == "card" }?.value.flatMap { DetailCardID(rawValue: $0.lowercased()) }
                self = .openItem(link: link, card: card)
            } else {
                self = .mainWindow
            }
        case "whats-new":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            self = .whatsNew(
                from: items.first { $0.name == "from" }?.value.flatMap { $0.isEmpty ? nil : $0 },
                to: items.first { $0.name == "to" }?.value.flatMap { $0.isEmpty ? nil : $0 })
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
        case .openItem(let link, let card):
            components.host = "item"
            components.queryItems =
                [URLQueryItem(name: "url", value: link.absoluteString)]
                + (card.map { [URLQueryItem(name: "card", value: $0.rawValue)] } ?? [])
        case .mainWindow:
            components.host = "open"
        case .whatsNew(let from, let to):
            components.host = "whats-new"
            let items = [("from", from), ("to", to)].compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            components.queryItems = items.isEmpty ? nil : items
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

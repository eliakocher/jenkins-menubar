import Foundation

/// What a banner carries in its user info, so that a click on it or on one of its actions opens the right link, also
/// when the click starts the app (ALERT-08).
///
/// The app's `NativeEffects` posts it with the banner; its notification delegate reads it back and opens
/// ``url(forAction:)``, starts the rebuild of ``rebuild(forAction:)`` (PIPE-09), or hides the build of
/// ``hide(forAction:)`` (HIDE-01); ``intent(forAction:)`` says which of the three a click means.
public struct BannerPayload: Hashable, Sendable {
    /// the notification category, which sets the banner's actions
    public var category: AlertContent.BannerCategory
    /// the link a click on the banner itself opens (ALERT-03)
    public var defaultAction: AlertContent.Action
    public var links: AlertContent.Links
    /// the build that the banner's Rebuild starts again; `nil` for a banner without Rebuild (PIPE-09)
    public var rebuild: BuildID?
    /// the build that the banner's Hide hides; `nil` for a banner without Hide, as a preview's (HIDE-01)
    public var hide: BuildID?

    /// What a click on a banner or one of its actions asks the app to do.
    public enum Intent: Hashable, Sendable {
        /// open a link in the browser
        case open(URL)
        /// start the build's rebuild (PIPE-09)
        case rebuild(BuildID)
        /// hide the build until its job's next build (HIDE-01)
        case hide(BuildID)
    }

    public init(
        category: AlertContent.BannerCategory, defaultAction: AlertContent.Action, links: AlertContent.Links,
        rebuild: BuildID? = nil, hide: BuildID? = nil
    ) {
        self.category = category
        self.defaultAction = defaultAction
        self.links = links
        self.rebuild = rebuild
        self.hide = hide
    }

    /// Returns the payload of an alert's banner.
    ///
    /// - Parameter content: the alert's content
    public init(content: AlertContent) {
        self.init(
            category: content.bannerCategory, defaultAction: content.defaultAction, links: content.links,
            rebuild: content.rebuild, hide: content.hide)
    }

    /// Returns the actions of a category, in the order the banner shows them.
    ///
    /// - Parameter category: the category
    /// - Returns: Open MR and Open build, or Open build alone; then Rebuild in the categories with it (PIPE-09); then
    ///   Open Console and Hide in the live ones (HIDE-01)
    public static func actions(of category: AlertContent.BannerCategory) -> [AlertContent.Action] {
        category.actions
    }

    /// Returns what a click asks for.
    ///
    /// - Parameter action: the action's identifier; nil for a click on the banner itself
    /// - Returns: the rebuild, the hide or the link; nil for a click that does nothing, as on an identifier that isn't
    ///   an action of this banner
    public func intent(forAction action: String?) -> Intent? {
        if let build = rebuild(forAction: action) {
            return .rebuild(build)
        }
        if let build = hide(forAction: action) {
            return .hide(build)
        }
        return url(forAction: action).map(Intent.open)
    }

    /// Returns the build a click on the banner's Hide hides (HIDE-01).
    ///
    /// - Parameter action: the action's identifier; nil for a click on the banner itself
    /// - Returns: the build; nil for any other click, and for a banner without Hide
    public func hide(forAction action: String?) -> BuildID? {
        guard action == AlertContent.Action.hide.rawValue, Self.actions(of: category).contains(.hide) else {
            return nil
        }
        return hide
    }

    /// Returns the build a click on the banner's Rebuild starts again (PIPE-09).
    ///
    /// - Parameter action: the action's identifier; nil for a click on the banner itself
    /// - Returns: the build; nil for any other click, and for a banner without Rebuild
    public func rebuild(forAction action: String?) -> BuildID? {
        guard action == AlertContent.Action.rebuild.rawValue, Self.actions(of: category).contains(.rebuild) else {
            return nil
        }
        return rebuild
    }

    /// Returns the link a click opens.
    ///
    /// - Parameter action: the action's identifier, an ``AlertContent/Action`` raw value; nil for a click on the banner
    ///   itself
    /// - Returns: the build or the MR; nil for an identifier that isn't an action of this banner
    public func url(forAction action: String?) -> URL? {
        guard let action else {
            return links.url(for: defaultAction)
        }
        guard let action = AlertContent.Action(rawValue: action), Self.actions(of: category).contains(action) else {
            return nil
        }
        return links.url(for: action)
    }

    /// the banner's user info, plain strings only, which UserNotifications keeps across launches
    public var userInfo: [String: String] {
        var info = [
            Key.category: category.rawValue,
            Key.defaultAction: defaultAction.rawValue,
            Key.build: links.build.absoluteString,
        ]
        info[Key.mergeRequest] = links.mergeRequest?.absoluteString
        info[Key.console] = links.console?.absoluteString
        info[Key.job] = rebuild?.job
        info[Key.number] = rebuild.map { String($0.number) }
        info[Key.hideJob] = hide?.job
        info[Key.hideNumber] = hide.map { String($0.number) }
        info[Key.project] = (rebuild ?? hide)?.project.rawValue
        return info
    }

    /// Reads the payload back from a banner's user info.
    ///
    /// - Parameter userInfo: the user info, as the notification delegate gets it
    /// - Returns: nil when it isn't a payload, such as a banner of an older version
    public init?(userInfo: [AnyHashable: Any]) {
        guard let category = (userInfo[Key.category] as? String).flatMap(AlertContent.BannerCategory.init(rawValue:)),
              let defaultAction = (userInfo[Key.defaultAction] as? String).flatMap(AlertContent.Action.init(rawValue:)),
              let build = (userInfo[Key.build] as? String).flatMap(URL.init(string:))
        else {
            return nil
        }
        let mergeRequest = (userInfo[Key.mergeRequest] as? String).flatMap(URL.init(string:))
        // A banner of a version before several projects has none: it was the primary project's.
        let project = (userInfo[Key.project] as? String).flatMap(ProjectID.init(rawValue:)) ?? .main
        var rebuild: BuildID?
        if let job = userInfo[Key.job] as? String, let number = (userInfo[Key.number] as? String).flatMap({ Int($0) }) {
            rebuild = BuildID(job: job, number: number, project: project)
        }
        let console = (userInfo[Key.console] as? String).flatMap(URL.init(string:))
        var hide: BuildID?
        if let job = userInfo[Key.hideJob] as? String, let number = (userInfo[Key.hideNumber] as? String).flatMap({ Int($0) }) {
            hide = BuildID(job: job, number: number, project: project)
        }
        self.init(
            category: category, defaultAction: defaultAction,
            links: AlertContent.Links(build: build, mergeRequest: mergeRequest, console: console), rebuild: rebuild,
            hide: hide)
    }

    private enum Key {
        static let category = "category"
        static let defaultAction = "defaultAction"
        static let build = "build"
        static let mergeRequest = "mergeRequest"
        static let job = "job"
        static let number = "number"
        static let console = "console"
        static let hideJob = "hideJob"
        static let hideNumber = "hideNumber"
        static let project = "project"
    }
}

extension AlertContent.Links {
    /// Returns the link of an action, like ``AlertContent/url(for:)``.
    fileprivate func url(for action: AlertContent.Action) -> URL? {
        switch action {
        case .openBuild: build
        case .openMergeRequest: mergeRequest
        case .openConsole: console
        case .rebuild, .hide, .dismiss: nil
        }
    }
}

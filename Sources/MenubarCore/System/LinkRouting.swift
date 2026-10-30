import Foundation
import Observation

/// An app that opens web links.
public struct BrowserApp: Codable, Hashable, Sendable {
    /// where the app is
    public var url: URL
    /// the bundle id, like `com.apple.Safari`
    public var bundleID: String?
    /// the name people know it by, like `Safari`
    public var name: String

    public init(url: URL, bundleID: String?, name: String) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
    }
}

/// What the link router asks of macOS: the default browser, and opening a link with an app (APP-09). The app implements
/// it with `NSWorkspace`; the tests and the throwaway and smoke runs use fakes that change nothing on the Mac.
@MainActor
public protocol DefaultBrowserSystem: Sendable {
    /// MegaMonitor itself
    var thisApp: BrowserApp? { get }
    /// the app that opens `https` links now
    func defaultBrowser() -> BrowserApp?
    /// an installed app by its bundle id
    func app(bundleID: String) -> BrowserApp?
    /// whether the app is still there
    func exists(_ app: BrowserApp) -> Bool
    /// Makes an app the default for `http` and `https`; macOS asks the user to confirm.
    /// - Throws: when macOS or the user refuses
    func setDefaultBrowser(_ app: BrowserApp) async throws
    /// Opens a link with an app, without asking anybody.
    func open(_ url: URL, with app: BrowserApp) async
}

/// The opt-in link router's state and rules (APP-09): MegaMonitor becomes the default browser, opens the links that
/// lead to Jenkins and GitLab items it shows in its window, and passes every other link on to the browser the user had.
///
/// - Turning on remembers the current default browser, then makes the app the default (macOS asks); a refusal turns the
///   switch back off with a note.
/// - Turning off gives the remembered browser its place back; with none, or when it is the app itself or gone, Safari.
/// - While the switch is off, a link that still arrives goes to the browser without a look at it.
/// - A link never goes to the app's own default: that would send it back here.
@Observable @MainActor
public final class LinkRouting {
    /// the key of the switch, in the preferences' suite
    static let enabledKey = "linkRouting.enabled"
    /// the key of the remembered browser
    static let browserKey = "linkRouting.browser"
    /// the bundle id of the fallback browser
    static let safariID = "com.apple.Safari"

    /// whether links open in the app; off by default
    public private(set) var isOn: Bool
    /// the quiet note under the switch after a refusal or a failed restore; `nil` for none
    public private(set) var note: String?
    /// whether turning the switch is under way, while macOS asks
    public private(set) var isChanging = false
    /// the browser from before the router was turned on
    public private(set) var remembered: BrowserApp?

    @ObservationIgnored private let system: any DefaultBrowserSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let projects: @MainActor () -> [Project]
    @ObservationIgnored private let log: @MainActor (String) -> Void

    /// - Parameters:
    ///   - system: macOS's default browser
    ///   - defaults: the preferences' suite
    ///   - projects: the projects, read at each link so Settings changes apply at once
    ///   - log: writes a line of the log; it gets only a host and a kind, never a link
    public init(
        system: any DefaultBrowserSystem, defaults: UserDefaults, projects: @escaping @MainActor () -> [Project],
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.system = system
        self.defaults = defaults
        self.projects = projects
        self.log = log
        isOn = defaults.bool(forKey: Self.enabledKey)
        remembered = defaults.data(forKey: Self.browserKey).flatMap { try? JSONDecoder().decode(BrowserApp.self, from: $0) }
        refresh()
    }

    /// the name Settings' footer gives for the browser that gets the other links: the remembered one, else the current
    /// default, else Safari
    public var browserName: String {
        (isOn ? forwardTarget : remembered ?? currentOtherBrowser ?? safari)?.name ?? "Safari"
    }

    /// Reads the system's default browser: the switch shows off when somebody chose another browser in System Settings.
    public func refresh() {
        if isOn, !isDefault {
            isOn = false
            defaults.set(false, forKey: Self.enabledKey)
        }
    }

    /// Turns the router on or off.
    ///
    /// - Parameter on: whether links open in the app
    public func setEnabled(_ on: Bool) async {
        guard on != isOn, !isChanging else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        note = nil
        if on {
            await turnOn()
        } else {
            await turnOff()
        }
    }

    /// Returns what a link that was opened should do.
    ///
    /// - Parameters:
    ///   - url: the link
    ///   - optionHeld: whether ⌥ was held while it arrived, which always means the browser
    /// - Returns: its place in the app, or ``LinkRoute/browser``; the log gets the host and the kind
    public func route(_ url: URL, optionHeld: Bool) -> LinkRoute {
        let route: LinkRoute = isOn && !optionHeld ? LinkRouter(projects: projects()).route(url) : .browser
        log("link to \(url.host(percentEncoded: false) ?? "no host"): \(route.kind)\(optionHeld ? " (⌥)" : "")")
        return route
    }

    /// Hands a link to the browser the user had, never to the app itself.
    ///
    /// - Parameter url: the link
    /// - Returns: whether a browser took it
    @discardableResult
    public func forward(_ url: URL) async -> Bool {
        guard let browser = forwardTarget else {
            return false
        }
        await system.open(url, with: browser)
        return true
    }

    /// the browser that gets the links the app doesn't keep: the remembered one, unless it is this app or gone, else
    /// Safari
    public var forwardTarget: BrowserApp? {
        if let remembered, remembered.bundleID != system.thisApp?.bundleID, system.exists(remembered) {
            return remembered
        }
        return safari
    }

    // MARK: - Turning on and off

    private func turnOn() async {
        let current = system.defaultBrowser()
        // Already the default, as after a restore that failed: the browser remembered before stays.
        if let current, current.bundleID != system.thisApp?.bundleID {
            remember(current)
        }
        guard let this = system.thisApp else {
            note = "MegaMonitor can't find itself as an app, so it can't become the default browser"
            return
        }
        do {
            try await system.setDefaultBrowser(this)
            isOn = true
            defaults.set(true, forKey: Self.enabledKey)
            log("link router on, other links go to \(browserName)")
        } catch {
            if let remembered, system.defaultBrowser()?.bundleID == this.bundleID {
                try? await system.setDefaultBrowser(remembered)
            }
            note = "macOS didn't change the default browser, so links keep opening in \(browserName)"
            log("link router: macOS refused the default browser")
        }
    }

    private func turnOff() async {
        guard let target = forwardTarget else {
            isOn = false
            defaults.set(false, forKey: Self.enabledKey)
            note = "No browser found to restore: choose one in System Settings → Desktop & Dock"
            return
        }
        do {
            try await system.setDefaultBrowser(target)
            forget()
            log("link router off, default browser \(target.name)")
        } catch {
            note = "Couldn't give \(target.name) its place back: choose a browser in System Settings → Desktop & Dock. Until then MegaMonitor passes every link on"
            log("link router: restoring the default browser failed")
        }
        // Either way the app stops routing: a link that still arrives goes straight to the browser.
        isOn = false
        defaults.set(false, forKey: Self.enabledKey)
    }

    private func remember(_ browser: BrowserApp) {
        remembered = browser
        defaults.set(try? JSONEncoder().encode(browser), forKey: Self.browserKey)
    }

    private func forget() {
        remembered = nil
        defaults.removeObject(forKey: Self.browserKey)
    }

    private var isDefault: Bool {
        guard let this = system.thisApp?.bundleID else {
            return false
        }
        return system.defaultBrowser()?.bundleID == this
    }

    private var currentOtherBrowser: BrowserApp? {
        system.defaultBrowser().flatMap { $0.bundleID == system.thisApp?.bundleID ? nil : $0 }
    }

    private var safari: BrowserApp? {
        system.app(bundleID: Self.safariID)
    }
}

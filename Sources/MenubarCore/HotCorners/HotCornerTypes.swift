import CoreGraphics
import Foundation

// Hot Corners (HOT-01…): the screen corners run an action when the pointer rests there, a different one with ⌘, ⌥, ⌃
// or ⇧ held. These are the shared types: the Settings pane edits them, the controller fires them, and the app's
// `HotCornerSystem` performs the macOS actions. Lanes add to these types; they don't rename what is here.

/// A corner of a display.
public enum HotCorner: String, Codable, CaseIterable, Hashable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// the corner's name, in Title Style
    public var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A modifier key that picks a corner's other action. One at a time: two held together pick nothing.
public enum HotCornerModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command, option, control, shift

    /// the key's symbol, like ⌘
    public var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    /// the key's name
    public var title: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        }
    }
}

/// An action of macOS, as the native hot corners have them. The app performs them through `HotCornerSystem`, none
/// with the Accessibility permission.
public enum SystemCornerAction: String, Codable, CaseIterable, Hashable, Sendable {
    case missionControl
    case applicationWindows
    case desktop
    /// the Apps launcher, formerly Launchpad
    case apps
    case startScreenSaver
    /// keeps the screen saver away while the pointer rests in the corner: a hold, not a one-time action
    case disableScreenSaver
    case displaySleep
    case lockScreen

    public var title: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .desktop: "Desktop"
        case .apps: "Apps"
        case .startScreenSaver: "Start Screen Saver"
        case .disableScreenSaver: "Disable Screen Saver"
        case .displaySleep: "Put Display to Sleep"
        case .lockScreen: "Lock Screen"
        }
    }

    /// an SF Symbol for the action
    public var symbolName: String {
        switch self {
        case .missionControl: "rectangle.3.group"
        case .applicationWindows: "macwindow.on.rectangle"
        case .desktop: "menubar.dock.rectangle"
        case .apps: "square.grid.3x3"
        case .startScreenSaver: "sparkles.tv"
        case .disableScreenSaver: "tv.slash"
        case .displaySleep: "moon.zzz"
        case .lockScreen: "lock"
        }
    }

    /// whether the action lasts while the pointer rests in the corner and ends when it leaves
    public var isHold: Bool { self == .disableScreenSaver }
}

/// What a corner, or a corner with a modifier, does.
public enum HotCornerAction: Codable, Hashable, Sendable {
    case none
    case system(SystemCornerAction)
    /// the main window at a section
    case openSection(AppRoute.Section)
    /// the main window as the global hotkey opens it: shown, or hidden when it is in front already
    case showMainWindow
    /// the main window's search field (Edit › Find…)
    case search
    /// a shortcut of the Shortcuts app, by its name exactly as `shortcuts list` prints it
    case runShortcut(name: String)
    /// an app, by the path of its bundle
    case openApp(path: String)

    /// the actions of MegaMonitor itself, in menu order
    public static let appActions: [HotCornerAction] =
        [.showMainWindow] + AppRoute.Section.allCases.map(HotCornerAction.openSection) + [.search]

    /// The action as one stored text: `none`, `system.<name>`, `section.<name>`, `showMainWindow`, `search`,
    /// `shortcut:<name>`, `app:<path>`.
    public var storedText: String {
        switch self {
        case .none: "none"
        case .system(let action): "system.\(action.rawValue)"
        case .openSection(let section): "section.\(section.rawValue)"
        case .showMainWindow: "showMainWindow"
        case .search: "search"
        case .runShortcut(let name): "shortcut:\(name)"
        case .openApp(let path): "app:\(path)"
        }
    }

    /// Reads a stored text; one no action has (an action of a later version, garbage, or the removed Refresh Now and
    /// Mute Alerts for 1 Hour: `refreshNow`, `muteAlerts`) is ``none``.
    ///
    /// - Parameter storedText: the text of ``storedText``
    public init(storedText text: String) {
        // A shortcut's name is kept verbatim, trailing spaces too: `shortcuts run` needs them.
        if text.hasPrefix("shortcut:") {
            let rest = String(text.dropFirst("shortcut:".count))
            self = rest.isEmpty ? .none : .runShortcut(name: rest)
        } else if text.hasPrefix("app:") {
            let rest = String(text.dropFirst("app:".count))
            self = rest.isEmpty ? .none : .openApp(path: rest)
        } else if text.hasPrefix("system.") {
            self = SystemCornerAction(rawValue: String(text.dropFirst("system.".count))).map(HotCornerAction.system) ?? .none
        } else if text.hasPrefix("section.") {
            self = AppRoute.Section(rawValue: String(text.dropFirst("section.".count))).map(HotCornerAction.openSection) ?? .none
        } else {
            switch text {
            case "showMainWindow": self = .showMainWindow
            case "search": self = .search
            default: self = .none
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let text = (try? decoder.singleValueContainer().decode(String.self)) ?? "none"
        self.init(storedText: text)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedText)
    }
}

/// One corner's setup: the delay and its five actions.
public struct HotCornerSetup: Codable, Hashable, Sendable {
    /// seconds the pointer rests in the corner before the action fires, one of ``HotCornerSettings/delayOptions``
    public var delay: Double
    /// the action without a modifier
    public var plain: HotCornerAction
    public var command: HotCornerAction
    public var option: HotCornerAction
    public var control: HotCornerAction
    public var shift: HotCornerAction

    public init(
        delay: Double = 0.15, plain: HotCornerAction = .none, command: HotCornerAction = .none,
        option: HotCornerAction = .none, control: HotCornerAction = .none, shift: HotCornerAction = .none
    ) {
        self.delay = delay
        self.plain = plain
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// The action for a modifier; nil is the plain one.
    public subscript(modifier: HotCornerModifier?) -> HotCornerAction {
        get {
            switch modifier {
            case nil: plain
            case .command?: command
            case .option?: option
            case .control?: control
            case .shift?: shift
            }
        }
        set {
            switch modifier {
            case nil: plain = newValue
            case .command?: command = newValue
            case .option?: option = newValue
            case .control?: control = newValue
            case .shift?: shift = newValue
            }
        }
    }

    /// whether any of the five actions does something
    public var hasAction: Bool {
        ([nil] + HotCornerModifier.allCases.map(Optional.some)).contains { self[$0] != .none }
    }
}

/// Settings → Hot Corners: the switch and the four corners.
public struct HotCornerSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var topLeft: HotCornerSetup
    public var topRight: HotCornerSetup
    public var bottomLeft: HotCornerSetup
    public var bottomRight: HotCornerSetup
    /// the light that plays in a corner when its action fires (HOT-12)
    public var glow: HotCornerGlow

    /// Instant, 0.15 s, 0.3 s, 0.5 s, 1 s, 2 s, as the old Hot Corners app had them
    public static let delayOptions: [Double] = [0, 0.15, 0.3, 0.5, 1, 2]

    public init(
        enabled: Bool = false, topLeft: HotCornerSetup = HotCornerSetup(), topRight: HotCornerSetup = HotCornerSetup(),
        bottomLeft: HotCornerSetup = HotCornerSetup(), bottomRight: HotCornerSetup = HotCornerSetup(),
        glow: HotCornerGlow = HotCornerGlow()
    ) {
        self.glow = glow
        self.enabled = enabled
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    public subscript(corner: HotCorner) -> HotCornerSetup {
        get {
            switch corner {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomLeft: bottomLeft
            case .bottomRight: bottomRight
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomLeft: bottomLeft = newValue
            case .bottomRight: bottomRight = newValue
            }
        }
    }

    /// whether the pointer needs watching: switched on, with at least one action somewhere
    public var needsWatching: Bool {
        enabled && HotCorner.allCases.contains { self[$0].hasAction }
    }
}

/// A pointer move as the app sees it.
public struct PointerEvent: Hashable, Sendable {
    /// global coordinates, bottom-left origin, the space of `NSScreen.frame` and `NSEvent.mouseLocation`
    public var location: CGPoint
    /// whether any mouse button is down (a drag)
    public var buttonsDown: Bool

    public init(location: CGPoint, buttonsDown: Bool) {
        self.location = location
        self.buttonsDown = buttonsDown
    }
}

/// Watches the pointer for Hot Corners, without the Accessibility permission. The app's is NSEvent monitors; the tests
/// use a fake that sends made-up events.
@MainActor
public protocol PointerSource: AnyObject {
    /// Starts sending pointer moves and drags; replaces a handler given before.
    func start(_ onEvent: @escaping @MainActor (PointerEvent) -> Void)
    /// Stops sending; nothing is watched afterwards.
    func stop()
    /// the displays' frames now, in the space of ``PointerEvent/location``
    var screens: [CGRect] { get }
    /// the modifier keys held right now
    var modifiers: Set<HotCornerModifier> { get }
}

/// What the old values of the Hot Corners app read: the keys of the `dev.kocher.HotCorners` defaults, as stored
/// (strings, doubles and booleans).
public typealias LegacyHotCornersDefaults = [String: any Sendable]

/// The macOS side of Hot Corners: the app performs the actions, the tests use a fake that only records them. A test
/// must never reach the real one: no Mission Control, display sleep, lock or shortcut from a test run.
@MainActor
public protocol HotCornerSystem: AnyObject {
    /// Performs a one-time action, or starts a hold (``SystemCornerAction/isHold``).
    func perform(_ action: SystemCornerAction)
    /// Ends the hold that ``perform(_:)`` started, if one runs.
    func endHold()
    /// Runs a shortcut of the Shortcuts app, by its name as `shortcuts list` prints it.
    func runShortcut(named name: String)
    /// Opens the app at the bundle path.
    func openApp(at path: String)
    /// Plays the corner glow (HOT-12) at a corner of a display.
    ///
    /// - Parameters:
    ///   - corner: the corner
    ///   - screen: the display's frame, in global coordinates with the origin at the bottom left
    ///   - glow: the color, animation and size
    func showGlow(at corner: HotCorner, screen: CGRect, glow: HotCornerGlow)
    /// the names of the user's shortcuts, as `shortcuts list` prints them, sorted
    func shortcutNames() async -> [String]
    /// whether the old Hot Corners app (`dev.kocher.HotCorners`) runs
    var isLegacyAppRunning: Bool { get }
    /// Asks the old Hot Corners app to quit. Never deletes it.
    func quitLegacyApp()
    /// the old app's defaults, or nil when it never stored any
    func legacyDefaults() -> LegacyHotCornersDefaults?
}

// MARK: - Decoding, storing and naming (Core lane)

extension HotCornerAction {
    /// The action as one line of the Activity log, like "Lock Screen", "Open Merge Requests" or "Run Shortcut “Focus”".
    public var logText: String {
        switch self {
        case .none: "Nothing"
        case .system(let action): action.title
        case .openSection(let section): "Open \(section.logTitle)"
        case .showMainWindow: "Show Main Window"
        case .search: "Search…"
        case .runShortcut(let name): "Run Shortcut “\(name.trimmingCharacters(in: .whitespaces))”"
        case .openApp(let path): "Open \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        }
    }
}

extension AppRoute.Section {
    /// the section's name in the log, in Title Style
    fileprivate var logTitle: String {
        switch self {
        case .pipelines: "Pipelines"
        case .inbox: "Inbox"
        case .mergeRequests: "Merge Requests"
        case .workItems: "Work Items"
        case .activity: "Activity"
        case .workspaces: "Workspaces"
        case .slots: "Slots"
        case .digest: "Digest"
        }
    }
}

extension HotCornerSetup {
    private enum CodingKeys: String, CodingKey {
        case delay, plain, command, option, control, shift
    }

    /// Reads a setup leniently: a missing action is none, and a delay outside ``HotCornerSettings/delayOptions`` (or
    /// missing) snaps to the nearest option (0.15 s when missing).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func action(_ key: CodingKeys) -> HotCornerAction {
            (try? container.decodeIfPresent(HotCornerAction.self, forKey: key)) ?? HotCornerAction.none
        }
        let delay = (try? container.decodeIfPresent(Double.self, forKey: .delay)) ?? 0.15
        self.init(
            delay: HotCornerSettings.nearestDelay(to: delay), plain: action(.plain), command: action(.command),
            option: action(.option), control: action(.control), shift: action(.shift))
    }
}

extension HotCornerSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, topLeft, topRight, bottomLeft, bottomRight, glow
    }

    /// Reads the settings leniently: a missing or unreadable part takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func setup(_ key: CodingKeys) -> HotCornerSetup {
            (try? container.decodeIfPresent(HotCornerSetup.self, forKey: key)) ?? HotCornerSetup()
        }
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
            topLeft: setup(.topLeft), topRight: setup(.topRight), bottomLeft: setup(.bottomLeft),
            bottomRight: setup(.bottomRight),
            glow: (try? container.decodeIfPresent(HotCornerGlow.self, forKey: .glow)) ?? HotCornerGlow())
    }

    /// Returns the option of ``delayOptions`` nearest to a delay; the shorter one on a tie, Instant for a value that
    /// isn't a number.
    ///
    /// - Parameter seconds: the delay
    /// - Returns: one of ``delayOptions``
    public static func nearestDelay(to seconds: Double) -> Double {
        guard seconds.isFinite else {
            return delayOptions[0]
        }
        return delayOptions.min { abs($0 - seconds) < abs($1 - seconds) } ?? delayOptions[0]
    }

    /// the settings with every corner's delay snapped to one of ``delayOptions``
    public var snapped: HotCornerSettings {
        var settings = self
        for corner in HotCorner.allCases {
            settings[corner].delay = Self.nearestDelay(to: settings[corner].delay)
        }
        return settings
    }

    /// The settings as the JSON text the preferences keep, with sorted keys.
    ///
    /// - Returns: the text, or nil for the defaults, which are kept as nothing
    public var jsonText: String? {
        guard self != HotCornerSettings() else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Reads the JSON text of ``jsonText``; text that doesn't decode gives the defaults.
    ///
    /// - Parameter text: the stored text
    public init(jsonText text: String) {
        self = (try? JSONDecoder().decode(HotCornerSettings.self, from: Data(text.utf8))) ?? HotCornerSettings()
    }

    /// a short line for the log of a change, like "on, Top Left: Mission Control, ⌘ Lock Screen"
    public var summary: String {
        let corners = HotCorner.allCases.compactMap { corner -> String? in
            let setup = self[corner]
            let parts = ([nil] + HotCornerModifier.allCases.map(Optional.some)).compactMap { modifier -> String? in
                let action = setup[modifier]
                guard action != .none else { return nil }
                return (modifier.map { $0.symbol + " " } ?? "") + action.logText
            }
            return parts.isEmpty ? nil : "\(corner.title): \(parts.joined(separator: ", "))"
        }
        return ([enabled ? "on" : "off"] + corners).joined(separator: "; ")
    }
}

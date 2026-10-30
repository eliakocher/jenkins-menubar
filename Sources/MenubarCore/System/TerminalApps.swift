import CoreServices
import Foundation

/// A terminal app found on this Mac, and what it says it can open (WS-05, AI-05).
public struct TerminalApp: Hashable, Sendable, Identifiable {
    /// the bundle identifier, like `com.apple.Terminal`
    public var id: String
    /// the name shown, like `cmux`
    public var name: String
    /// the app's folder
    public var url: URL
    /// whether it runs a `.command` script it is given: its Info.plist declares the script type as a shell's
    public var runsScripts: Bool
    /// whether it opens a folder it is given
    public var opensFolders: Bool

    public init(id: String, name: String, url: URL, runsScripts: Bool, opensFolders: Bool) {
        self.id = id
        self.name = name
        self.url = url
        self.runsScripts = runsScripts
        self.opensFolders = opensFolders
    }

    /// Terminal's bundle identifier; the fallback of every choice
    public static let terminalID = "com.apple.Terminal"

    /// the terminals the picker looks for, by bundle identifier, never by path
    public static let knownIDs = [
        terminalID, "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.cmuxterm.app",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    /// Terminal itself, for when the directory doesn't find it.
    static let systemTerminal = TerminalApp(
        id: terminalID, name: "Terminal", url: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
        runsScripts: true, opensFolders: true)

    /// the content types of a `.command` file, from the most to the least specific
    private static let scriptTypes: Set<String> = ["com.apple.terminal.shell-script", "public.shell-script"]

    /// Reads what an app declares it can open from its Info.plist: a script counts when a document type with the Shell
    /// role (or, for a known terminal, any role but Editor) lists the shell script type or the `command` extension;
    /// a folder counts when a document type lists `public.folder`.
    ///
    /// - Parameters:
    ///   - info: the Info.plist
    ///   - isKnown: whether the app is one of the ``knownIDs``
    /// - Returns: whether it runs scripts, and whether it opens folders
    public static func capabilities(of info: [String: Any], isKnown: Bool) -> (runsScripts: Bool, opensFolders: Bool) {
        var scripts = false
        var folders = false
        for entry in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            let types = Set(entry["LSItemContentTypes"] as? [String] ?? [])
            let extensions = Set((entry["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() })
            let role = entry["CFBundleTypeRole"] as? String
            let roleFits = role == "Shell" || (isKnown && role != "Editor")
            if roleFits, !types.isDisjoint(with: scriptTypes) || extensions.contains("command") {
                scripts = true
            }
            if types.contains("public.folder") {
                folders = true
            }
        }
        return (scripts, folders)
    }
}

/// Finds terminals on this Mac. The system's answers come from Launch Services and the apps' Info.plists, and never
/// start an app; the tests give their own.
public protocol TerminalDirectory: Sendable {
    /// Returns the app with a bundle identifier, when it is installed.
    func app(bundleID: String) -> TerminalApp?

    /// Returns the app Launch Services opens `.command` files with, the closest thing macOS has to a default terminal.
    func scriptHandler() -> TerminalApp?
}

extension TerminalDirectory {
    /// Returns the known terminals that are installed and can open a script or a folder, Terminal first.
    public func installedTerminals() -> [TerminalApp] {
        TerminalApp.knownIDs.compactMap(app(bundleID:)).filter { $0.runsScripts || $0.opensFolders }
    }
}

/// The directory of this Mac.
public struct SystemTerminalDirectory: TerminalDirectory {
    public init() {}

    public func app(bundleID: String) -> TerminalApp? {
        let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]
        return urls?.first.flatMap(Self.app(at:))
    }

    public func scriptHandler() -> TerminalApp? {
        LSCopyDefaultApplicationURLForContentType("com.apple.terminal.shell-script" as CFString, .all, nil)
            .flatMap { Self.app(at: $0.takeRetainedValue() as URL) }
    }

    private static func app(at url: URL) -> TerminalApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            return nil
        }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        if id == TerminalApp.terminalID {
            return TerminalApp(id: id, name: name, url: url, runsScripts: true, opensFolders: true)
        }
        let found = TerminalApp.capabilities(of: info, isKnown: TerminalApp.knownIDs.contains(id))
        return TerminalApp(id: id, name: name, url: url, runsScripts: found.runsScripts, opensFolders: found.opensFolders)
    }
}

/// What the terminal opens: a folder (Open in Terminal) or a script (Open in Claude Code).
public enum TerminalTask: Hashable, Sendable {
    case folder
    case script

    /// what the terminal can't do, for a note like "cmux can't run a script"
    fileprivate var cannot: String {
        switch self {
        case .folder: "open a folder"
        case .script: "run a script"
        }
    }
}

/// The terminal Open in Terminal and Open in Claude Code use: the one chosen in Settings → Repositories, else the one
/// that opens `.command` files; Terminal when that one isn't there or can't do the task, with the reason.
public struct TerminalChoice: Hashable, Sendable {
    public var app: TerminalApp
    /// why it isn't the terminal asked for, like "cmux isn't installed"; `nil` when it is
    public var note: String?

    /// the preferences' key of the chosen bundle identifier; none stored means Default
    public static let defaultsKey = "terminalApp"

    /// Reads the chosen terminal.
    ///
    /// - Parameter defaults: the preferences' suite
    /// - Returns: the bundle identifier; `nil` for Default
    public static func preferred(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Keeps the chosen terminal.
    ///
    /// - Parameters:
    ///   - id: the bundle identifier; `nil` for Default
    ///   - defaults: the preferences' suite
    public static func setPreferred(_ id: String?, in defaults: UserDefaults) {
        defaults.set(id, forKey: defaultsKey)
    }

    /// Chooses the terminal for a task.
    ///
    /// - Parameters:
    ///   - preferred: the chosen bundle identifier; `nil` for Default
    ///   - task: what it opens
    ///   - directory: where terminals are looked up
    /// - Returns: the app to open with, and why it isn't the one asked for
    public static func choose(preferred: String?, for task: TerminalTask, in directory: any TerminalDirectory) -> TerminalChoice {
        let fallback = directory.app(bundleID: TerminalApp.terminalID) ?? .systemTerminal
        let asked: TerminalApp?
        let label: String
        if let preferred {
            asked = directory.app(bundleID: preferred)
            label = asked?.name ?? preferred
        } else {
            asked = directory.scriptHandler()
            label = asked.map { "the default (\($0.name))" } ?? "the default"
        }
        guard let asked else {
            return TerminalChoice(app: fallback, note: preferred == nil ? nil : "\(label) isn't installed")
        }
        let can = task == .script ? asked.runsScripts : asked.opensFolders
        return can ? TerminalChoice(app: asked, note: nil) : TerminalChoice(app: fallback, note: "\(label) can't \(task.cannot)")
    }

    /// Returns the `open` call that hands a folder or a script to the app: `open -a <app> <path>`. The app's path and
    /// the target are two arguments, never a shell string.
    ///
    /// - Parameter target: the checkout's folder, or the launch script
    /// - Returns: the arguments of `/usr/bin/open`
    public func openArguments(for target: String) -> [String] {
        ["-a", app.url.path(percentEncoded: false), target]
    }

    /// "Terminal", or "Terminal (cmux isn't installed)": where something opened, for a result line
    public var summary: String {
        note.map { "\(app.name) (\($0))" } ?? app.name
    }
}

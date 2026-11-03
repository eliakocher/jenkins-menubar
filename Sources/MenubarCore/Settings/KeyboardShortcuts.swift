import Foundation

/// One command whose keyboard shortcut the user can change in Settings → Shortcuts (KEYS-01): its id, its words, the
/// shortcut it has until the user records another, and the commands it may share a key with.
public struct ShortcutCommand: Hashable, Sendable, Identifiable {
    /// where the Shortcuts pane lists the command, in this order
    public enum Group: String, CaseIterable, Hashable, Sendable {
        case anywhere
        case window
        case sections
        case selection
        case builds
        case go
        case textSize
        case activity

        /// the pane's section header
        public var title: String {
            switch self {
            case .anywhere: "Anywhere"
            case .window: "Window"
            case .sections: "Sections"
            case .selection: "Selected Item"
            case .builds: "Builds"
            case .go: "Back and Forward"
            case .textSize: "Text Size"
            case .activity: "Activity"
            }
        }
    }

    /// the id the preferences keep the user's shortcut under; never changes once shipped
    public let id: String
    /// the menu item's name, in Title Style
    public let title: String
    /// one plain line on what it does where that isn't clear from the name
    public let detail: String?
    public let group: Group
    /// the shortcut it has until one is recorded; nil for none
    public let defaultShortcut: HotkeyShortcut?
    /// the commands that have the same key by default because they work in different places: only one of them is ever
    /// on offer in the menu at a time, so recording one of their keys isn't a conflict
    public let sharesKeyWith: Set<String>

    init(
        _ id: String, _ title: String, detail: String? = nil, in group: Group, default defaultShortcut: HotkeyShortcut? = nil,
        sharesKeyWith: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.defaultShortcut = defaultShortcut
        self.sharesKeyWith = sharesKeyWith
    }
}

/// Every command with a shortcut of its own, as the main window's menu bar has it, in the order of the Shortcuts pane.
public enum ShortcutCatalog {
    /// the id of the global hotkey, which `Preferences/globalShortcut` keeps; it isn't in the ``ShortcutMap``
    public static let globalID = "openAnywhere"

    /// the id of Toggle Sidebar
    public static let toggleSidebarID = "toggleSidebar"

    /// the id of the Nth section's command, counting from 1
    public static func sectionID(_ number: Int) -> String {
        "section\(number)"
    }

    /// The number of the section a command's id says.
    ///
    /// - Parameter id: a command id
    /// - Returns: the position, 1 to 9, or nil for another command
    public static func sectionNumber(of id: String) -> Int? {
        guard id.hasPrefix("section"), let number = Int(id.dropFirst("section".count)), (1...9).contains(number) else {
            return nil
        }
        return number
    }

    /// a key of the keyboard's ANSI layout, as the virtual key codes have them
    private static func key(_ code: UInt32, _ modifiers: HotkeyShortcut.Modifiers, _ label: String) -> HotkeyShortcut? {
        HotkeyShortcut(keyCode: code, modifiers: modifiers, label: label)
    }

    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// the commands, the global hotkey first
    public static let all: [ShortcutCommand] = {
        let cmd: HotkeyShortcut.Modifiers = .command
        var commands: [ShortcutCommand] = [
            ShortcutCommand(
                globalID, "Open MegaMonitor (anywhere)", detail: "From any app; press it again to hide the window",
                in: .anywhere),
            ShortcutCommand(
                toggleSidebarID, "Toggle Sidebar", detail: "Shows or hides the sidebar of the window you are in",
                in: .window, default: key(1, [.control, .command], "S")),
            ShortcutCommand(
                "toggleInspector", "Show or Hide Inspector", detail: "Activity's details", in: .window,
                default: key(34, [.control, .command], "I")),
            ShortcutCommand("find", "Find", detail: "Jumps to the search field", in: .window, default: key(3, cmd, "F")),
            ShortcutCommand(
                "newWorkItem", "New Work Item…", detail: "Opens GitLab's new issue page", in: .window, default: key(45, cmd, "N")),
            ShortcutCommand(
                "openByLink", "Open by Link…", detail: "A merge request or work item by its link", in: .window,
                default: key(31, [.command, .shift], "O")),
            ShortcutCommand(
                "openMainWindow", "Open the Main Window", detail: "From the Window menu, while another window is in front",
                in: .window, default: key(29, cmd, "0"), sharesKeyWith: ["actualSize"]),
        ]
        for number in 1...9 {
            commands.append(
                ShortcutCommand(
                    sectionID(number), "Show Section \(number)", detail: "The section in that place of the sidebar",
                    in: .sections, default: key(digitKeyCodes[number - 1], cmd, String(number))))
        }
        commands += [
            ShortcutCommand(
                "openSelected", "Open in Browser", detail: "In Workspaces it opens the checkout in your IDE or Finder",
                in: .selection, default: key(31, cmd, "O")),
            ShortcutCommand(
                "copyLink", "Copy Link", detail: "The selected item's link", in: .selection,
                default: key(8, [.command, .shift], "C")),
            ShortcutCommand(
                "closeOpened", "Close Opened Item", detail: "An item under Opened; with none, ⌘W closes the window",
                in: .selection, default: key(13, cmd, "W")),
            ShortcutCommand(
                "inboxDone", "Mark Inbox Item Done", detail: "Restores it in the Done list", in: .selection,
                default: key(51, cmd, "⌫"), sharesKeyWith: ["hideBuild"]),
            ShortcutCommand(
                "reload", "Reload the Section", detail: "Only the section you are in; Check Now does all of them",
                in: .builds, default: key(15, cmd, "R")),
            ShortcutCommand(
                "checkNow", "Check Now", detail: "While the main window is in front; without it, ⌘R", in: .builds,
                default: key(15, [.command, .shift], "R")),
            ShortcutCommand(
                "watchBuild", "Watch a Build…", detail: "A build by its link", in: .builds, default: key(37, cmd, "L")),
            ShortcutCommand(
                "watchMergeRequest", "Watch Builds of Merge Request", detail: "The selected merge request's builds",
                in: .builds, default: key(13, [.command, .shift], "W")),
            ShortcutCommand(
                "hideBuild", "Hide Build or Stop Watching", detail: "Hides the selected build until the next one; a watched build is stopped",
                in: .builds, default: key(51, cmd, "⌫"), sharesKeyWith: ["inboxDone"]),
            ShortcutCommand("showHiddenBuilds", "Show Hidden Builds", in: .builds),
            ShortcutCommand("allBuildsInJenkins", "All Builds in Jenkins", in: .builds),
            ShortcutCommand("back", "Back", detail: "⌘← and the mouse's back button always go back too", in: .go, default: key(33, cmd, "[")),
            ShortcutCommand(
                "forward", "Forward", detail: "⌘→ and the mouse's forward button always go forward too", in: .go,
                default: key(30, cmd, "]")),
            ShortcutCommand("biggerText", "Make Text Bigger", in: .textSize, default: key(24, cmd, "+")),
            ShortcutCommand("smallerText", "Make Text Smaller", in: .textSize, default: key(27, cmd, "-")),
            ShortcutCommand(
                "actualSize", "Actual Size", detail: "While the main window is in front", in: .textSize,
                default: key(29, cmd, "0"), sharesKeyWith: ["openMainWindow"]),
            ShortcutCommand("showInFinder", "Show Activity in Finder", in: .activity),
            ShortcutCommand("clearActivity", "Clear Activity…", in: .activity),
        ]
        return commands
    }()

    private static let byID: [String: ShortcutCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Returns a command by its id.
    ///
    /// - Parameter id: the command's id
    /// - Returns: the command, or nil for an id no command has, like one of a removed command
    public static func command(_ id: String) -> ShortcutCommand? {
        byID[id]
    }

    /// the commands of a group, in their order
    public static func commands(in group: ShortcutCommand.Group) -> [ShortcutCommand] {
        all.filter { $0.group == group }
    }
}

extension HotkeyShortcut {
    /// Returns whether two shortcuts are the same keys: the same key code and modifiers, whatever their labels say.
    public func isSameKey(as other: HotkeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// The user's shortcuts by command id, as Settings → Shortcuts changes them (KEYS-01).
///
/// It keeps only what differs from a command's default: a recorded shortcut, or a cleared one. A command without an entry
/// has its default, so a command a later version adds comes with its default and one that was removed is forgotten.
/// It is stored as JSON text in one key (``PreferencesStore/keyboardShortcutsKey``): a command id and its shortcut's
/// stored text, empty for a cleared one.
public struct ShortcutMap: Hashable, Sendable, Codable {
    private enum Override: Hashable, Sendable {
        case shortcut(HotkeyShortcut)
        case cleared
    }

    private var overrides: [String: Override]

    /// A map with every command at its default.
    public init() {
        overrides = [:]
    }

    /// whether every command has its default
    public var isEmpty: Bool {
        overrides.isEmpty
    }

    /// Returns the shortcut a command has now.
    ///
    /// - Parameter id: the command's id
    /// - Returns: the recorded shortcut, the command's default when none was recorded, or nil when it was cleared or has no
    ///   command
    public func shortcut(for id: String) -> HotkeyShortcut? {
        switch overrides[id] {
        case .shortcut(let shortcut)?: shortcut
        case .cleared?: nil
        case nil: ShortcutCatalog.command(id)?.defaultShortcut
        }
    }

    /// Returns whether the user changed a command's shortcut, to another or to none.
    public func isCustomized(_ id: String) -> Bool {
        overrides[id] != nil
    }

    /// Records a shortcut for a command, or clears it. A shortcut that is the command's default is no change, and clearing
    /// a command that has none is none; an id no command has is ignored.
    ///
    /// - Parameters:
    ///   - shortcut: the shortcut; nil clears it
    ///   - id: the command's id
    public mutating func set(_ shortcut: HotkeyShortcut?, for id: String) {
        guard let command = ShortcutCatalog.command(id), id != ShortcutCatalog.globalID else { return }
        switch (shortcut, command.defaultShortcut) {
        case (let shortcut?, let standard?) where shortcut.isSameKey(as: standard):
            overrides[id] = nil
        case (let shortcut?, _):
            overrides[id] = .shortcut(shortcut)
        case (nil, nil):
            overrides[id] = nil
        case (nil, _):
            overrides[id] = .cleared
        }
    }

    /// Gives a command its default again.
    public mutating func reset(_ id: String) {
        overrides[id] = nil
    }

    /// Gives every command its default again.
    public mutating func resetAll() {
        overrides = [:]
    }

    // MARK: Coding

    public init(from decoder: any Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([String: String].self)
        overrides = [:]
        for (id, text) in stored {
            // An id no command has is dropped, and so is text that isn't a shortcut: both read as the default.
            guard let command = ShortcutCatalog.command(id), id != ShortcutCatalog.globalID else { continue }
            if text.isEmpty {
                if command.defaultShortcut != nil {
                    overrides[id] = .cleared
                }
            } else if let shortcut = HotkeyShortcut(rawValue: text) {
                if let standard = command.defaultShortcut, shortcut.isSameKey(as: standard) {
                    continue
                }
                overrides[id] = .shortcut(shortcut)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var stored: [String: String] = [:]
        for (id, override) in overrides {
            switch override {
            case .shortcut(let shortcut): stored[id] = shortcut.rawValue
            case .cleared: stored[id] = ""
            }
        }
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }

    /// The map as the JSON text the preferences keep, with sorted keys.
    ///
    /// - Returns: the text, or nil for a map without changes
    public var jsonText: String? {
        guard !isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Reads the JSON text of ``jsonText``.
    ///
    /// - Parameter text: the stored text
    /// - Returns: the map; text that doesn't decode gives the defaults
    public init(jsonText text: String) {
        self = (try? JSONDecoder().decode(ShortcutMap.self, from: Data(text.utf8))) ?? ShortcutMap()
    }
}

/// Why a shortcut can't be taken as it is.
public enum ShortcutRefusal: Hashable, Sendable {
    /// macOS or text editing owns the keys; the text says what for, like "⌘Q is Quit's"
    case reserved(String)
    /// another command has the keys
    case usedBy(ShortcutCommand)

    /// the one-line text Settings shows, without an ending period
    public var message: String {
        switch self {
        case .reserved(let text): text
        case .usedBy(let command): "Used by \(command.title)"
        }
    }
}

/// The rules for recording a shortcut: the keys macOS keeps, and the keys another command already has (KEYS-02).
public enum ShortcutRules {
    /// who keeps a reserved key
    public enum Owner: Hashable, Sendable {
        /// a menu item or a feature of macOS
        case macOS(String)
        /// text editing, which every text field needs
        case textEditing(String)
        /// MegaMonitor itself, which answers these keys beside the menu
        case app(String)
    }

    /// the keys no command may take, with what has them
    public static let reserved: [(shortcut: HotkeyShortcut, owner: Owner)] = {
        let cmd: HotkeyShortcut.Modifiers = .command
        let entries: [(UInt32, HotkeyShortcut.Modifiers, String, Owner)] = [
            (12, cmd, "Q", .macOS("Quit")), (13, cmd, "W", .macOS("Close Window")), (4, cmd, "H", .macOS("Hide")),
            (4, [.command, .option], "H", .macOS("Hide Others")), (46, cmd, "M", .macOS("Minimize")),
            (43, cmd, ",", .macOS("Settings")), (49, cmd, "Space", .macOS("Spotlight")), (48, cmd, "⇥", .macOS("the app switcher")),
            (8, cmd, "C", .textEditing("Copy")), (9, cmd, "V", .textEditing("Paste")), (7, cmd, "X", .textEditing("Cut")),
            (0, cmd, "A", .textEditing("Select All")), (6, cmd, "Z", .textEditing("Undo")),
            (6, [.command, .shift], "Z", .textEditing("Redo")),
            (123, cmd, "←", .app("goes back")), (124, cmd, "→", .app("goes forward")),
        ]
        return entries.compactMap { code, modifiers, label, owner in
            HotkeyShortcut(keyCode: code, modifiers: modifiers, label: label).map { ($0, owner) }
        }
    }()

    /// Returns why the keys are reserved, if they are.
    ///
    /// - Parameter shortcut: the shortcut
    /// - Returns: the text, like "⌘Q is Quit's: macOS keeps it", or nil for keys that are free of macOS
    public static func reservedNote(for shortcut: HotkeyShortcut) -> String? {
        guard let entry = reserved.first(where: { $0.shortcut.isSameKey(as: shortcut) }) else { return nil }
        let keys = shortcut.display
        return switch entry.owner {
        case .macOS(let use): "\(keys) is \(use)'s: macOS keeps it"
        case .textEditing(let use): "\(keys) is \(use)'s: text fields need it"
        case .app(let use): "\(keys) always \(use) in MegaMonitor"
        }
    }
}

extension Preferences {
    /// Returns what keeps a shortcut from being a command's: macOS's own keys (a command may keep its own default, like
    /// Close Opened Item's ⌘W) and the other commands' keys, the global hotkey's too.
    ///
    /// - Parameters:
    ///   - shortcut: the shortcut to record
    ///   - id: the command that would have it
    /// - Returns: the refusal, or nil when the shortcut is free
    public func shortcutRefusal(of shortcut: HotkeyShortcut, for id: String) -> ShortcutRefusal? {
        let command = ShortcutCatalog.command(id)
        if let note = ShortcutRules.reservedNote(for: shortcut),
            !(command?.defaultShortcut.map { $0.isSameKey(as: shortcut) } ?? false)
        {
            return .reserved(note)
        }
        return shortcutOwner(of: shortcut, excluding: id).map(ShortcutRefusal.usedBy)
    }

    /// Returns the command that has the keys now.
    ///
    /// - Parameters:
    ///   - shortcut: the keys
    ///   - id: the command to leave out, which may keep them; commands that share its key by default are left out too
    /// - Returns: the first command that has them, or nil
    public func shortcutOwner(of shortcut: HotkeyShortcut, excluding id: String) -> ShortcutCommand? {
        let sharing = ShortcutCatalog.command(id)?.sharesKeyWith ?? []
        return ShortcutCatalog.all.first { command in
            guard command.id != id, !sharing.contains(command.id) else { return false }
            return self.shortcut(for: command.id)?.isSameKey(as: shortcut) == true
        }
    }

    /// Gives a command a shortcut, or clears it, and takes the keys from the command that had them. The global hotkey
    /// is the command with ``ShortcutCatalog/globalID``.
    ///
    /// - Parameters:
    ///   - shortcut: the shortcut; nil clears it
    ///   - id: the command's id
    public mutating func assign(_ shortcut: HotkeyShortcut?, to id: String) {
        if let shortcut, let owner = shortcutOwner(of: shortcut, excluding: id) {
            store(nil, for: owner.id)
        }
        store(shortcut, for: id)
    }

    private mutating func store(_ shortcut: HotkeyShortcut?, for id: String) {
        if id == ShortcutCatalog.globalID {
            globalShortcut = shortcut
        } else {
            shortcuts.set(shortcut, for: id)
        }
    }

    /// the shortcut a command has now, the global hotkey included
    public func shortcut(for id: String) -> HotkeyShortcut? {
        id == ShortcutCatalog.globalID ? globalShortcut : shortcuts.shortcut(for: id)
    }

    /// whether a command's shortcut differs from its default; the global hotkey's default is none
    public func isShortcutCustomized(_ id: String) -> Bool {
        id == ShortcutCatalog.globalID ? globalShortcut != nil : shortcuts.isCustomized(id)
    }
}

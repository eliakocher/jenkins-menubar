import Foundation
import Testing

@testable import MenubarCore

@Suite("Keyboard shortcuts")
struct KeyboardShortcutsTests {
    private static func shortcut(_ code: UInt32, _ modifiers: HotkeyShortcut.Modifiers, _ label: String) -> HotkeyShortcut {
        HotkeyShortcut(keyCode: code, modifiers: modifiers, label: label)!
    }

    private static let commandS = shortcut(1, [.command], "S")
    private static let commandF = shortcut(3, [.command], "F")
    private static let commandK = shortcut(40, [.command], "K")

    @Test("KEYS-01 every command has a unique id, and no two share a default key except the ones that say so")
    func catalogIsConsistent() {
        let ids = ShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == ShortcutCatalog.globalID)
        for (index, first) in ShortcutCatalog.all.enumerated() {
            for second in ShortcutCatalog.all[(index + 1)...] {
                guard let one = first.defaultShortcut, let two = second.defaultShortcut, one.isSameKey(as: two) else {
                    continue
                }
                #expect(first.sharesKeyWith.contains(second.id) && second.sharesKeyWith.contains(first.id), "\(first.id) \(second.id)")
            }
        }
    }

    @Test("KEYS-01 a command has its default until one is recorded, and Toggle Sidebar's is ⌃⌘S")
    func defaultsApply() {
        var map = ShortcutMap()
        #expect(map.shortcut(for: ShortcutCatalog.toggleSidebarID)?.display == "⌃⌘S")
        #expect(map.shortcut(for: "forward")?.display == "⌘]")
        #expect(map.shortcut(for: "showHiddenBuilds") == nil)
        map.set(Self.commandS, for: ShortcutCatalog.toggleSidebarID)
        #expect(map.shortcut(for: ShortcutCatalog.toggleSidebarID) == Self.commandS)
        #expect(map.isCustomized(ShortcutCatalog.toggleSidebarID))
        map.set(nil, for: "forward")
        #expect(map.shortcut(for: "forward") == nil)
        map.set(Self.commandK, for: "showHiddenBuilds")
        #expect(map.shortcut(for: "showHiddenBuilds") == Self.commandK)
        // Recording the default again, or clearing what has none, is no change.
        map.reset(ShortcutCatalog.toggleSidebarID)
        map.set(Self.shortcut(1, [.control, .command], "S"), for: ShortcutCatalog.toggleSidebarID)
        map.reset("forward")
        map.set(nil, for: "allBuildsInJenkins")
        map.reset("showHiddenBuilds")
        #expect(map.isEmpty)
    }

    @Test("KEYS-01 the stored map decodes what it can: new commands get their default, removed ones and garbage are dropped")
    func decodesRobustly() {
        let text = """
            {"toggleSidebar": "⌘S#1", "forward": "", "removedLongAgo": "⌘K#40", "find": "not a shortcut", \
            "back": "⌘[#33", "openAnywhere": "⌘K#40", "newCommandOfALaterVersion": "⌘K#40"}
            """
        let map = ShortcutMap(jsonText: text)
        #expect(map.shortcut(for: ShortcutCatalog.toggleSidebarID) == Self.commandS)
        #expect(map.shortcut(for: "forward") == nil)
        // Garbage reads as the default; so does a shortcut that is the default.
        #expect(map.shortcut(for: "find")?.display == "⌘F")
        #expect(!map.isCustomized("find"))
        #expect(!map.isCustomized("back"))
        // The global hotkey isn't in the map, and unknown ids are gone.
        #expect(!map.isCustomized(ShortcutCatalog.globalID))
        #expect(!map.isCustomized("removedLongAgo"))
        #expect(map.jsonText == #"{"forward":"","toggleSidebar":"⌘S#1"}"#)
        #expect(ShortcutMap(jsonText: "[1, 2").isEmpty)
        #expect(ShortcutMap(jsonText: "{\"find\": 3}").isEmpty)
    }

    @Test("KEYS-01 the shortcuts are kept in the preferences, absent while they are the defaults, and read back")
    func savedInPreferences() throws {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        var preferences = store.load()
        #expect(preferences.shortcuts.isEmpty)
        preferences.shortcuts.set(Self.commandS, for: ShortcutCatalog.toggleSidebarID)
        store.save(preferences)
        #expect(suite.defaults.string(forKey: PreferencesStore.keyboardShortcutsKey) == #"{"toggleSidebar":"⌘S#1"}"#)
        #expect(store.load().shortcuts.shortcut(for: ShortcutCatalog.toggleSidebarID) == Self.commandS)
        // New and removed commands: what the file says about them can't break the load.
        suite.defaults.set(#"{"toggleSidebar":"⌘S#1","gone":"⌘K#40"}"#, forKey: PreferencesStore.keyboardShortcutsKey)
        #expect(store.load().shortcuts.shortcut(for: "find")?.display == "⌘F")
        preferences.shortcuts.resetAll()
        store.save(preferences)
        #expect(suite.defaults.object(forKey: PreferencesStore.keyboardShortcutsKey) == nil)
        // It is part of a backup of the personal settings.
        #expect(PersonalSettingsBackup.allowlist.contains { $0.key == PreferencesStore.keyboardShortcutsKey && $0.type == .string })
    }

    @Test("KEYS-02 a shortcut another command has is refused with that command's name, and Replace takes it over")
    func conflictsAreFound() {
        var preferences = Preferences()
        let refusal = preferences.shortcutRefusal(of: Self.commandF, for: ShortcutCatalog.toggleSidebarID)
        #expect(refusal?.message == "Used by Find")
        // Its own keys, and keys nobody has, are free.
        #expect(preferences.shortcutRefusal(of: Self.commandF, for: "find") == nil)
        #expect(preferences.shortcutRefusal(of: Self.commandS, for: ShortcutCatalog.toggleSidebarID) == nil)
        // The global hotkey counts too, from both sides.
        preferences.globalShortcut = Self.commandK
        #expect(preferences.shortcutRefusal(of: Self.commandK, for: "find")?.message == "Used by Open MegaMonitor (anywhere)")
        #expect(preferences.shortcutRefusal(of: Self.commandF, for: ShortcutCatalog.globalID)?.message == "Used by Find")
        // Replace: the new owner has the keys, the old one has none.
        preferences.assign(Self.commandF, to: ShortcutCatalog.toggleSidebarID)
        #expect(preferences.shortcut(for: ShortcutCatalog.toggleSidebarID) == Self.commandF)
        #expect(preferences.shortcut(for: "find") == nil)
        preferences.assign(Self.commandK, to: "reload")
        #expect(preferences.globalShortcut == nil)
        #expect(preferences.shortcut(for: "reload") == Self.commandK)
    }

    @Test("KEYS-02 commands that work in different places may keep the same key")
    func sharedKeysAreNoConflict() {
        let preferences = Preferences()
        let zero = Self.shortcut(29, [.command], "0")
        #expect(preferences.shortcutRefusal(of: zero, for: "actualSize") == nil)
        #expect(preferences.shortcutRefusal(of: zero, for: "openMainWindow") == nil)
        #expect(preferences.shortcutRefusal(of: Self.shortcut(51, [.command], "⌫"), for: "inboxDone") == nil)
        // Another command can't take it without saying whose it is.
        #expect(preferences.shortcutRefusal(of: zero, for: "find") != nil)
    }

    private static let reservedKeys: [(UInt32, HotkeyShortcut.Modifiers, String)] = [
        (12, .command, "Q"), (13, .command, "W"), (4, .command, "H"), (46, .command, "M"), (43, .command, ","),
        (8, .command, "C"), (9, .command, "V"), (6, [.command, .shift], "Z"), (123, .command, "←"),
    ]

    @Test("KEYS-03 the keys macOS and text fields keep are refused", arguments: reservedKeys.indices)
    func reservedKeysAreRefused(_ index: Int) throws {
        let (code, modifiers, label) = Self.reservedKeys[index]
        let keys = try #require(HotkeyShortcut(keyCode: code, modifiers: modifiers, label: label))
        let preferences = Preferences()
        for id in ["find", ShortcutCatalog.toggleSidebarID, ShortcutCatalog.globalID] {
            guard case .reserved(let note)? = preferences.shortcutRefusal(of: keys, for: id) else {
                Issue.record("\(keys.display) for \(id) wasn't refused as reserved")
                return
            }
            #expect(note.contains(keys.display))
        }
        #expect(ShortcutRules.reservedNote(for: keys) != nil)
    }

    @Test("KEYS-03 a command keeps its own default even when macOS has it too: Close Opened Item's ⌘W")
    func ownDefaultIsAllowed() {
        let preferences = Preferences()
        let commandW = Self.shortcut(13, [.command], "W")
        #expect(preferences.shortcutRefusal(of: commandW, for: "closeOpened") == nil)
        #expect(preferences.shortcutRefusal(of: commandW, for: "find") != nil)
        // ⌥⌘H and ⇧⌘W aren't ⌘H and ⌘W.
        #expect(preferences.shortcutRefusal(of: Self.shortcut(4, [.command, .option], "H"), for: "find") != nil)
        #expect(preferences.shortcutRefusal(of: Self.shortcut(13, [.command, .shift], "W"), for: "watchMergeRequest") == nil)
        #expect(ShortcutRules.reservedNote(for: Self.commandS) == nil)
    }

    @Test("KEYS-01 the Nth section's command id round-trips, and only 1 to 9 are sections")
    func sectionIDs() {
        for number in 1...9 {
            #expect(ShortcutCatalog.sectionNumber(of: ShortcutCatalog.sectionID(number)) == number)
            #expect(ShortcutCatalog.command(ShortcutCatalog.sectionID(number))?.defaultShortcut?.display == "⌘\(number)")
        }
        #expect(ShortcutCatalog.sectionNumber(of: "section10") == nil)
        #expect(ShortcutCatalog.sectionNumber(of: "find") == nil)
    }
}

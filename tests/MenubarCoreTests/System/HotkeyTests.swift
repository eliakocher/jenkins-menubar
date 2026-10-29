import Foundation
import Testing

@testable import MenubarCore

@Suite("Global hotkey")
@MainActor
struct HotkeyTests {
    private static let ctrlOptCmdK = HotkeyShortcut(keyCode: 40, modifiers: [.control, .option, .command], label: "k")!

    @Test("APP-08 a shortcut needs ⌘, ⌃ or ⌥")
    func needsAModifier() {
        #expect(HotkeyShortcut(keyCode: 40, modifiers: [], label: "K") == nil)
        #expect(HotkeyShortcut(keyCode: 40, modifiers: [.shift], label: "K") == nil)
        #expect(HotkeyShortcut(keyCode: 40, modifiers: [.command], label: "K") != nil)
        #expect(HotkeyShortcut(keyCode: 40, modifiers: [.control, .shift], label: "K") != nil)
        #expect(HotkeyShortcut(keyCode: 40, modifiers: [.option], label: "K") != nil)
    }

    @Test("APP-08 a shortcut round-trips through its stored text")
    func roundTrip() throws {
        let shortcut = Self.ctrlOptCmdK
        #expect(shortcut.display == "⌃⌥⌘K")
        #expect(shortcut.rawValue == "⌃⌥⌘K#40")
        #expect(HotkeyShortcut(rawValue: shortcut.rawValue) == shortcut)
        #expect(HotkeyShortcut(rawValue: shortcut.rawValue)?.keyCode == 40)
        #expect(HotkeyShortcut(rawValue: shortcut.rawValue)?.modifiers == [.control, .option, .command])

        // Keys with a name of their own, and one whose label is the stored separator.
        let space = try #require(HotkeyShortcut(keyCode: 49, modifiers: [.command, .shift], label: " "))
        #expect(space.display == "⇧⌘Space")
        #expect(HotkeyShortcut(rawValue: space.rawValue) == space)
        let hash = try #require(HotkeyShortcut(keyCode: 20, modifiers: [.command], label: "#"))
        #expect(HotkeyShortcut(rawValue: hash.rawValue) == hash)

        // Carbon's modifier values, which RegisterEventHotKey takes as they are.
        #expect(shortcut.modifiers.rawValue == 256 | 2048 | 4096)

        let encoded = try JSONEncoder().encode(Preferences(globalShortcut: shortcut))
        #expect(try JSONDecoder().decode(Preferences.self, from: encoded).globalShortcut == shortcut)
        // A value encoded before the field existed decodes with none.
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).globalShortcut == nil)
    }

    @Test("APP-08 the shortcut is saved, logged and read back with the preferences")
    func savedLoggedAndRead() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        #expect(store.load().globalShortcut == nil)

        var preferences = Preferences()
        preferences.globalShortcut = Self.ctrlOptCmdK
        let saved = store.save(preferences)
        #expect(saved == [.init(key: .globalShortcut, old: "none", new: "⌃⌥⌘K")])
        #expect(store.load().globalShortcut == Self.ctrlOptCmdK)
        #expect(store.save(preferences).isEmpty)

        preferences.globalShortcut = nil
        #expect(store.save(preferences) == [.init(key: .globalShortcut, old: "⌃⌥⌘K", new: "none")])
        #expect(store.load().globalShortcut == nil)
    }

    @Test("APP-08 stored text that isn't a shortcut reads as none")
    func garbageReadsAsNone() {
        let suite = TemporaryDefaults()
        let store = PreferencesStore(defaults: suite.defaults)
        for text in ["", "K", "⌘K", "⌘K#x", "⇧K#40", "#40", "K#40"] {
            suite.defaults.set(text, forKey: PreferencesStore.Key.globalShortcut.rawValue)
            #expect(store.load().globalShortcut == nil, "\(text)")
        }
        suite.defaults.set(7, forKey: PreferencesStore.Key.globalShortcut.rawValue)
        #expect(store.load().globalShortcut == nil)
    }

    @Test("APP-08 registers at launch, on a change, and removes it on none and on quit")
    func registers() {
        let registrar = FakeHotkeyRegistrar()
        let hotkey = GlobalHotkey(registrar: registrar)
        #expect(hotkey.status == .off)

        hotkey.apply(nil)
        #expect(registrar.current == nil)

        hotkey.apply(Self.ctrlOptCmdK)
        #expect(registrar.current == Self.ctrlOptCmdK)
        #expect(hotkey.status == .active(Self.ctrlOptCmdK))

        // Another preference changing registers nothing again.
        hotkey.apply(Self.ctrlOptCmdK)
        #expect(registrar.registered == [Self.ctrlOptCmdK])

        let other = HotkeyShortcut(keyCode: 49, modifiers: [.command, .shift], label: " ")!
        hotkey.apply(other)
        #expect(registrar.current == other)

        hotkey.apply(nil)
        #expect(registrar.current == nil)
        #expect(hotkey.status == .off)

        hotkey.apply(other)
        hotkey.stop()
        #expect(registrar.current == nil)
        #expect(hotkey.status == .off)
    }

    @Test("APP-08 a shortcut that is taken shows why, and is tried again")
    func taken() {
        let registrar = FakeHotkeyRegistrar()
        registrar.error = .taken
        let hotkey = GlobalHotkey(registrar: registrar)
        var logged: [String] = []
        hotkey.onFailure = { logged.append($0) }

        hotkey.apply(Self.ctrlOptCmdK)
        #expect(hotkey.status == .failed(Self.ctrlOptCmdK, .taken))
        #expect(hotkey.status.problem == "⌃⌥⌘K is already used by another app or by macOS. Pick another shortcut.")
        #expect(logged.count == 1)

        // The next preference change tries again, and says nothing more while it still fails.
        hotkey.apply(Self.ctrlOptCmdK)
        #expect(logged.count == 1)

        registrar.error = nil
        hotkey.apply(Self.ctrlOptCmdK)
        #expect(hotkey.status == .active(Self.ctrlOptCmdK))
        #expect(hotkey.status.problem == nil)

        registrar.error = .refused(-9868)
        hotkey.apply(nil)
        hotkey.apply(Self.ctrlOptCmdK)
        #expect(hotkey.status.problem == "macOS didn't accept ⌃⌥⌘K (error -9868). Pick another shortcut.")
    }

    @Test("APP-08 a press reaches the app")
    func press() {
        let registrar = FakeHotkeyRegistrar()
        let hotkey = GlobalHotkey(registrar: registrar)
        var presses = 0
        hotkey.onPress = { presses += 1 }

        registrar.press()
        #expect(presses == 0)
        hotkey.apply(Self.ctrlOptCmdK)
        registrar.press()
        registrar.press()
        #expect(presses == 2)
        hotkey.stop()
        registrar.press()
        #expect(presses == 2)
    }
}

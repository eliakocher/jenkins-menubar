import MenubarCore
import SwiftUI
import Testing

@testable import MenubarUI

@Suite("Keyboard shortcut bridge")
struct KeyboardShortcutBridgeTests {
    private static let cases: [(HotkeyShortcut, KeyEquivalent?, EventModifiers)] = [
        (HotkeyShortcut(keyCode: 1, modifiers: [.command], label: "S")!, "s", .command),
        (HotkeyShortcut(keyCode: 1, modifiers: [.control, .command], label: "S")!, "s", [.control, .command]),
        (HotkeyShortcut(keyCode: 51, modifiers: [.command], label: "⌫")!, .delete, .command),
        (HotkeyShortcut(keyCode: 123, modifiers: [.command, .option], label: "←")!, .leftArrow, [.command, .option]),
        // A recorded ⇧⌘[ says `{`, and a menu item has the key unshifted.
        (HotkeyShortcut(keyCode: 33, modifiers: [.command, .shift], label: "{")!, "[", [.command, .shift]),
        (HotkeyShortcut(keyCode: 24, modifiers: [.command], label: "+")!, "+", .command),
        (HotkeyShortcut(keyCode: 96, modifiers: [.command], label: "F5")!, KeyEquivalent(Character(Unicode.Scalar(0xF708)!)), .command),
    ]

    @Test("KEYS-01 a recorded shortcut becomes the menu item's key equivalent and modifiers", arguments: cases.indices)
    func keyEquivalents(_ index: Int) {
        let (shortcut, key, modifiers) = Self.cases[index]
        #expect(shortcut.keyEquivalent == key, "\(shortcut.display)")
        #expect(shortcut.eventModifiers == modifiers, "\(shortcut.display)")
    }

    @Test("KEYS-01 every default shortcut has a key equivalent")
    func defaultsConvert() {
        for command in ShortcutCatalog.all {
            if let shortcut = command.defaultShortcut {
                #expect(shortcut.keyboardShortcut != nil, "\(command.id)")
            }
        }
    }
}

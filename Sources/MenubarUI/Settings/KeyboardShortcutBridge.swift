import MenubarCore
import SwiftUI

/// What SwiftUI needs to run a recorded shortcut: a key equivalent and modifiers for a menu item, and the check a key
/// press of a view makes (KEYS-01).
extension HotkeyShortcut {
    /// The keys on the keyboard's number row and next to the letters, as they read without Shift, by virtual key code. A
    /// menu item's key equivalent is the key unshifted, and a recorded ⇧⌘[ says `{`.
    private static let unshifted: [UInt32: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 33: "[", 30: "]", 39: "'", 41: ";", 42: "\\", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    /// The keys with a name of their own, which SwiftUI spells as `KeyEquivalent` constants.
    private static let named: [UInt32: KeyEquivalent] = [
        36: .return, 48: .tab, 49: .space, 51: .delete, 117: .deleteForward, 123: .leftArrow, 124: .rightArrow,
        125: .downArrow, 126: .upArrow, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
    ]

    /// the function keys F1 to F20 by virtual key code, in AppKit's private-use characters (`NSF1FunctionKey` on)
    private static let functionKeys: [UInt32: UInt32] = {
        let codes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($0.element, 0xF704 + UInt32($0.offset)) })
    }()

    /// the key as a menu item has it; nil for a key that has no equivalent, like the keypad's Enter
    var keyEquivalent: KeyEquivalent? {
        if let key = Self.named[keyCode] {
            return key
        }
        if let scalar = Self.functionKeys[keyCode].flatMap(Unicode.Scalar.init) {
            return KeyEquivalent(Character(scalar))
        }
        if modifiers.contains(.shift), let key = Self.unshifted[keyCode] {
            return KeyEquivalent(key)
        }
        guard label.count == 1, let character = label.lowercased().first else {
            return nil
        }
        return KeyEquivalent(character)
    }

    /// the modifiers as SwiftUI has them
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// the shortcut as a menu item's `.keyboardShortcut`; nil without a key equivalent
    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: eventModifiers) }
    }

    /// Returns whether a key press of a view is this shortcut. ⌘⌫ also takes forward delete, as the Inbox's Done always did.
    func matches(_ press: SwiftUI.KeyPress) -> Bool {
        guard press.modifiers.intersection([.command, .shift, .option, .control]) == eventModifiers else {
            return false
        }
        if let key = keyEquivalent, press.key == key {
            return true
        }
        return keyCode == 51 && press.key == .deleteForward
    }
}

extension ShortcutMap {
    /// the shortcut of a command as a menu item has it; nil for a command without one
    func keyboardShortcut(_ id: String) -> KeyboardShortcut? {
        shortcut(for: id)?.keyboardShortcut
    }
}

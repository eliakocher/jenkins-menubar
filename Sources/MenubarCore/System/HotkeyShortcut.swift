import Foundation

/// A keyboard shortcut for the global hotkey (APP-08): a key and the modifiers held with it.
///
/// It is stored as one readable string, `⌃⌥⌘K#40`: the modifiers in the order macOS shows them, the key's label, `#`
/// and the key code. The key code is what registers the hotkey and doesn't change with the keyboard layout; the label
/// is only what Settings and the log show, taken from the key as it was typed.
public struct HotkeyShortcut: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The modifier keys. The raw values are Carbon's (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), which
    /// `RegisterEventHotKey` takes as they are, so the app target needs no conversion.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)

        /// the modifiers as macOS shows them: ⌃⌥⇧⌘
        public var symbols: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }
    }

    /// the virtual key code, which doesn't depend on the keyboard layout
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// the key as it looks, like `K`, `Space` or `F5`
    public let label: String

    /// Makes a shortcut, which needs ⌘, ⌃ or ⌥: with Shift alone, or no modifier, every typed capital or plain key
    /// would open the window.
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code
    ///   - modifiers: the modifiers held
    ///   - label: the key's label; empty makes one from the key code
    /// - Returns: the shortcut; nil when it has none of ⌘, ⌃ and ⌥
    public init?(keyCode: UInt32, modifiers: Modifiers, label: String) {
        guard !modifiers.isDisjoint(with: Self.required) else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowed)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = Self.specialKeys[keyCode] ?? (trimmed.isEmpty ? "Key \(keyCode)" : trimmed.uppercased())
    }

    /// the modifiers of which a shortcut needs at least one
    public static let required: Modifiers = [.command, .control, .option]
    private static let allowed: Modifiers = [.command, .control, .option, .shift]

    /// the shortcut in macOS's symbols, like ⌃⌥⌘K
    public var display: String {
        modifiers.symbols + label
    }

    public var description: String { display }

    /// the stored string, like `⌃⌥⌘K#40`
    public var rawValue: String {
        "\(display)#\(keyCode)"
    }

    /// Reads a stored string.
    ///
    /// - Parameter rawValue: what ``rawValue`` made
    /// - Returns: the shortcut; nil for text that isn't one, or one without ⌘, ⌃ or ⌥
    public init?(rawValue: String) {
        guard let hash = rawValue.lastIndex(of: "#"), let code = UInt32(rawValue[rawValue.index(after: hash)...]) else {
            return nil
        }
        var modifiers: Modifiers = []
        var rest = rawValue[..<hash]
        while let first = rest.first, let modifier = Self.symbolModifiers[first] {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        self.init(keyCode: code, modifiers: modifiers, label: String(rest))
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let shortcut = HotkeyShortcut(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a shortcut: \(raw)"))
        }
        self = shortcut
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let symbolModifiers: [Character: Modifiers] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    /// The keys whose label isn't a typed character, by virtual key code.
    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 76: "⌅",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]
}

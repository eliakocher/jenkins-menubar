import CoreGraphics
import Foundation

// The corner glow (HOT-12): when a hot corner fires, a soft light plays in that corner. These are the settings as data;
// MenubarUI draws the light and the app's panel shows it. Colors are data here: a preset, or an RGB hex text.

/// How the glow moves.
public enum HotCornerGlowStyle: String, Codable, CaseIterable, Hashable, Sendable {
    /// a soft bloom that fades
    case glow
    /// two beats
    case pulse
    /// rings that spread from the corner
    case ripple

    public var title: String {
        switch self {
        case .glow: "Glow"
        case .pulse: "Pulse"
        case .ripple: "Ripple"
        }
    }
}

/// How far the glow reaches into the screen.
public enum HotCornerGlowSize: String, Codable, CaseIterable, Hashable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// how far the glow reaches from the corner, in points
    public var points: Double {
        switch self {
        case .small: 200
        case .medium: 320
        case .large: 480
        }
    }
}

/// The glow's color: the system accent, a preset, or one of the user's own as RGB hex text.
public enum HotCornerGlowColor: Hashable, Sendable {
    case accent, blue, purple, pink, orange, green
    /// six hex digits, `RRGGBB`, without a `#`
    case custom(hex: String)

    /// the presets of the settings' swatches, in order
    public static let presets: [HotCornerGlowColor] = [.accent, .blue, .purple, .pink, .orange, .green]

    public var title: String {
        switch self {
        case .accent: "Accent"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .orange: "Orange"
        case .green: "Green"
        case .custom: "Custom"
        }
    }

    /// The color as one stored text: `accent`, a preset's name, or `#RRGGBB`.
    public var storedText: String {
        switch self {
        case .accent: "accent"
        case .blue: "blue"
        case .purple: "purple"
        case .pink: "pink"
        case .orange: "orange"
        case .green: "green"
        case .custom(let hex): "#" + hex
        }
    }

    /// Reads a stored text; one that is none of them is the accent.
    ///
    /// - Parameter storedText: the text of ``storedText``
    public init(storedText text: String) {
        switch text {
        case "accent": self = .accent
        case "blue": self = .blue
        case "purple": self = .purple
        case "pink": self = .pink
        case "orange": self = .orange
        case "green": self = .green
        default:
            if text.hasPrefix("#"), let hex = Self.normalizedHex(String(text.dropFirst())) {
                self = .custom(hex: hex)
            } else {
                self = .accent
            }
        }
    }

    /// Returns six upper-case hex digits for a text like `3366FF` or `#3366ff`.
    ///
    /// - Parameter text: the text
    /// - Returns: the digits, or nil when the text isn't six hex digits
    public static func normalizedHex(_ text: String) -> String? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return digits.uppercased()
    }

    /// The color's red, green and blue (0…1), or nil for the accent, which only the app knows.
    public var rgb: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .accent: nil
        case .blue: (0.20, 0.52, 1.00)
        case .purple: (0.62, 0.36, 0.98)
        case .pink: (1.00, 0.34, 0.62)
        case .orange: (1.00, 0.58, 0.16)
        case .green: (0.22, 0.84, 0.46)
        case .custom(let hex):
            Self.components(ofHex: hex)
        }
    }

    private static func components(ofHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let value = UInt32(hex, radix: 16), hex.count == 6 else {
            return nil
        }
        return (
            Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
        )
    }
}

extension HotCornerGlowColor: Codable {
    public init(from decoder: any Decoder) throws {
        let text = (try? decoder.singleValueContainer().decode(String.self)) ?? "accent"
        self.init(storedText: text)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedText)
    }
}

/// Settings → Hot Corners → Corner Glow: whether the light plays, in which color, how, and how far.
public struct HotCornerGlow: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var color: HotCornerGlowColor
    public var style: HotCornerGlowStyle
    public var size: HotCornerGlowSize
    /// how long the whole animation plays, in seconds, for every style; one of ``durationRange`` in steps of
    /// ``durationStep``
    public var duration: Double {
        didSet { duration = Self.snappedDuration(duration) }
    }
    /// the glow's overall opacity, within ``opacityRange``
    public var opacity: Double {
        didSet { opacity = Self.clampedOpacity(opacity) }
    }

    /// the seconds a slider offers
    public static let durationRange: ClosedRange<Double> = 0.4...2.0
    public static let durationStep = 0.1
    public static let defaultDuration = 0.9
    public static let opacityRange: ClosedRange<Double> = 0.2...1.0

    public init(
        enabled: Bool = true, color: HotCornerGlowColor = .accent, style: HotCornerGlowStyle = .glow,
        size: HotCornerGlowSize = .medium, duration: Double = defaultDuration, opacity: Double = 1
    ) {
        self.enabled = enabled
        self.color = color
        self.style = style
        self.size = size
        self.duration = Self.snappedDuration(duration)
        self.opacity = Self.clampedOpacity(opacity)
    }

    /// Returns a duration snapped to the nearest 0.1 s and clamped to 0.4…2.0 s; one that isn't a number is the default.
    ///
    /// - Parameter seconds: the duration
    public static func snappedDuration(_ seconds: Double) -> Double {
        guard seconds.isFinite else {
            return defaultDuration
        }
        let snapped = (seconds / durationStep).rounded() * durationStep
        // Tenths as whole numbers, so 0.7 stays 0.7 and not 0.7000000000000001.
        return (min(durationRange.upperBound, max(durationRange.lowerBound, snapped)) * 10).rounded() / 10
    }

    /// Returns an opacity clamped to 0.2…1.0; one that isn't a number is 1.
    ///
    /// - Parameter value: the opacity
    public static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        return min(opacityRange.upperBound, max(opacityRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, color, style, size, duration, opacity
    }

    /// Reads the glow leniently: a missing or unreadable part takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true,
            color: (try? container.decodeIfPresent(HotCornerGlowColor.self, forKey: .color)) ?? .accent,
            style: (try? container.decodeIfPresent(HotCornerGlowStyle.self, forKey: .style)) ?? .glow,
            size: (try? container.decodeIfPresent(HotCornerGlowSize.self, forKey: .size)) ?? .medium,
            duration: (try? container.decodeIfPresent(Double.self, forKey: .duration)) ?? Self.defaultDuration,
            opacity: (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1)
    }
}

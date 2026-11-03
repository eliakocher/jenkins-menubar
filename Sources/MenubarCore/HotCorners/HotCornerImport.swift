import Foundation

/// The one-time import of the old Hot Corners app's settings (HOT-08), from its `dev.kocher.HotCorners` defaults.
///
/// The old app kept one action per corner, its shortcut and delay, a global delay before the per-corner ones, and a
/// switch. What it didn't store, it read with its own fallbacks; the import uses the same ones, so the corners do what
/// they did.
public enum HotCornerImport {
    /// the key in the preferences' suite that marks the import as done, so it runs once
    public static let markerKey = "hotCornersImported"

    /// the old app's action of a corner it had none stored for
    static func legacyDefaultAction(of corner: HotCorner) -> HotCornerAction {
        switch corner {
        case .topLeft: .system(.missionControl)
        case .topRight: .system(.applicationWindows)
        case .bottomLeft: .system(.desktop)
        case .bottomRight: .system(.displaySleep)
        }
    }

    /// Returns the settings the old app's defaults stand for.
    ///
    /// - A missing or unknown action is the corner's default (top left Mission Control, top right Application Windows,
    ///   bottom left Desktop, bottom right Put Display to Sleep); `shortcut` without a name is none.
    /// - A missing delay is the global `delay`, then 0.15 s; each is rounded to the nearest option.
    /// - A missing `enabled` is on.
    ///
    /// - Parameter legacy: the old app's defaults, by key
    /// - Returns: the settings, with the old action as each corner's plain one
    public static func settings(from legacy: LegacyHotCornersDefaults) -> HotCornerSettings {
        var settings = HotCornerSettings(enabled: bool(legacy["enabled"]) ?? true)
        let globalDelay = number(legacy["delay"]) ?? 0.15
        for corner in HotCorner.allCases {
            let key = "corner.\(corner.rawValue)"
            let delay = number(legacy["\(key).delay"]) ?? globalDelay
            let action: HotCornerAction =
                switch legacy[key] as? String {
                case "none": .none
                case "missionControl": .system(.missionControl)
                case "appWindows": .system(.applicationWindows)
                case "showDesktop": .system(.desktop)
                case "displaySleep": .system(.displaySleep)
                case "shortcut":
                    (legacy["\(key).shortcut"] as? String).flatMap { $0.isEmpty ? nil : .runShortcut(name: $0) } ?? .none
                default: legacyDefaultAction(of: corner)
                }
            settings[corner] = HotCornerSetup(delay: HotCornerSettings.nearestDelay(to: delay), plain: action)
        }
        return settings
    }

    private static func number(_ value: (any Sendable)?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as Float: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func bool(_ value: (any Sendable)?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as Int: value != 0
        case let value as Double: value != 0
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }
}

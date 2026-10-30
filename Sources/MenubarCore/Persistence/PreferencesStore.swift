import Foundation

/// Reads and writes the ``Preferences`` in a UserDefaults suite, one key per value (SET-01).
///
/// The app passes its own defaults (`local.menubar-monitor`); tests pass a suite of their own. A stored value of the
/// wrong type, or outside the value's options, reads as the default.
public struct PreferencesStore: @unchecked Sendable {
    // UserDefaults is documented as thread-safe, but the SDK doesn't mark it Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// the suite the preferences live in, for what the app keeps beside them, like the pane Settings showed last
    public var userDefaults: UserDefaults {
        defaults
    }

    /// the UserDefaults key of ``welcomeCompleted``
    static let welcomeCompletedKey = "welcomeCompleted"

    /// Whether the welcome flow was finished or closed once (TEAM-03, IMP-03). A missing value reads as `false`, so
    /// the flow shows at first start. It isn't one of the ``Preferences``: Settings neither shows nor logs it.
    public var welcomeCompleted: Bool {
        get { defaults.bool(forKey: Self.welcomeCompletedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.welcomeCompletedKey) }
    }

    /// the UserDefaults key of ``notificationPolicy``
    static let notificationPolicyKey = "notificationPolicy"

    /// Which builds may alert (ALERT-09), kept as JSON in one key. It isn't one of the ``Preferences``: the pipeline's
    /// views change it from the lists, and Settings neither shows nor logs it. Text that doesn't decode reads as the
    /// default, which notifies for everything.
    public var notificationPolicy: NotificationPolicy {
        get {
            guard let text = defaults.string(forKey: Self.notificationPolicyKey),
                let policy = try? JSONDecoder().decode(NotificationPolicy.self, from: Data(text.utf8))
            else {
                return NotificationPolicy()
            }
            return policy
        }
        nonmutating set {
            if newValue == NotificationPolicy() {
                defaults.removeObject(forKey: Self.notificationPolicyKey)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(newValue), let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: Self.notificationPolicyKey)
            }
        }
    }

    /// The UserDefaults key of each value, which is also its name in the log (SET-01).
    public enum Key: String, CaseIterable, Sendable {
        case checkIntervalSeconds
        case hideSuccessfulAfter
        case hideFailedAfter
        case hidesMergedBuilds
        case alertStyle
        case stageAlerts
        case iconStyle
        case gitLabMaxAgeSeconds
        case workItemsScope
        case workItemsType
        case workItemsState
        case workItemsSort
        case workItemsLimit
        case workItemsWithLabels
        case workItemsWithoutLabels
        case workItemsLabelsMatch
        case showInMenuBar
        case fillInCopiedLink
        case globalShortcut
        case easterEggs
        case slotAlerts
    }

    /// A value that ``save(_:)`` changed, as text for the log: `on` and `off` for a switch, and a list joined with
    /// `, `. An empty value is empty text.
    public struct Change: Hashable, Sendable {
        public var key: Key
        public var old: String
        public var new: String

        public init(key: Key, old: String, new: String) {
            self.key = key
            self.old = old
            self.new = new
        }
    }

    /// Reads the preferences.
    ///
    /// - Returns: the stored values, with the default for any value that is missing, of the wrong type, or outside
    ///   its options
    public func load() -> Preferences {
        var preferences = Preferences()
        // A value of the wrong type, or a raw value that is no case, leaves the default in place.
        func read<Value>(_ key: Key, into path: WritableKeyPath<Preferences, Value>) {
            if let value = defaults.object(forKey: key.rawValue) as? Value {
                preferences[keyPath: path] = value
            }
        }
        func readRaw<Value: RawRepresentable>(_ key: Key, into path: WritableKeyPath<Preferences, Value>)
        where Value.RawValue == String {
            if let raw = defaults.object(forKey: key.rawValue) as? String, let value = Value(rawValue: raw) {
                preferences[keyPath: path] = value
            }
        }
        read(.checkIntervalSeconds, into: \.checkIntervalSeconds)
        readRaw(.hideSuccessfulAfter, into: \.hideSuccessfulAfter)
        readRaw(.hideFailedAfter, into: \.hideFailedAfter)
        read(.hidesMergedBuilds, into: \.hidesMergedBuilds)
        readRaw(.alertStyle, into: \.alertStyle)
        read(.stageAlerts, into: \.stageAlerts)
        readRaw(.iconStyle, into: \.iconStyle)
        read(.gitLabMaxAgeSeconds, into: \.gitLabMaxAgeSeconds)
        readRaw(.workItemsScope, into: \.workItems.scope)
        readRaw(.workItemsType, into: \.workItems.type)
        readRaw(.workItemsState, into: \.workItems.state)
        readRaw(.workItemsSort, into: \.workItems.sort)
        read(.workItemsLimit, into: \.workItems.limit)
        read(.workItemsWithLabels, into: \.workItems.withLabels)
        read(.workItemsWithoutLabels, into: \.workItems.withoutLabels)
        readRaw(.workItemsLabelsMatch, into: \.workItems.labelsMatch)
        read(.showInMenuBar, into: \.showInMenuBar)
        read(.fillInCopiedLink, into: \.fillInCopiedLink)
        read(.easterEggs, into: \.easterEggs)
        read(.slotAlerts, into: \.slotAlerts)
        // Text that isn't a shortcut, or one without ⌘, ⌃ or ⌥, reads as none.
        if let raw = defaults.object(forKey: Key.globalShortcut.rawValue) as? String {
            preferences.globalShortcut = HotkeyShortcut(rawValue: raw)
        }
        // A case that isn't one of the value's options is caught here.
        return Self.validated(preferences)
    }

    /// Writes the values that differ from the stored ones. A value outside its options is saved as the default.
    ///
    /// - Parameter preferences: the new preferences
    /// - Returns: the values that changed, in the order of ``Key``; empty when nothing changed
    @discardableResult
    public func save(_ preferences: Preferences) -> [Change] {
        let old = load()
        let new = Self.validated(preferences)
        var changes: [Change] = []
        for key in Key.allCases {
            let before = Self.stored(key, of: old)
            let after = Self.stored(key, of: new)
            guard before != after else { continue }
            defaults.set(after.object, forKey: key.rawValue)
            changes.append(Change(key: key, old: before.text, new: after.text))
        }
        return changes
    }

    private static func validated(_ preferences: Preferences) -> Preferences {
        let defaults = Preferences()
        var valid = preferences
        func check<Value: Equatable>(_ path: WritableKeyPath<Preferences, Value>, in options: [Value]) {
            if !options.contains(valid[keyPath: path]) {
                valid[keyPath: path] = defaults[keyPath: path]
            }
        }
        check(\.checkIntervalSeconds, in: Preferences.checkIntervalOptions)
        check(\.hideSuccessfulAfter, in: Preferences.hideSuccessfulOptions)
        check(\.hideFailedAfter, in: Preferences.hideFailedOptions)
        check(\.gitLabMaxAgeSeconds, in: Preferences.gitLabMaxAgeOptions)
        check(\.workItems.limit, in: WorkItemFilters.limitOptions)
        return valid
    }

    /// A value as UserDefaults keeps it.
    private enum Stored: Equatable {
        case int(Int)
        case bool(Bool)
        case string(String)
        case strings([String])
        /// the stored string of a shortcut, empty for none
        case shortcut(String)

        var object: Any {
            switch self {
            case .int(let value): value
            case .bool(let value): value
            case .string(let value): value
            case .strings(let value): value
            case .shortcut(let value): value
            }
        }

        var text: String {
            switch self {
            case .int(let value): String(value)
            case .bool(let value): value ? "on" : "off"
            case .string(let value): value
            case .strings(let value): value.joined(separator: ", ")
            case .shortcut(let value): HotkeyShortcut(rawValue: value)?.display ?? "none"
            }
        }
    }

    private static func stored(_ key: Key, of preferences: Preferences) -> Stored {
        let workItems = preferences.workItems
        return switch key {
        case .checkIntervalSeconds: .int(preferences.checkIntervalSeconds)
        case .hideSuccessfulAfter: .string(preferences.hideSuccessfulAfter.rawValue)
        case .hideFailedAfter: .string(preferences.hideFailedAfter.rawValue)
        case .hidesMergedBuilds: .bool(preferences.hidesMergedBuilds)
        case .alertStyle: .string(preferences.alertStyle.rawValue)
        case .stageAlerts: .bool(preferences.stageAlerts)
        case .iconStyle: .string(preferences.iconStyle.rawValue)
        case .gitLabMaxAgeSeconds: .int(preferences.gitLabMaxAgeSeconds)
        case .workItemsScope: .string(workItems.scope.rawValue)
        case .workItemsType: .string(workItems.type.rawValue)
        case .workItemsState: .string(workItems.state.rawValue)
        case .workItemsSort: .string(workItems.sort.rawValue)
        case .workItemsLimit: .int(workItems.limit)
        case .workItemsWithLabels: .strings(workItems.withLabels)
        case .workItemsWithoutLabels: .strings(workItems.withoutLabels)
        case .workItemsLabelsMatch: .string(workItems.labelsMatch.rawValue)
        case .showInMenuBar: .bool(preferences.showInMenuBar)
        case .fillInCopiedLink: .bool(preferences.fillInCopiedLink)
        case .globalShortcut: .shortcut(preferences.globalShortcut?.rawValue ?? "")
        case .easterEggs: .bool(preferences.easterEggs)
        case .slotAlerts: .bool(preferences.slotAlerts)
        }
    }
}

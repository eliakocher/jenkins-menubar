import Foundation

/// A file with the user's personal preferences, for a new Mac or a fresh start (SET-01): Settings → Advanced's
/// "Back up my settings".
///
/// It holds an allowlist of UserDefaults keys and nothing else. Tokens are in the Keychain, never in the defaults, and
/// the team values have the team file; window and UI state, the announced slot alerts, the link routing (which needs
/// macOS's own prompt) and the welcome flag stay on the Mac they belong to.
///
/// The file is JSON: `{"formatVersion": 1, "kind": "megamonitor-personal-settings", "exportedAt": "…", "values": {…}}`.
/// A value is a JSON boolean, number, string or list of strings; stored `Data` is `{"base64": "…"}`.
public enum PersonalSettingsBackup {
    /// the file's `kind`
    public static let kind = "megamonitor-personal-settings"
    /// the version of the file's layout; a file with a higher one is refused
    public static let formatVersion = 1

    /// The type a key's value has, which an import insists on.
    public enum ValueType: Sendable, Hashable {
        case bool, int, double, string, strings, data
    }

    /// One key of the allowlist.
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var type: ValueType

        public init(_ key: String, _ type: ValueType) {
            self.key = key
            self.type = type
        }
    }

    /// Every key a backup holds, the only ones an export reads and an import writes. Nothing secret belongs here.
    public static let allowlist: [Entry] = {
        let preferences: [Entry] = PreferencesStore.Key.allCases.map { key in
            Entry(key.rawValue, valueType(of: key))
        }
        return preferences + [
            // kept as JSON text by `PreferencesStore.notificationPolicy`
            Entry(PreferencesStore.notificationPolicyKey, .string),
            // the Inbox's routing, quiet hours and sound, as JSON text (`PreferencesStore.inboxNotificationsKey`)
            Entry(PreferencesStore.inboxNotificationsKey, .string),
            // what the menu bar shows: the item's parts and the pane's rows, as JSON text (APP-11)
            Entry(PreferencesStore.menuBarLayoutKey, .string),
            // the keyboard shortcuts the user changed, as JSON text (`PreferencesStore.keyboardShortcutsKey`, KEYS-01)
            Entry(PreferencesStore.keyboardShortcutsKey, .string),
            // `RepositorySettings`, `TerminalChoice` and `AISettings` (MCP choices, no secret) in their own keys
            Entry(RepositorySettings.defaultsKey, .data),
            Entry(TerminalChoice.defaultsKey, .string),
            Entry(AISettings.defaultsKey, .data),
            // The look: the UI module owns these keys (`@AppStorage` in MenubarUI), so they are strings here, as
            // `MenubarCore` doesn't import SwiftUI.
            Entry("layout.contentWidth", .string),
            Entry("layout.customContentWidth", .double),
            Entry("markdown.readingSizeStep", .int),
            Entry("mergeRequestDiffLayout", .string),
            Entry("changes.foldersOpen", .bool),
            Entry(CommentThreadOrder.sortKey, .string),
            Entry(CommentThreadOrder.openFirstKey, .bool),
            // the sidebar's order of the sections: link names joined by commas, empty is the default
            Entry(SectionOrder.key, .string),
        ]
    }()

    /// The type of a preference's value, as `PreferencesStore` stores it.
    private static func valueType(of key: PreferencesStore.Key) -> ValueType {
        switch key {
        case .checkIntervalSeconds, .gitLabMaxAgeSeconds, .workItemsLimit: .int
        case .hidesMergedBuilds, .stageAlerts, .showInMenuBar, .fillInCopiedLink, .easterEggs, .slotAlerts,
            .workItemsScopedValueOnly:
            .bool
        case .workItemsWithLabels, .workItemsWithoutLabels, .workItemsHideOnRows: .strings
        case .hideSuccessfulAfter, .hideFailedAfter, .alertStyle, .iconStyle, .workItemsScope, .workItemsType,
            .workItemsState, .workItemsSort, .workItemsLabelsMatch, .globalShortcut, .appearance, .funLevel:
            .string
        }
    }

    /// What an import did.
    public struct ImportResult: Sendable, Hashable {
        /// the keys it wrote, sorted
        public var keys: [String]

        public init(keys: [String]) {
            self.keys = keys
        }

        /// the number of values written
        public var count: Int { keys.count }
    }

    // MARK: - Export

    /// Reads the allowlisted values that are set.
    ///
    /// - Parameters:
    ///   - defaults: the preferences' suite
    ///   - now: the export's time
    /// - Returns: the file's JSON
    /// - Throws: the error of the JSON encoding
    public static func export(from defaults: UserDefaults, now: Date = Date()) throws -> Data {
        var values: [String: Any] = [:]
        for entry in allowlist {
            if let object = defaults.object(forKey: entry.key), let json = json(of: object, as: entry.type) {
                values[entry.key] = json
            }
        }
        let file: [String: Any] = [
            "formatVersion": formatVersion,
            "kind": kind,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "values": values,
        ]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes a backup file.
    ///
    /// - Parameters:
    ///   - defaults: the preferences' suite
    ///   - url: the file, which is replaced
    /// - Returns: the number of values in it
    /// - Throws: the error of writing the file
    @discardableResult
    public static func export(from defaults: UserDefaults, to url: URL, now: Date = Date()) throws -> Int {
        let data = try export(from: defaults, now: now)
        try data.write(to: url, options: .atomic)
        return exportedCount(data)
    }

    private static func exportedCount(_ data: Data) -> Int {
        let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (file?["values"] as? [String: Any])?.count ?? 0
    }

    // MARK: - Import

    /// Writes the allowlisted values of a backup, each only with the type it has; the rest of the file is ignored.
    ///
    /// - Parameters:
    ///   - data: the file's contents
    ///   - defaults: the preferences' suite
    /// - Returns: the keys written
    /// - Throws: a ``PersonalSettingsBackupError`` that says why the file was refused
    @discardableResult
    public static func importValues(from data: Data, into defaults: UserDefaults) throws -> ImportResult {
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            file["kind"] as? String == kind
        else {
            throw PersonalSettingsBackupError.notABackup
        }
        guard let version = (file["formatVersion"] as? NSNumber)?.intValue else {
            throw PersonalSettingsBackupError.notABackup
        }
        guard version <= formatVersion else {
            throw PersonalSettingsBackupError.newerFormat(version)
        }
        guard let values = file["values"] as? [String: Any] else {
            throw PersonalSettingsBackupError.notABackup
        }
        var written: [String] = []
        for entry in allowlist {
            if let json = values[entry.key], let object = object(of: json, as: entry.type) {
                defaults.set(object, forKey: entry.key)
                written.append(entry.key)
            }
        }
        return ImportResult(keys: written.sorted())
    }

    /// Reads a backup file and writes its values.
    ///
    /// - Parameters:
    ///   - url: the file
    ///   - defaults: the preferences' suite
    /// - Returns: the keys written
    /// - Throws: a ``PersonalSettingsBackupError``
    @discardableResult
    public static func importValues(from url: URL, into defaults: UserDefaults) throws -> ImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersonalSettingsBackupError.unreadable(error.localizedDescription)
        }
        return try importValues(from: data, into: defaults)
    }

    // MARK: - Values

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The JSON value of a stored one, or `nil` when it has another type than the key's.
    private static func json(of object: Any, as type: ValueType) -> Any? {
        switch type {
        case .bool:
            guard let number = object as? NSNumber, isBool(number) else { return nil }
            return number.boolValue
        case .int:
            guard let number = object as? NSNumber, !isBool(number), !CFNumberIsFloatType(number) else { return nil }
            return number.intValue
        case .double:
            guard let number = object as? NSNumber, !isBool(number) else { return nil }
            return number.doubleValue
        case .string:
            return object as? String
        case .strings:
            return object as? [String]
        case .data:
            return (object as? Data).map { ["base64": $0.base64EncodedString()] }
        }
    }

    /// The value to store for a JSON one, or `nil` when it has another type than the key's.
    private static func object(of json: Any, as type: ValueType) -> Any? {
        switch type {
        case .bool:
            guard let number = json as? NSNumber, isBool(number) else { return nil }
            return number.boolValue
        case .int:
            guard let number = json as? NSNumber, !isBool(number), !CFNumberIsFloatType(number) else { return nil }
            return number.intValue
        case .double:
            guard let number = json as? NSNumber, !isBool(number) else { return nil }
            return number.doubleValue
        case .string:
            return json as? String
        case .strings:
            return json as? [String]
        case .data:
            guard let tagged = json as? [String: Any], let text = tagged["base64"] as? String else { return nil }
            return Data(base64Encoded: text)
        }
    }
}

/// Why a settings backup was refused.
public enum PersonalSettingsBackupError: Error, Hashable, Sendable, LocalizedError {
    /// the file couldn't be read, with the system's reason
    case unreadable(String)
    /// the file isn't a MegaMonitor settings backup: no JSON, or another `kind`
    case notABackup
    /// the file was written by a newer MegaMonitor, with this format version
    case newerFormat(Int)

    /// the text Settings shows
    public var message: String {
        switch self {
        case .unreadable(let reason): "The backup could not be read: \(reason)"
        case .notABackup: "That is not a MegaMonitor settings backup"
        case .newerFormat(let version):
            "That backup is from a newer MegaMonitor (format \(version)): update the app first"
        }
    }

    public var errorDescription: String? { message }
}

extension AppModel {
    /// Writes the personal settings to a backup file, and logs it.
    ///
    /// - Parameter url: the file, which is replaced
    /// - Returns: the number of values in it
    /// - Throws: the error of writing the file
    @discardableResult
    public func exportPersonalSettings(to url: URL) throws -> Int {
        let count = try PersonalSettingsBackup.export(from: preferencesStore.userDefaults, to: url)
        let log = log
        let name = url.lastPathComponent
        Task { await log.log(.info, .settings, "Exported personal settings to \(name): \(count) values") }
        return count
    }

    /// Reads a backup file, writes its values, and makes the app pick them up: the preferences and the notification
    /// policy through ``reload()``, the repositories, the terminal and the Claude settings through their stores.
    ///
    /// - Parameter url: the file
    /// - Returns: what was written
    /// - Throws: a ``PersonalSettingsBackupError`` when the file is refused; nothing is written then
    @discardableResult
    public func importPersonalSettings(from url: URL) throws -> PersonalSettingsBackup.ImportResult {
        let defaults = preferencesStore.userDefaults
        let result = try PersonalSettingsBackup.importValues(from: url, into: defaults)
        reload()
        workspaces.update(RepositorySettings.load(from: defaults))
        workspaces.setTerminal(TerminalChoice.preferred(in: defaults))
        ai.update(AISettings.load(from: defaults))
        let log = log
        let message = "Imported personal settings from \(url.lastPathComponent): \(result.count) values"
        Task { await log.log(.info, .settings, message) }
        return result
    }
}

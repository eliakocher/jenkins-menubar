import Foundation

/// The one-time move of the user's data from the former identity `menubar-monitor` to MegaMonitor (Task 7.12, APP-10).
///
/// Conservative: it copies, reads the copy back, and leaves the former data where it was; `./install.sh --retire-old`
/// removes it once the user asks. It never overwrites: a key, a token or a file the new identity has already stays.
/// It runs in two parts, each before anything reads what it moves:
///
/// 1. ``moveFilesAndDefaults()``, at launch before the app's scenes and stores exist: the UserDefaults domain, key by
///    key with the keys' names unchanged, and the Application Support, Caches and Logs folders, item by item.
/// 2. ``moveTokens(from:to:)``, at the top of the launch task, before the import and the first check read the tokens.
///
/// Each part marks itself done in the new domain once everything in it was verified, so a failure is tried again at
/// the next launch and a success never runs again. The login item and the default browser are redone by the app from
/// what part 1 reports (``FilesReport/reclaimDefaultBrowser``) and from the marker scripts/migrate-old-bundle.sh leaves.
@MainActor
public struct IdentityMigration {
    /// the key in the new domain that marks part 1 done
    nonisolated static let filesDoneKey = "identityMigration.filesDone"
    /// the key in the new domain that marks part 2 done
    nonisolated static let tokensDoneKey = "identityMigration.tokensDone"

    /// the former UserDefaults domain, like `local.menubar-monitor`
    public var formerDomain: String
    /// the new domain, like `local.megamonitor`: the domain of ``defaults``
    public var currentDomain: String
    /// the former folders
    public var formerLocations: FileLocations
    /// the new folders
    public var currentLocations: FileLocations
    /// the defaults whose own domain is ``currentDomain``: `.standard` in the app, a suite of its own in the tests
    public var defaults: UserDefaults
    /// the former name in the activity log's file names, renamed in the copy: `menubar-monitor.log.1` →
    /// `MegaMonitor.log.1`
    public var formerLogName: String
    /// the new name in the activity log's file names
    public var currentLogName: String

    public init(
        formerDomain: String, currentDomain: String, formerLocations: FileLocations, currentLocations: FileLocations,
        defaults: UserDefaults, formerLogName: String = AppIdentity.Former.name, currentLogName: String = AppIdentity.name
    ) {
        self.formerDomain = formerDomain
        self.currentDomain = currentDomain
        self.formerLocations = formerLocations
        self.currentLocations = currentLocations
        self.defaults = defaults
        self.formerLogName = formerLogName
        self.currentLogName = currentLogName
    }

    /// Returns the app's migration: from `local.menubar-monitor` and `~/Library/…/menubar-monitor` to the
    /// ``AppIdentity`` names, through `UserDefaults.standard`.
    ///
    /// - Parameter library: the user's Library folder
    /// - Returns: the migration
    public static func standard(library: URL = URL.libraryDirectory) -> IdentityMigration {
        let former = AppIdentity.Former.name
        return IdentityMigration(
            formerDomain: AppIdentity.Former.bundleID,
            currentDomain: AppIdentity.bundleID,
            formerLocations: FileLocations(
                applicationSupport: library.appending(path: "Application Support/\(former)", directoryHint: .isDirectory),
                caches: library.appending(path: "Caches/\(former)", directoryHint: .isDirectory),
                logs: library.appending(path: "Logs/\(former)", directoryHint: .isDirectory)),
            currentLocations: .standard(environment: [:], library: library),
            defaults: .standard)
    }

    // MARK: - Part 1: the defaults and the folders

    /// What part 1 did.
    public struct FilesReport: Hashable, Sendable {
        /// whether anything of the former identity was there: a key in its domain or one of its folders
        public var foundFormer = false
        /// the keys copied into the new domain
        public var copiedKeys = 0
        /// the keys the new domain had already, which stayed as they were
        public var keptKeys = 0
        /// the items copied, like `Application Support/projects.json`
        public var copiedItems: [String] = []
        /// the items the new folders had already, which stayed as they were
        public var keptItems: [String] = []
        /// what failed, never with a value; part 1 runs again at the next launch while this isn't empty
        public var problems: [String] = []
        /// whether the link router was on under the former bundle id: macOS still names that id as the default
        /// browser, which no app answers to now, so the app asks to become the default again (APP-09)
        public var reclaimDefaultBrowser = false

        public init() {}

        /// the lines for the activity log: counts and item names, never a value; none on a fresh install
        public var logLines: [String] {
            guard foundFormer || !problems.isEmpty else {
                return []
            }
            var lines = [
                "Moved from menubar-monitor to MegaMonitor: \(copiedKeys) preferences, \(copiedItems.count) files and folders"
                    + (keptKeys + keptItems.count > 0 ? " (\(keptKeys) preferences and \(keptItems.count) files were there already and stayed)" : "")
            ]
            lines += problems.map { "Moving from menubar-monitor: \($0)" }
            return lines
        }
    }

    /// Copies the former domain's keys the new domain doesn't have, and the former folders' items the new folders
    /// don't have, then reads every copy back. Leaves the former domain and folders as they were.
    ///
    /// Call it before anything reads the preferences or the files. Later migrations of keys inside the new domain go
    /// after it, never before: until it ran, the new domain may still be empty.
    ///
    /// - Returns: what it did; nil when it had run before
    @discardableResult
    public func moveFilesAndDefaults() -> FilesReport? {
        guard !isDone(Self.filesDoneKey) else {
            return nil
        }
        var report = FilesReport()
        moveDefaults(into: &report)
        let pairs: [(String, URL, URL)] = [
            ("Application Support", formerLocations.applicationSupport, currentLocations.applicationSupport),
            ("Caches", formerLocations.caches, currentLocations.caches),
            ("Logs", formerLocations.logs, currentLocations.logs),
        ]
        for (label, former, current) in pairs {
            copyMissingItems(label: label, from: former, to: current, into: &report)
        }
        if report.problems.isEmpty {
            defaults.set(true, forKey: Self.filesDoneKey)
        }
        return report
    }

    private func moveDefaults(into report: inout FilesReport) {
        let former = defaults.persistentDomain(forName: formerDomain) ?? [:]
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard !former.isEmpty else {
            return
        }
        report.foundFormer = true
        let missing = former.filter { current[$0.key] == nil }
        report.keptKeys = former.count - missing.count
        for (key, value) in missing {
            defaults.set(value, forKey: key)
        }
        let copied = defaults.persistentDomain(forName: currentDomain) ?? [:]
        let unverified = missing.keys.filter { key in
            guard let value = copied[key] else {
                return true
            }
            return !(value as AnyObject).isEqual(missing[key]! as AnyObject)
        }
        report.copiedKeys = missing.count - unverified.count
        if !unverified.isEmpty {
            // Only the names: a value may be anything.
            report.problems.append("\(unverified.count) preferences didn't read back as copied: \(unverified.sorted().joined(separator: ", "))")
        }
        if former[LinkRouting.enabledKey] as? Bool == true, current[LinkRouting.enabledKey] == nil {
            report.reclaimDefaultBrowser = true
        }
    }

    /// Copies each item of a former folder that the new folder lacks, with the activity log's files renamed.
    private func copyMissingItems(label: String, from former: URL, to current: URL, into report: inout FilesReport) {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: former.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue else {
            return
        }
        report.foundFormer = true
        let items: [URL]
        do {
            try manager.createDirectory(at: current, withIntermediateDirectories: true)
            items = try manager.contentsOfDirectory(at: former, includingPropertiesForKeys: nil)
        } catch {
            report.problems.append("couldn't read or create the \(label) folder: \(error.localizedDescription)")
            return
        }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = renamed(item.lastPathComponent)
            let target = current.appending(path: name)
            let shown = "\(label)/\(name)"
            // Also a broken link counts as there, so it is never replaced.
            if (try? manager.attributesOfItem(atPath: target.path(percentEncoded: false))) != nil {
                report.keptItems.append(shown)
                continue
            }
            do {
                try manager.copyItem(at: item, to: target)
                guard Self.sameTree(item, target) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                report.copiedItems.append(shown)
            } catch {
                // The target wasn't there before, so whatever is there now is this copy's half: it goes, and the next
                // launch tries again.
                try? manager.removeItem(at: target)
                report.problems.append("couldn't copy \(shown): \(error.localizedDescription)")
            }
        }
    }

    /// The name of an item in the new folder: the activity log's files take the new name.
    private func renamed(_ name: String) -> String {
        let prefix = "\(formerLogName).log"
        guard name == prefix || name.hasPrefix(prefix + ".") else {
            return name
        }
        return "\(currentLogName).log" + name.dropFirst(prefix.count)
    }

    /// Whether two items hold the same relative paths, of the same kinds and sizes.
    static func sameTree(_ first: URL, _ second: URL) -> Bool {
        listing(first) == listing(second)
    }

    private static func listing(_ root: URL) -> [String: String]? {
        let manager = FileManager.default
        let path = root.path(percentEncoded: false)
        guard let top = try? manager.attributesOfItem(atPath: path) else {
            return nil
        }
        var listing = ["": describe(top)]
        if top[.type] as? FileAttributeType == .typeDirectory {
            guard let subpaths = try? manager.subpathsOfDirectory(atPath: path) else {
                return nil
            }
            for subpath in subpaths {
                guard let attributes = try? manager.attributesOfItem(atPath: (path as NSString).appendingPathComponent(subpath)) else {
                    return nil
                }
                listing[subpath] = describe(attributes)
            }
        }
        return listing
    }

    private static func describe(_ attributes: [FileAttributeKey: Any]) -> String {
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "?"
        let size = type == FileAttributeType.typeDirectory.rawValue ? 0 : (attributes[.size] as? Int ?? -1)
        return "\(type) \(size)"
    }

    // MARK: - Part 2: the tokens

    /// What part 2 did, by the tokens' display names.
    public struct TokensReport: Hashable, Sendable {
        /// the tokens copied and read back
        public var copied: [String] = []
        /// the tokens the new keychain service had already, which stayed as they were
        public var kept: [String] = []
        /// what failed, never with a token; part 2 runs again at the next launch while this isn't empty
        public var problems: [String] = []

        public init() {}

        /// the lines for the activity log: names only, never a token
        public var logLines: [String] {
            var lines: [String] = []
            if !copied.isEmpty {
                lines.append("Moved the \(copied.joined(separator: " and ")) token to the keychain service \(AppIdentity.keychainService)")
            }
            if !kept.isEmpty {
                lines.append("Kept the \(kept.joined(separator: " and ")) token already under \(AppIdentity.keychainService)")
            }
            lines += problems.map { "Moving the tokens from menubar-monitor: \($0)" }
            return lines
        }
    }

    /// Copies each token the former keychain service has and the new one doesn't, and reads it back. The former
    /// items stay. The tokens never reach a log, a command line or the report.
    ///
    /// - Parameters:
    ///   - former: the former keychain service
    ///   - current: the new keychain service
    /// - Returns: what it did; nil when it had run before
    @discardableResult
    public func moveTokens(from former: any Keychain, to current: any Keychain) async -> TokensReport? {
        guard !isDone(Self.tokensDoneKey) else {
            return nil
        }
        var report = TokensReport()
        for account in TokenAccount.allCases {
            let name = account.displayName
            let token: String
            do {
                guard let found = try await former.find(account: account.rawValue), !found.isEmpty else {
                    continue
                }
                token = found
            } catch {
                report.problems.append("couldn't read the former \(name) token")
                continue
            }
            do {
                if let existing = try await current.find(account: account.rawValue), !existing.isEmpty {
                    report.kept.append(name)
                    continue
                }
                try await current.store(token, account: account.rawValue)
                // Read back before trusting the copy: the former item stays either way.
                guard try await current.find(account: account.rawValue) == token else {
                    throw KeychainError.notStored
                }
                report.copied.append(name)
            } catch {
                report.problems.append("couldn't copy the \(name) token: \(Self.reason(error))")
            }
        }
        if report.problems.isEmpty {
            defaults.set(true, forKey: Self.tokensDoneKey)
        }
        return report
    }

    /// A keychain error's text, which never holds a token; any other error by its type only.
    private static func reason(_ error: any Error) -> String {
        (error as? KeychainError)?.localizedDescription ?? String(describing: type(of: error))
    }

    private func isDone(_ key: String) -> Bool {
        defaults.persistentDomain(forName: currentDomain)?[key] as? Bool == true
    }
}

import Foundation

/// What an app bundle's Info.plist says about its build: the version and the build stamp (APP-05).
public struct BundleBuild: Hashable, Sendable {
    /// `CFBundleShortVersionString`, like "1.0.7"
    public var version: String?
    /// `CFBundleVersion`, like "8"
    public var buildNumber: String?
    /// what `build.sh` stamped: the checkout and the hash of its sources; nil for a build without it
    public var stamp: BuildStamp?

    public init(version: String?, buildNumber: String?, stamp: BuildStamp?) {
        self.version = version
        self.buildNumber = buildNumber
        self.stamp = stamp
    }

    /// Reads the build from an Info.plist.
    ///
    /// - Parameter infoDictionary: the bundle's Info.plist, like `Bundle.main.infoDictionary`
    public init(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: infoDictionary?["CFBundleVersion"] as? String,
            stamp: BuildStamp(infoDictionary: infoDictionary))
    }

    /// Reads the build of a bundle on disk.
    ///
    /// - Parameter bundle: the app bundle, like `~/Applications/MegaMonitor.app`
    /// - Returns: the build; nil when the bundle has no readable Info.plist, or no executable under the name it gives
    public static func read(bundle: URL) -> BundleBuild? {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: contents.appending(path: "Info.plist", directoryHint: .notDirectory)),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(
                  atPath: contents.appending(path: "MacOS/\(executable)").path(percentEncoded: false))
        else { return nil }
        return BundleBuild(infoDictionary: info)
    }

    /// Returns a bundle's or folder's path without the final slash a directory URL has, the one form the update uses
    /// everywhere: in the log, the handover, `open` and the relaunch's `pgrep` pattern, where `…/MegaMonitor.app/` would
    /// give `…app//Contents/MacOS/` and never match.
    ///
    /// - Parameter url: the bundle or folder
    /// - Returns: the path, like `/Users/someone/Applications/MegaMonitor.app`; `/` stays `/`
    public static func plainPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// "1.0.7 (8)", or what of it is known
    public var versionLine: String {
        switch (version, buildNumber) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): "(\(build))"
        case (nil, nil): "an unknown version"
        }
    }

    /// The first 12 digits of the source hash, enough to tell two builds apart in the log.
    public var shortHash: String {
        stamp.map { String($0.sourceHash.prefix(12)) } ?? "no stamp"
    }
}

/// Whether the bundle `build.sh --install` left is really the new build, checked before the app hands over to it
/// (APP-05). A relaunch into a bundle that isn't new would leave the old version running and offer the update again.
public enum InstalledCheck: Hashable, Sendable {
    /// the installed build is the checkout as it is now
    case current
    /// the installed build is newer than the running one, but the checkout changed again while it was built: the new
    /// app offers the update once more
    case behindCheckout
    /// no bundle, Info.plist, executable or stamp at the path `build.sh` named
    case missing
    /// the installed build has the running app's hash: nothing new was installed
    case unchanged

    /// Checks the installed build against the running one and the checkout.
    ///
    /// - Parameters:
    ///   - installed: the installed bundle's build, ``BundleBuild/read(bundle:)``; nil when it couldn't be read
    ///   - running: the running app's stamp
    ///   - checkoutHash: the checkout's hash now; nil when it couldn't be computed
    /// - Returns: the verdict
    public static func verify(installed: BundleBuild?, running: BuildStamp, checkoutHash: String?) -> InstalledCheck {
        guard let hash = installed?.stamp?.sourceHash else {
            return .missing
        }
        if hash == running.sourceHash {
            return .unchanged
        }
        if let checkoutHash, hash != checkoutHash {
            return .behindCheckout
        }
        return .current
    }

    /// whether the app may hand over to the installed bundle
    public var isNew: Bool {
        switch self {
        case .current, .behindCheckout: true
        case .missing, .unchanged: false
        }
    }
}

/// What the app that installed an update leaves for the next start, so that one can tell whether the update took
/// (APP-05): it is the new build when its hash is the expected one, and still the old one when it has the previous hash,
/// for example a copy at another path that was opened instead.
public struct UpdateHandover: Codable, Hashable, Sendable {
    /// the bundle `build.sh --install` installed
    public var installedApp: String
    /// the installed build's source hash
    public var expectedHash: String
    /// the source hash of the app that installed it
    public var previousHash: String
    /// the version line of the app that installed it, like "1.0.6 (7)"
    public var previousVersion: String
    /// when it was installed
    public var installedAt: Date

    public init(installedApp: String, expectedHash: String, previousHash: String, previousVersion: String, installedAt: Date) {
        self.installedApp = installedApp
        self.expectedHash = expectedHash
        self.previousHash = previousHash
        self.previousVersion = previousVersion
        self.installedAt = installedAt
    }

    /// What the start after the update finds.
    public enum Outcome: Hashable, Sendable {
        /// the running app is the installed build
        case updated
        /// the running app is the build that installed the update: the update didn't take
        case stillOld
        /// another build runs, like one `install.sh` made since: nothing to say
        case other
    }

    /// the longest time a handover is waited for: a start later than that is no longer the relaunch
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// Tells what the running app is, compared with the update.
    ///
    /// - Parameter running: the running app's stamp
    public func outcome(running: BuildStamp) -> Outcome {
        switch running.sourceHash {
        case expectedHash: .updated
        case previousHash: .stillOld
        default: .other
        }
    }

    /// the UserDefaults key, written as JSON
    static let defaultsKey = "updateHandover"

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Reads and removes the handover; one older than ``maxAge`` is removed and not returned.
    static func take(from defaults: UserDefaults, now: Date) -> UpdateHandover? {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return nil
        }
        defaults.removeObject(forKey: defaultsKey)
        guard let handover = try? JSONDecoder().decode(UpdateHandover.self, from: data),
              now.timeIntervalSince(handover.installedAt) <= maxAge
        else { return nil }
        return handover
    }
}

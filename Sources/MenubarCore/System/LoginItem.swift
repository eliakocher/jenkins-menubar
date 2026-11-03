import Foundation

/// The app's login item, which opens it at login (APP-02).
///
/// The app implements it with `SMAppService.mainApp`, as Task 0.12 decided; the tests and the gallery use
/// `FakeLoginItem`. The status is the truth: open at login is not stored as a preference.
@MainActor
public protocol LoginItem: Sendable {
    /// the status macOS reports now; System Settings can change it at any time
    var status: LoginItemStatus { get }
    /// Registers the app to open at login.
    func register() throws
    /// Removes the app from the login items.
    func unregister() throws
    /// Opens System Settings → General → Login Items, where the user approves or removes the item.
    func openSystemSettings()
    /// where the app runs from, which explains a login item macOS can't find
    var place: LoginItemPlace { get }
}

extension LoginItem {
    public var place: LoginItemPlace { .installed }
}

/// Where the running app lives, as far as macOS finding it as a login item depends on it (APP-02).
///
/// A copy that was downloaded or copied around carries the quarantine flag, so macOS runs it from a read-only,
/// randomized "AppTranslocation" path; and a login item is only found for an app in an Applications folder.
public struct LoginItemPlace: Sendable, Hashable {
    /// the app bundle's path
    public var bundlePath: String
    /// whether the bundle carries the `com.apple.quarantine` attribute
    public var isQuarantined: Bool
    /// the user's home folder, for `~/Applications`
    public var home: String

    public init(bundlePath: String, isQuarantined: Bool, home: String = NSHomeDirectory()) {
        self.bundlePath = bundlePath
        self.isQuarantined = isQuarantined
        self.home = home
    }

    /// the place of an app that was installed properly
    public static let installed = LoginItemPlace(
        bundlePath: "/Applications/MegaMonitor.app", isQuarantined: false, home: "/Users/me")

    /// whether macOS runs a quarantined copy from a randomized, read-only path
    public var isTranslocated: Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// whether the app is in `/Applications` or `~/Applications`
    public var isInApplications: Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }

    /// the folder the app runs from, with `~` for the home folder
    public var folderText: String {
        let folder = (bundlePath as NSString).deletingLastPathComponent
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// What Settings and the welcome flow say under the "Open at login" switch, and whether they offer System Settings.
public struct LoginItemHelp: Sendable, Hashable {
    /// the explanation; nil when the switch says it all
    public var message: String?
    /// whether "Open Login Items Settings…" is offered
    public var opensLoginItems: Bool

    public init(message: String?, opensLoginItems: Bool) {
        self.message = message
        self.opensLoginItems = opensLoginItems
    }

    public static let quarantined =
        "macOS is running a quarantined copy. Move MegaMonitor to ~/Applications (or install it with ./install.sh), then open it again."

    public static let unknownCause =
        "macOS doesn't know MegaMonitor as a login item yet. Open Login Items Settings and add it with the + button."

    public static func outsideApplications(_ place: LoginItemPlace) -> String {
        "MegaMonitor runs from \(place.folderText), not from an Applications folder. Move it to ~/Applications "
            + "(or install it with ./install.sh), then open it again."
    }

    /// The help for the login item's state.
    ///
    /// - Parameters:
    ///   - status: the login item's status
    ///   - place: where the app runs from
    ///   - failed: whether turning it on or off was refused; the reason is shown on its own line
    public static func of(status: LoginItemStatus, place: LoginItemPlace, failed: Bool) -> LoginItemHelp {
        switch status {
        case .requiresApproval:
            return LoginItemHelp(message: status.message, opensLoginItems: true)
        case .enabled:
            return LoginItemHelp(message: nil, opensLoginItems: false)
        case .notFound, .notRegistered:
            guard status == .notFound || failed else {
                return LoginItemHelp(message: nil, opensLoginItems: false)
            }
            let message =
                if place.isTranslocated || place.isQuarantined {
                    quarantined
                } else if !place.isInApplications {
                    outsideApplications(place)
                } else {
                    unknownCause
                }
            return LoginItemHelp(message: message, opensLoginItems: true)
        }
    }
}

/// What macOS reports for the login item, as `SMAppService.Status` has it.
public enum LoginItemStatus: String, Sendable, Hashable, CaseIterable {
    case notRegistered
    case enabled
    /// registered, and waiting for the user's approval in System Settings
    case requiresApproval
    /// macOS can't find the app, as for a build that runs outside its bundle
    case notFound

    /// whether Settings shows open at login as on: the app is registered, approved or not
    public var isOn: Bool {
        self == .enabled || self == .requiresApproval
    }

    /// whether Settings links to System Settings → Login Items
    public var needsApproval: Bool {
        self == .requiresApproval
    }

    /// the line under the switch when the place of the app is unknown; ``LoginItemHelp/of(status:place:failed:)`` knows more
    public var message: String? {
        switch self {
        case .enabled, .notRegistered: nil
        case .requiresApproval: "Waiting for your approval in System Settings → General → Login Items"
        case .notFound: LoginItemHelp.unknownCause
        }
    }
}

/// Why open at login couldn't be changed.
public struct LoginItemError: Error, Hashable, Sendable, LocalizedError {
    /// whether it was being turned on
    public var turningOn: Bool
    /// the system's reason
    public var reason: String

    public init(turningOn: Bool, reason: String) {
        self.turningOn = turningOn
        self.reason = reason
    }

    /// the text Settings shows and the log keeps
    public var message: String {
        "Open at login couldn't be turned \(turningOn ? "on" : "off"): \(reason)"
    }

    public var errorDescription: String? { message }
}

/// Turns open at login on and off through the login item, and logs each change (APP-02, SET-01).
@MainActor
public struct LaunchAtLogin {
    /// the name the change is logged under, as the preferences' keys are (SET-01)
    public static let logKey = "openAtLogin"

    public let item: any LoginItem
    private let log: ActivityLog?

    public init(item: any LoginItem, log: ActivityLog? = nil) {
        self.item = item
        self.log = log
    }

    /// the login item's status now
    public var status: LoginItemStatus {
        item.status
    }

    /// where the app runs from
    public var place: LoginItemPlace {
        item.place
    }

    /// Registers or unregisters the login item, unless it already is as asked.
    ///
    /// Logs info "openAtLogin: off → on" when the setting changed, or a warning with the reason when macOS refused.
    ///
    /// - Parameter on: whether the app opens at login
    /// - Returns: the status afterwards, which may be ``LoginItemStatus/requiresApproval``
    /// - Throws: a ``LoginItemError`` with the system's reason
    @discardableResult
    public func setOn(_ on: Bool) async throws -> LoginItemStatus {
        let before = item.status
        guard on != before.isOn else { return before }
        do {
            if on {
                try item.register()
            } else {
                try item.unregister()
            }
        } catch {
            // A login item that already throws a `LoginItemError` has its text; wrapping it would repeat the prefix.
            let failure = (error as? LoginItemError) ?? LoginItemError(turningOn: on, reason: error.localizedDescription)
            // The status and the place say why macOS refused, in one entry (paths hold no secrets).
            let place = item.place
            await log?.log(
                .warning, .settings,
                "\(failure.message) [status \(before.rawValue); runs from \(place.bundlePath); "
                    + "quarantined \(place.isQuarantined || place.isTranslocated)]")
            throw failure
        }
        let after = item.status
        if after.isOn != before.isOn {
            await log?.log(.info, .settings, "\(Self.logKey): \(Self.text(before)) → \(Self.text(after))")
        }
        return after
    }

    /// the file install.sh leaves in the Application Support folder when the app moved to a new bundle path while open at
    /// login was on (the rename to MegaMonitor.app): macOS still holds the old path, and the new app registers again
    public static let refreshMarkerName = "refresh-login-item"

    /// Registers the login item again for the app's current place, when install.sh left the marker, and removes the marker.
    ///
    /// The marker is removed first, so a failure is tried once and not at every launch. The registration is dropped and
    /// made again because the status of a login item that macOS holds under the old bundle path already reads as on.
    ///
    /// - Parameter folder: the Application Support folder the marker is in
    public func refreshRegistrationIfMarked(in folder: URL) async {
        let marker = folder.appending(path: Self.refreshMarkerName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else {
            return
        }
        try? FileManager.default.removeItem(at: marker)
        try? item.unregister()
        do {
            try item.register()
            await log?.log(.info, .settings, "\(Self.logKey): registered again for the app's new place")
        } catch {
            await log?.log(.warning, .settings, LoginItemError(turningOn: true, reason: error.localizedDescription).message)
        }
    }

    /// Opens System Settings → General → Login Items.
    public func openSystemSettings() {
        item.openSystemSettings()
    }

    private static func text(_ status: LoginItemStatus) -> String {
        status.isOn ? "on" : "off"
    }
}

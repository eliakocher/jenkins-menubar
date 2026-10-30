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

    /// the line Settings → General shows under the switch; nil when the switch says it all (proposed copy)
    public var message: String? {
        switch self {
        case .enabled, .notRegistered: nil
        case .requiresApproval: "Waiting for your approval in System Settings → General → Login Items"
        case .notFound: "Open at login needs the installed app: run ./build.sh --install"
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
            await log?.log(.warning, .settings, failure.message)
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

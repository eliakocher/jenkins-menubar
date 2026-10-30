import Foundation

/// The names MegaMonitor uses on the system, from the identity map of the plan.
///
/// The visible name is MegaMonitor (``displayName``); the identity stays menubar-monitor, for the user's settings and
/// tokens: the bundle id, the URL scheme, the keychain service and the folder names are what they were before the
/// rename, so no setting, token, login item or default-browser choice is lost.
///
/// build.sh writes the same bundle id and URL scheme into Info.plist; the tests keep both in step.
public enum AppIdentity {
    /// The bundle id, which is also the UserDefaults domain and the LaunchAgent label.
    public static let bundleID = "local.menubar-monitor"
    /// The keychain service, and the folder name in Application Support, Caches and Logs. Never shown to the user.
    public static let name = "menubar-monitor"
    public static let urlScheme = "menubar-monitor"
    public static let keychainService = name

    /// The name the user sees: the bundle's name, the windows, the menus and every text.
    public static let displayName = "MegaMonitor"
    /// The file name of the bundle build.sh builds and install.sh installs into `~/Applications`.
    public static let bundleFileName = "\(displayName).app"

    /// The Info.plist key holding the path of the checkout the app was built from.
    public static let sourceRootKey = "MMSourceRoot"
    /// The Info.plist key holding the hash of the checkout's sources at build time.
    public static let sourceHashKey = "MMSourceHash"
}

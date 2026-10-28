import Foundation

/// The names menubar-monitor uses on the system, from the identity map of the plan.
///
/// build.sh writes the same bundle id and URL scheme into Info.plist; the tests keep both in step.
public enum AppIdentity {
    /// The bundle id, which is also the UserDefaults domain and the LaunchAgent label.
    public static let bundleID = "local.menubar-monitor"
    /// The bundle name, the executable, the keychain service, and the folder name in Application Support, Caches and
    /// Logs.
    public static let name = "menubar-monitor"
    public static let urlScheme = "menubar-monitor"
    public static let keychainService = name

    /// The Info.plist key holding the path of the checkout the app was built from.
    public static let sourceRootKey = "MMSourceRoot"
    /// The Info.plist key holding the hash of the checkout's sources at build time.
    public static let sourceHashKey = "MMSourceHash"
}

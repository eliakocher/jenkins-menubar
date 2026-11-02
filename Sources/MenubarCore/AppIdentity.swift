import Foundation

/// The names MegaMonitor uses on the system.
///
/// The identity was `menubar-monitor` until Task 7.12 renamed it (``Former``); ``IdentityMigration`` copies the
/// user's preferences, tokens and folders from the former names once, at the first launch under the new ones.
///
/// build.sh writes the same bundle id and URL schemes into Info.plist, and install.sh and
/// scripts/migrate-old-bundle.sh use the same folder names; the tests keep them in step.
public enum AppIdentity {
    /// The bundle id, which is also the UserDefaults domain and the unified log's subsystem.
    public static let bundleID = "local.megamonitor"
    /// The folder name in Application Support, Caches and Logs, and the activity log's file name. Never shown to the
    /// user as a name of its own.
    public static let name = "MegaMonitor"
    /// The scheme of the app's own links, `megamonitor://` (APP-03).
    public static let urlScheme = "megamonitor"
    /// Every scheme the app answers to: its own, and the former one, so links written before the rename still work.
    public static let urlSchemes = [urlScheme, Former.urlScheme]
    /// The keychain service of the tokens.
    public static let keychainService = "megamonitor"

    /// The name the user sees: the bundle's name, the windows, the menus and every text.
    public static let displayName = "MegaMonitor"
    /// The file name of the bundle build.sh builds and install.sh installs into `~/Applications`.
    public static let bundleFileName = "\(displayName).app"

    /// The Info.plist key holding the path of the checkout the app was built from.
    public static let sourceRootKey = "MMSourceRoot"
    /// The Info.plist key holding the hash of the checkout's sources at build time.
    public static let sourceHashKey = "MMSourceHash"

    /// The identity before Task 7.12, which ``IdentityMigration`` copies from and `./install.sh --retire-old` removes.
    public enum Former {
        /// the former bundle id and UserDefaults domain
        public static let bundleID = "local.menubar-monitor"
        /// the former folder name in Application Support, Caches and Logs, and the activity log's file name
        public static let name = "menubar-monitor"
        /// the former scheme, still accepted (``AppIdentity/urlSchemes``)
        public static let urlScheme = "menubar-monitor"
        /// the former keychain service
        public static let keychainService = "menubar-monitor"
    }
}

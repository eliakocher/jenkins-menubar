import MenubarCore
import os

/// The app's own diagnostics, in the unified log (`log stream --predicate 'subsystem == "local.menubar-monitor"'`).
///
/// What people need to see goes to the Activity log instead; this is for problems of the app's wiring.
enum AppLog {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

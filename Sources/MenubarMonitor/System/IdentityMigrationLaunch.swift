import AppKit
import MenubarCore

/// Runs the first part of the identity migration (Task 7.12, APP-10) at the very start, before NSApplication, the
/// scenes and the stores read a preference or a file, and keeps it for ``AppShell``, which runs the second part (the
/// tokens, the default browser, the notification permission) at the top of its launch task.
@MainActor
enum IdentityMigrationLaunch {
    /// the migration and what its first part did (nil when it had run before); nil when it was skipped
    private(set) static var pending: (migration: IdentityMigration, report: IdentityMigration.FilesReport?)?

    /// Quits a copy that still runs under the former bundle id, then copies the former preferences and folders.
    /// Skipped for the runs that keep away from the user's data (`--throwaway`, `MENUBAR_MONITOR_DATA_DIR`) and outside
    /// the bundle.
    ///
    /// - Parameters:
    ///   - arguments: the command line, without the executable
    ///   - environment: the process environment
    static func run(arguments: [String], environment: [String: String]) {
        #if DEBUG
        if arguments.contains(AppShell.throwawayOption) {
            return
        }
        #endif
        if let folder = environment[FileLocations.dataDirectoryVariable], !folder.isEmpty {
            return
        }
        // Only the bundle under the new id: an executable run outside it has a domain of another name.
        guard Bundle.main.bundleIdentifier == AppIdentity.bundleID else {
            return
        }
        quitFormerCopies()
        let migration = IdentityMigration.standard()
        pending = (migration, migration.moveFilesAndDefaults())
    }

    /// Asks a copy under the former bundle id to quit, and waits for it at most 5 seconds, so two apps never run and
    /// its last writes to its preferences are in before they are copied. install.sh quits it too; this catches a copy
    /// started some other way.
    private static func quitFormerCopies() {
        let former = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.Former.bundleID)
        guard !former.isEmpty else {
            return
        }
        for app in former {
            app.terminate()
        }
        // No run loop runs yet, so isTerminated wouldn't change: the process table tells.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, former.contains(where: { kill($0.processIdentifier, 0) == 0 }) {
            usleep(100_000)
        }
    }
}

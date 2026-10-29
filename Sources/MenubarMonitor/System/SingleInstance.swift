import AppKit
import MenubarCore

/// Keeps one instance of the app running (APP-03).
///
/// LaunchServices already hands a second start of the same bundle to the running app. This catches the rest: another
/// copy of the bundle, such as `build/` next to `~/Applications/`, or the executable started from a terminal.
enum SingleInstance {
    /// Returns the instance that runs already, if any.
    static func runningInstance() -> NSRunningApplication? {
        let current = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .first { $0.processIdentifier != current && !$0.isTerminated }
    }

    /// Opens the running instance's bundle, which sends it a reopen event: it comes forward, and opens its main window
    /// when none is open. Waits at most 5 seconds for LaunchServices.
    static func handOver(to running: NSRunningApplication) {
        guard let bundle = running.bundleURL else {
            running.activate()
            return
        }
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                AppLog.warning("Couldn't hand over to the running instance: \(error.localizedDescription)")
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}

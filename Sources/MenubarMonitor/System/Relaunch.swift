import Foundation

/// Opens the rebuilt app once this one has quit (APP-05).
///
/// Opened while this instance still runs, the new one would hand over to it and exit (``SingleInstance``). So a
/// detached `/bin/sh` waits until this process is gone, at most 30 seconds, and then opens the new bundle. The pid and
/// the path are the script's arguments, never part of its text.
enum Relaunch {
    private static let script = """
        tries=0
        while kill -0 "$1" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -gt 150 ] && exit 1
            sleep 0.2
        done
        exec /usr/bin/open "$2"
        """

    /// Starts the wait for this process to end, then the opening of the app; quit right after.
    ///
    /// - Parameter app: the installed app
    static func open(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", script, "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path(percentEncoded: false)]
        do {
            try shell.run()
        } catch {
            AppLog.error("Couldn't start opening the rebuilt app: \(error.localizedDescription)")
        }
    }
}

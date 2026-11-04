import Foundation
import MenubarCore

/// Opens the rebuilt app once this one has quit (APP-05).
///
/// Opened while this instance still runs, the new one would hand over to it and exit (``SingleInstance``). So a
/// detached `/bin/sh` waits until this process is gone, at most 30 seconds, and then opens the installed bundle by its
/// path, the one the update store checked. Right after a quit, `open` sometimes starts nothing (install.sh saw it
/// 2026-11-02), so the script looks for the bundle's executable among the processes and opens it again, up to three
/// times. The pid and the path are the script's arguments, never part of its text; the path is escaped before `pgrep`
/// reads it as a pattern. The next start tells in the Activity log whether the update took
/// (`UpdateStore.launched(bundle:info:)`).
enum Relaunch {
    private static let script = """
        tries=0
        while kill -0 "$1" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -gt 150 ] && exit 1
            sleep 0.2
        done
        app=${2%/}
        pattern=$(printf '%s' "$app/Contents/MacOS/" | sed 's/[][\\.*^$+?(){}|]/\\\\&/g')
        for attempt in 1 2 3; do
            /usr/bin/open "$app"
            waited=0
            while [ "$waited" -lt 25 ]; do
                pgrep -f "^$pattern" >/dev/null 2>&1 && exit 0
                sleep 0.2
                waited=$((waited + 1))
            done
        done
        exit 1
        """

    /// Starts the wait for this process to end, then the opening of the app; quit right after.
    ///
    /// - Parameter app: the installed app
    static func open(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        // The path without a final slash, so the pattern below reads `…app/Contents/MacOS/`.
        shell.arguments = [
            "-c", script, "relaunch", String(ProcessInfo.processInfo.processIdentifier),
            BundleBuild.plainPath(app),
        ]
        do {
            try shell.run()
        } catch {
            AppLog.error("Couldn't start opening the rebuilt app: \(error.localizedDescription)")
        }
    }
}

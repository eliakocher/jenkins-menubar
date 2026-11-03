import MenubarCore
import SwiftUI

/// Starts the app; with `--smoke`, the smoke check; with `--gallery` in debug builds, the design gallery; with
/// `--claude-read-guard`, the hook that keeps Claude's file tools in a checkout (``ClaudeReadGuard``).
@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == ClaudeReadGuard.argument {
            // Claude Code runs this before each tool call of a chat about code: its JSON in, the decision out, nothing
            // else of the app starts.
            let input = FileHandle.standardInput.readDataToEndOfFile()
            FileHandle.standardOutput.write(
                ClaudeReadGuard.hookOutput(for: input, environment: ProcessInfo.processInfo.environment))
            exit(0)
        }
        if arguments.contains("--smoke") {
            SmokeMode.run(arguments: arguments)
        }
        if arguments.contains("--gallery") {
            #if DEBUG
            GalleryMode.run(arguments: arguments)
            #else
            // Rather than start the app in the user's menubar.
            FileHandle.standardError.write(Data("the gallery is in debug builds only: ./build.sh --debug\n".utf8))
            exit(2)
            #endif
        }
        if let running = SingleInstance.runningInstance() {
            SingleInstance.handOver(to: running)
            exit(0)
        }
        // The identity migration first (Task 7.12, APP-10): it copies the former preferences and folders before
        // anything reads them. A later migration of keys inside the new domain goes after this line, never before.
        IdentityMigrationLaunch.run(arguments: arguments, environment: ProcessInfo.processInfo.environment)
        MenubarMonitorApp.main()
    }
}

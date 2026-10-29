import SwiftUI

/// Starts the app; with `--smoke`, the smoke check; with `--gallery` in debug builds, the design gallery.
@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
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
        MenubarMonitorApp.main()
    }
}

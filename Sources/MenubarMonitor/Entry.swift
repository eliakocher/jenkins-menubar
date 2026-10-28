import SwiftUI

/// Starts the app, or with `--gallery` in debug builds the design gallery.
@main
enum Entry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--gallery") {
            #if DEBUG
            GalleryMode.run(arguments: Array(CommandLine.arguments.dropFirst()))
            #else
            // Rather than start the app in the user's menubar.
            FileHandle.standardError.write(Data("the gallery is in debug builds only: ./build.sh --debug\n".utf8))
            exit(2)
            #endif
        }
        MenubarMonitorApp.main()
    }
}

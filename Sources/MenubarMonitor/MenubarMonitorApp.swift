import AppKit
import MenubarCore
import SwiftUI

/// The app's scenes. Until Phase 4 builds the panel, the menubar item only offers Quit.
struct MenubarMonitorApp: App {
    var body: some Scene {
        MenuBarExtra {
            Button("Quit \(AppIdentity.name)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: StatusImage.idle)
        }
    }
}

@MainActor
enum StatusImage {
    /// The idle menubar icon, `icons/menubar.png`: a template, so macOS tints it like its own icons, drawn at 2× since
    /// the file has no resolution of its own.
    static let idle: NSImage = {
        guard let image = NSImage(named: "menubar") else {
            // Run outside the bundle, from .build.
            return NSImage(systemSymbolName: "hammer", accessibilityDescription: AppIdentity.name) ?? NSImage()
        }
        image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.name
        return image
    }()
}

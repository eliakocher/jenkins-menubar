#if DEBUG
import AppKit
import MenubarCore
import SwiftUI

extension GalleryCatalog {
    /// The About window with the easter eggs on and off (EGG-21); the roll stands still for the shot.
    static var aboutEntries: [GalleryEntry] {
        func entry(screen: String, eggs: Bool) -> GalleryEntry {
            GalleryEntry(screen: screen, state: "default", size: AboutView.size(eggs: eggs)) { _ in
                AboutView(
                    eggs: eggs, icon: NSApp.applicationIconImage,
                    versionLine: AboutCredits.versionLine(info: ["CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "2"]),
                    scrolls: false)
            }
        }
        return [entry(screen: "about", eggs: true), entry(screen: "about-no-eggs", eggs: false)]
    }
}
#endif

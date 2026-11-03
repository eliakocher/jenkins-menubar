#if DEBUG
import MenubarCore
import SwiftUI

/// The "What's New" sheet: after an update that skipped versions, after a single update, and without a changelog. Made up
/// throughout.
enum WhatsNewGallery {
    /// a made-up changelog, as `Changelog.parse` reads a file
    static let changelog = Changelog.parse(
        """
        # Changelog

        ## [Unreleased]

        ### Added
        - Nothing yet.

        ## [1.0.4] - 2026-11-03

        ### Fixed
        - Opening the menu bar pane while the butler is about to peek no longer crashes the app.

        ## [1.0.3] - 2026-11-03

        ### Added
        - Pipelines:
          - **Watch** for a job you don't follow yet, from its build detail.
          - **Save…** in the console log, which writes the whole log to a file, with progress and Cancel.
        - Slots: **arrow keys** move through the item rows, Return opens the item, ← closes the slot.
        - **The fun layer**, behind the Easter eggs setting, with a **Fun level** (Subtle, Normal or Party).

        ### Changed
        - The Merge card shows the last known state at once while the fresh one loads.

        ## [1.0.2] - 2026-11-02

        ### Fixed
        - A rebuild shows its progress as a percentage, in the toolbar and in the pane.
        - The Inbox no longer lists a finished build twice.
        """)

    /// the sections after a version
    static func sections(from: String?, to: String? = nil) -> [ChangelogSection] {
        Changelog.sections(changelog, from: from, to: to)
    }
}

extension GalleryCatalog {
    static var whatsNewEntries: [GalleryEntry] {
        let size = CGSize(width: WhatsNewSheet.width, height: 640)
        return [
            GalleryEntry(screen: "whats-new", state: "skipped-versions", size: size) { _ in
                WhatsNewSheet(sections: WhatsNewGallery.sections(from: "1.0.1", to: "1.0.4"), close: {})
            },
            GalleryEntry(screen: "whats-new", state: "single", size: CGSize(width: WhatsNewSheet.width, height: 360)) { _ in
                WhatsNewSheet(sections: WhatsNewGallery.sections(from: "1.0.3", to: "1.0.4"), close: {})
            },
            GalleryEntry(screen: "whats-new", state: "no-changelog", size: CGSize(width: WhatsNewSheet.width, height: 360)) { _ in
                WhatsNewSheet(sections: [], close: {})
            },
        ]
    }
}
#endif

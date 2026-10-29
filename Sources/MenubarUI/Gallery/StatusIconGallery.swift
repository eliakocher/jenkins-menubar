#if DEBUG
import AppKit
import MenubarCore
import SwiftUI

/// The status label as the gallery shows it: exactly what the label draws, in the menu bar's font, centered on the
/// window's background; no backdrop imitates the menu bar (`docs/design/status-icon.md`, States).
struct StatusIconGalleryView: View {
    let model: StatusLabelModel

    var body: some View {
        StatusLabelContent(model: model)
            .font(Font(NSFont.menuBarFont(ofSize: 0)))
            .frame(width: 280, height: 44)
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/status-icon.md`.
    static var statusIconEntries: [GalleryEntry] {
        let size = CGSize(width: 280, height: 44)
        return [
            GalleryEntry(screen: "status-icon", state: "idle", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel())
            },
            GalleryEntry(screen: "status-icon", state: "running", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(running: 1)))
            },
            GalleryEntry(screen: "status-icon", state: "failed", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(failed: 1)))
            },
            GalleryEntry(screen: "status-icon", state: "unstable", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(unstable: 1)))
            },
            GalleryEntry(screen: "status-icon", state: "successful", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(successful: 1)))
            },
            GalleryEntry(screen: "status-icon", state: "all-counts", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(running: 2, failed: 1, unstable: 1, successful: 3)))
            },
            GalleryEntry(screen: "status-icon", state: "problem", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(problem: .jenkins))
            },
            GalleryEntry(screen: "status-icon", state: "problem-with-counts", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(problem: .jenkins, counts: BuildCounts(running: 1, failed: 1)))
            },
            GalleryEntry(screen: "status-icon", state: "color-all-counts", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(
                    counts: BuildCounts(running: 2, failed: 1, unstable: 1, successful: 3), style: .color))
            },
            GalleryEntry(screen: "status-icon", state: "color-markers", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(
                    problem: .jenkins, counts: BuildCounts(running: 1, failed: 1), style: .color))
            },
            GalleryEntry(screen: "status-icon", state: "large-counts", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(running: 12, successful: 10)))
            },
            // The easter eggs (`docs/easter-eggs.md`): the hats on the idle butler, and the Konami bow in front of the counts.
            GalleryEntry(screen: "status-icon", state: "idle-party-hat", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(hat: .party))
            },
            GalleryEntry(screen: "status-icon", state: "idle-santa-hat", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(hat: .santa))
            },
            GalleryEntry(screen: "status-icon", state: "bow-full", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(bow: .full))
            },
            GalleryEntry(screen: "status-icon", state: "bow-half-with-counts", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(counts: BuildCounts(running: 1, failed: 1), bow: .half))
            },
            GalleryEntry(screen: "status-icon", state: "widest", size: size) { _ in
                StatusIconGalleryView(model: StatusLabelModel(
                    problem: .jenkins, counts: BuildCounts(running: 120, failed: 105, unstable: 110, successful: 999)))
            },
        ]
    }
}
#endif

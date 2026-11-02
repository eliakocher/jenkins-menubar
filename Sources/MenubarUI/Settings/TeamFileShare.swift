import AppKit
import MenubarCore
import SwiftUI

/// What Share Setup… and Import from a Link… do, which Settings → Team's row calls; the pane gives the real ones.
struct TeamFileLinkActions {
    /// whether an import link exists to copy: the team values were imported from a link before
    var canCopyLink = false
    var onImportLink: () -> Void = {}
    /// writes the team file to share and returns it, nil when that failed
    var onShare: () -> URL? = { nil }
    /// puts the import link on the pasteboard; true when it did
    var onCopyLink: () -> Bool = { false }
}

/// Holds the AppKit view of Share Setup…'s button, which the sharing picker needs to open beside it, and the picker
/// itself, which must outlive the call that shows it.
@MainActor
final class ShareAnchorBox {
    weak var view: NSView?
    private var picker: NSSharingServicePicker?

    /// Shows the system's sharing picker for a file beside the button.
    func present(_ file: URL) {
        guard let view = view ?? NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [file])
        self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// A view that gives its AppKit view to a ``ShareAnchorBox``. It draws nothing and takes no clicks.
struct ShareAnchor: NSViewRepresentable {
    let box: ShareAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = PassiveView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    private final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

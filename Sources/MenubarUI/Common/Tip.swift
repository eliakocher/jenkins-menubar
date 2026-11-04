import AppKit
import SwiftUI

// The app's tooltip, in place of `.help`: one small glass bubble per window that a controller moves, fills and shows
// (see ``TipController``), never a tooltip per view. The user's call: no VoiceOver or accessibility text from it.

/// What a tooltip says: a text, or a small view (a list of names) that is only built when the tooltip shows.
enum TipSource {
    case text(String)
    case view(() -> AnyView)
}

extension View {
    /// Shows a tooltip over the view after the pointer rests on it for half a second; it hides when the pointer leaves,
    /// and on a scroll, a click or a key, and doesn't show while the page scrolls. Nothing in the view re-renders for it.
    ///
    /// - Parameter text: what the tooltip says; `nil` or empty shows none
    func tip(_ text: String?) -> some View {
        background {
            TipAnchor(source: text.flatMap { $0.isEmpty ? nil : TipSource.text($0) })
        }
    }

    /// Shows a tooltip made of a small view, like a list of names; the view is built when the tooltip shows, not before.
    ///
    /// - Parameter content: the tooltip's content, at most 280 pt wide
    func tip<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        background {
            TipAnchor(source: .view({ AnyView(content()) }))
        }
    }
}

/// The view a tooltip hangs on: it sits behind its view with the same frame, takes no clicks, and registers with the
/// window's controller. Scrolling moves it with the page, so it costs nothing while the page scrolls.
private struct TipAnchor: NSViewRepresentable {
    let source: TipSource?

    func makeNSView(context: Context) -> TipAnchorView {
        let view = TipAnchorView()
        view.source = source
        return view
    }

    func updateNSView(_ view: TipAnchorView, context: Context) {
        view.source = source
    }
}

/// An area for ``TipController``'s hit test. Held weakly by the controller.
@MainActor
final class TipAnchorView: NSView {
    var source: TipSource?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// whether neither the view nor an ancestor is hidden or fully transparent
    var isShownOnScreen: Bool {
        var view: NSView? = self
        while let current = view {
            if current.isHidden || current.alphaValue < 0.01 { return false }
            view = current.superview
        }
        return true
    }

    /// Returns the part of the view that is on screen, in the window's coordinates, worked out now from the view's own
    /// bounds up through every ancestor (the clip views of scrolling cut it); `nil` when hidden, transparent, outside a
    /// window or scrolled out. It doesn't use `visibleRect`, which for these views returned the whole visible page.
    var frameOnScreen: CGRect? {
        guard window != nil, isShownOnScreen else { return nil }
        var rect = bounds
        var view: NSView = self
        while let parent = view.superview {
            rect = parent.convert(rect, from: view)
            if parent is NSClipView || parent.clipsToBounds {
                rect = rect.intersection(parent.bounds)
            }
            if rect.isEmpty { return nil }
            view = parent
        }
        let inWindow = view.convert(rect, to: nil)
        return inWindow.isEmpty ? nil : inWindow
    }

    /// how many views sit above this one up to the window, to tell nested anchors of the same size apart
    var depthInWindow: Int {
        var depth = 0
        var view = superview
        while let current = view {
            depth += 1
            view = current.superview
        }
        return depth
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            TipHub.shared.unregister(self, from: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            TipHub.shared.register(self, in: window)
        }
    }
}

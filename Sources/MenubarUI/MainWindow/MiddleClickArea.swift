import AppKit
import SwiftUI

/// Which events a middle click is, decided from plain values so that it is testable without a window or a mouse.
enum MiddleClick {
    /// Returns whether a mouse button number is the middle button (2 on every mouse macOS knows).
    static func isMiddleButton(_ number: Int) -> Bool {
        number == 2
    }

    /// Returns whether an event is part of a middle click. `buttonNumber` is read only for the types that have one:
    /// AppKit raises when a key or a left click is asked for it, and an exception in an event path fails silently.
    static func isMiddleClick(_ event: NSEvent?) -> Bool {
        guard let event else {
            return false
        }
        switch event.type {
        case .otherMouseDown, .otherMouseUp:
            return isMiddleButton(event.buttonNumber)
        default:
            return false
        }
    }
}

extension View {
    /// Runs `action` on a middle click anywhere on the view. Left and right clicks, hovers and drags pass through to what
    /// is under it, so selection, the context menu and dragging of a list row keep working.
    func onMiddleClick(perform action: @escaping @MainActor () -> Void) -> some View {
        overlay(MiddleClickArea(action: action))
    }
}

/// A transparent view that takes only the middle button's events. Its `hitTest` answers by the event being dispatched:
/// for a middle click it is the target, for everything else (left and right clicks, moves, scrolls) it is not there.
private struct MiddleClickArea: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.action = action
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.action = action
    }

    final class AreaView: NSView {
        var action: (@MainActor () -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard MiddleClick.isMiddleClick(NSApp.currentEvent), super.hitTest(point) != nil else {
                return nil
            }
            return self
        }

        override func otherMouseDown(with event: NSEvent) {
            // Taken, so that the matching `otherMouseUp` comes here too.
            guard MiddleClick.isMiddleClick(event) else {
                super.otherMouseDown(with: event)
                return
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard MiddleClick.isMiddleClick(event) else {
                super.otherMouseUp(with: event)
                return
            }
            // Only a release on the row closes it: a press that moved away before the release is a cancel.
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                action?()
            }
        }
    }
}

import AppKit
import SwiftUI

/// What to do with a window frame that AppKit restored: keep it while enough of it is on a screen, otherwise (a display
/// that is gone) the default size, centered on the main screen.
public enum WindowFrameRestore {
    /// how much of the title bar area, in points, has to be on a screen so that the window can still be grabbed
    static let minimumVisible = CGSize(width: 120, height: 40)

    /// - parameter restored: the window's frame after AppKit restored the saved one
    /// - parameter screens: the visible frames of all screens, the main screen first
    /// - parameter defaultSize: the size of the first launch
    public static func frame(restored: CGRect, screens: [CGRect], defaultSize: CGSize) -> CGRect {
        let isReachable = screens.contains { screen in
            let overlap = screen.intersection(restored)
            return !overlap.isNull && overlap.width >= minimumVisible.width && overlap.height >= minimumVisible.height
        }
        if isReachable {
            return restored
        }
        guard let main = screens.first else {
            return restored
        }
        let size = CGSize(width: min(defaultSize.width, main.width), height: min(defaultSize.height, main.height))
        return CGRect(
            x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Makes the window it sits in remember its frame, size and position, across closing and reopening it and across app
/// starts (`NSWindow.setFrameAutosaveName`). The first launch keeps the scene's `.defaultSize`.
struct WindowFrameMemory: NSViewRepresentable {
    let autosaveName: String
    let defaultSize: CGSize

    func makeNSView(context: Context) -> MemoryView {
        let view = MemoryView()
        view.autosaveName = autosaveName
        view.defaultSize = defaultSize
        return view
    }

    func updateNSView(_ view: MemoryView, context: Context) {}

    final class MemoryView: NSView {
        var autosaveName = ""
        var defaultSize = CGSize(width: 1120, height: 720)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != autosaveName else {
                return
            }
            // Restores the saved frame when there is one and saves every later move and resize.
            window.setFrameAutosaveName(autosaveName)
            let screens = NSScreen.screens.map(\.visibleFrame)
            let frame = WindowFrameRestore.frame(restored: window.frame, screens: screens, defaultSize: defaultSize)
            if frame != window.frame {
                window.setFrame(frame, display: true)
            }
        }
    }
}

extension View {
    /// Remembers the frame of the window this view is in under `name` (see `WindowFrameMemory`).
    func remembersWindowFrame(_ name: String, defaultSize: CGSize) -> some View {
        background { WindowFrameMemory(autosaveName: name, defaultSize: defaultSize) }
    }
}

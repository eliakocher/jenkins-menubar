import AppKit
import MenubarCore
import MenubarUI
import SwiftUI

/// The corner glow of Hot Corners (HOT-12): a transparent panel in the corner of a display that plays the light of
/// ``HotCornerGlowView`` once and closes itself.
///
/// - Borderless and non-activating, above everything (`.screenSaver`), on every Space and over full-screen apps. It
///   ignores the mouse, has no shadow, and never becomes key or main, so the app never activates and typing goes on.
/// - Sized to the glow and anchored at the corner of the given display frame (global coordinates, bottom-left origin).
/// - One firing replaces the one before: a new glow closes the running one first.
@MainActor
final class HotCornerGlowPanel: NSPanel {
    /// the glow that plays now
    private static var current: HotCornerGlowPanel?

    /// Plays a glow at a corner of a display, closing the one that plays.
    ///
    /// - Parameters:
    ///   - corner: the corner
    ///   - screen: the display's frame in global coordinates
    ///   - glow: the color, animation and size
    static func show(at corner: HotCorner, screen: CGRect, glow: HotCornerGlow) {
        current?.close()
        let side = min(CGFloat(glow.size.points), screen.width, screen.height)
        let frame = CGRect(
            x: corner == .topLeft || corner == .bottomLeft ? screen.minX : screen.maxX - side,
            y: corner == .topLeft || corner == .topRight ? screen.maxY - side : screen.minY, width: side, height: side)
        let panel = HotCornerGlowPanel(frame: frame)
        let hosting = NSHostingView(rootView: HotCornerGlowView(corner: corner, glow: glow, side: side))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        current = panel
        // The panel never takes focus: only ordering it in front.
        panel.orderFrontRegardless()
        let seconds = glow.duration + 0.15
        Task { [weak panel] in
            try? await Task.sleep(for: .seconds(seconds))
            panel?.close()
        }
    }

    private init(frame: CGRect) {
        super.init(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A borderless window in the menu bar's area would be pushed down into the screen; the glow stays where it was put.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func close() {
        if Self.current === self {
            Self.current = nil
        }
        super.close()
    }
}

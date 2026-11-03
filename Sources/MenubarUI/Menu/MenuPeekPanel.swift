import AppKit
import MenubarCore
import SwiftUI

/// Where the peeking butler leans out of the menu bar pane: beside it, from behind its edge, in a small transparent panel
/// that is a child of the pane's window, like the flyout (the user, 2026-11-03: "almost not visible" when he was clipped by
/// the pane's own rounded edge).
///
/// The panel starts exactly at the pane's edge and holds only the part of him that shows outside: his cut line sits on the
/// panel's edge, so his body seems to be behind the pane. It moves and closes with the pane, never takes the keyboard, and a
/// click on him is a catch. It uses the side the flyout isn't on, and the side that has room on the screen; with neither,
/// he doesn't peek.
@MainActor
final class MenuPeekPanelController {
    enum Side: Equatable {
        case right, left
    }

    /// where the panel goes
    struct Placement: Equatable {
        var side: Side
        var frame: NSRect
    }

    /// the figure's length, and the panel's height around it
    static let length: CGFloat = 118
    static let height: CGFloat = 134

    /// Returns where the panel goes, or `nil` when he can't peek.
    ///
    /// - Parameters:
    ///   - pane: the pane window's frame
    ///   - flyout: the flyout's frame while one shows; his side is the other one
    ///   - visible: the screen's visible frame
    ///   - along: where along the pane's height he comes out, 0 from the top to 1 at the bottom
    ///   - width: the width that shows of him outside the pane
    /// - Returns: the side, preferring the right, and the panel's frame; `nil` for no side with room that the flyout leaves free
    static func placement(pane: NSRect, flyout: NSRect?, visible: NSRect, along: CGFloat, width: CGFloat) -> Placement? {
        let taken: Side? = flyout.map { $0.midX > pane.midX ? .right : .left }
        let centerY = pane.maxY - pane.height * along
        let y = min(max(centerY - height / 2, visible.minY), visible.maxY - height)
        for side in [Side.right, .left] where side != taken {
            switch side {
            case .right where visible.maxX - pane.maxX >= width:
                return Placement(side: .right, frame: NSRect(x: pane.maxX, y: y, width: width, height: height))
            case .left where pane.minX - visible.minX >= width:
                return Placement(side: .left, frame: NSRect(x: pane.minX - width, y: y, width: width, height: height))
            default:
                continue
            }
        }
        return nil
    }

    /// the width of him that shows outside the pane: what is past his cut line
    static var shownWidth: CGFloat {
        let art = PeekArt.art(for: .left)
        let frame = ButlerPeekFigure.size(of: art, edge: .left, length: length)
        return (frame.width * (1 - art.hidden)).rounded(.up)
    }

    private var panel: MenuPeekPanel?
    private var side: Side?

    /// Whether he could peek now: a side has room and the flyout leaves it free.
    func canPeek(pane: NSWindow?, flyout: NSWindow?, along: CGFloat = 0.68) -> Bool {
        guard let pane, pane.isVisible else {
            return false
        }
        return Self.placement(
            pane: pane.frame, flyout: flyout?.isVisible == true ? flyout?.frame : nil,
            visible: (pane.screen ?? NSScreen.main)?.visibleFrame ?? pane.frame, along: along, width: Self.shownWidth) != nil
    }

    /// Shows the panel while the pane's peek plays, puts it on the right side, and hides it otherwise.
    func refresh(fun: FunModel, pane: NSWindow?, flyout: NSWindow?) {
        guard let playing = fun.playing, playing.owner == FunModel.paneOwner, let pane, pane.isVisible,
            let placement = Self.placement(
                pane: pane.frame, flyout: flyout?.isVisible == true ? flyout?.frame : nil,
                visible: (pane.screen ?? NSScreen.main)?.visibleFrame ?? pane.frame, along: CGFloat(playing.along),
                width: Self.shownWidth)
        else {
            hide()
            return
        }
        let panel = panel ?? MenuPeekPanel()
        self.panel = panel
        if side != placement.side || panel.contentView == nil {
            side = placement.side
            let hosting = MenuFlyoutHostingView(rootView: AnyView(MenuPeekPanelView(fun: fun, side: placement.side)))
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        panel.setFrame(placement.frame, display: true)
        if panel.parent !== pane {
            pane.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// Takes the panel away.
    func hide() {
        guard let panel, panel.parent != nil || panel.isVisible else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        side = nil
    }
}

/// The peek's window: borderless, transparent, never key, so the pane keeps the keyboard and stays open.
final class MenuPeekPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: MenuPeekPanelController.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the peek panel draws: the butler leaning out away from the pane, slid in and out by the phase the model plays. A click
/// on him is a catch, and the pointer resting on him sends him back, as on the other surfaces.
struct MenuPeekPanelView: View {
    let fun: FunModel
    let side: MenuPeekPanelController.Side
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var slide: CGFloat = 0
    @ViewState private var fuse: Task<Void, Never>?

    var body: some View {
        // Leaning out to the right is the left-edge art, whose cut line is the panel's left edge, and the other way round.
        ButlerPeekFigure(
            edge: side == .right ? .left : .right, along: 0.5, slide: slide, hat: FunModel.peekHat(catches: fun.catches),
            length: MenuPeekPanelController.length)
            .contentShape(Rectangle())
            .onTapGesture { fun.catchButler() }
            .onHover { near in
                fuse?.cancel()
                fuse = nil
                if near {
                    fuse = Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        if !Task.isCancelled {
                            fun.duck()
                        }
                    }
                }
            }
            .accessibilityLabel("The butler peeks out. Click to catch him.")
            .accessibilityAddTraits(.isButton)
            .onChange(of: fun.playing?.phase, initial: true) { _, phase in
                let target: CGFloat = phase == .slidingOut || phase == nil ? 0 : 1
                if reduceMotion || phase == nil {
                    slide = target
                } else {
                    withAnimation(phase == .slidingOut ? .easeIn(duration: 0.2) : .spring(duration: 0.38, bounce: 0.3)) { slide = target }
                }
            }
    }
}

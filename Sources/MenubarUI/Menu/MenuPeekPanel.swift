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
    private var hosting: MenuFlyoutHostingView?
    private var side: Side?
    /// what the next refresh reads: the fun model, the pane's window and the flyout's, as they are when it runs
    private var source: (@MainActor () -> (fun: FunModel, pane: NSWindow?, flyout: NSWindow?)?)?
    private var isRefreshScheduled = false
    /// Refreshes the panel when the pane's window resizes or moves while he is out, so he stays on its edge.
    private var paneObservers: [any NSObjectProtocol] = []
    private weak var observedPane: NSWindow?

    /// Whether he could peek now: a side has room and the flyout leaves it free.
    func canPeek(pane: NSWindow?, flyout: NSWindow?, along: CGFloat = 0.68) -> Bool {
        guard let pane, pane.isVisible else {
            return false
        }
        return Self.placement(
            pane: pane.frame, flyout: flyout?.isVisible == true ? flyout?.frame : nil,
            visible: (pane.screen ?? NSScreen.main)?.visibleFrame ?? pane.frame, along: along, width: Self.shownWidth) != nil
    }

    /// Asks for a refresh on the next turn of the run loop; asks in the same turn share one.
    ///
    /// The pane calls this from SwiftUI's updates, which run inside its window's layout and constraint passes: a window's
    /// frame, child windows or content view changed there marks the pane's constraints dirty again, and AppKit raises
    /// when a window needs more constraint passes than it has views (the crash of 2026-11-03). So the panel's window is
    /// only ever touched here, a turn later, outside every pass.
    ///
    /// - Parameter source: returns the fun model, the pane's window (`nil` while the pane is closed) and the flyout's,
    ///   read when the refresh runs; `nil` hides the panel
    func setNeedsRefresh(_ source: @escaping @MainActor () -> (fun: FunModel, pane: NSWindow?, flyout: NSWindow?)?) {
        self.source = source
        guard !isRefreshScheduled else {
            return
        }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.isRefreshScheduled = false
                guard let state = self.source?() else {
                    self.hide()
                    return
                }
                self.refresh(fun: state.fun, pane: state.pane, flyout: state.flyout)
            }
        }
    }

    /// Shows the panel while the pane's peek plays, puts it on the right side, and hides it otherwise. A pane or a place
    /// that isn't sound (no size, off every screen, not finite) skips the peek. Call it outside layout: see
    /// ``setNeedsRefresh(_:)``.
    func refresh(fun: FunModel, pane: NSWindow?, flyout: NSWindow?) {
        guard let playing = fun.playing, playing.owner == FunModel.paneOwner, let pane, pane.isVisible,
            Self.isSound(pane.frame), let screen = pane.screen ?? NSScreen.main,
            let placement = Self.placement(
                pane: pane.frame, flyout: flyout?.isVisible == true ? flyout?.frame : nil,
                visible: screen.visibleFrame, along: CGFloat(playing.along), width: Self.shownWidth),
            Self.isSound(placement.frame)
        else {
            hide()
            return
        }
        let panel = panel ?? MenuPeekPanel()
        self.panel = panel
        if hosting == nil || side != placement.side {
            side = placement.side
            let view = AnyView(MenuPeekPanelView(fun: fun, side: placement.side))
            if let hosting {
                hosting.rootView = view
            } else {
                // In a plain container, not as the window's content view: the panel's size is only ever set here, and
                // SwiftUI never manages the window's content size from the figure.
                let hosting = MenuFlyoutHostingView(rootView: view)
                hosting.sizingOptions = []
                let container = NSView(frame: NSRect(origin: .zero, size: placement.frame.size))
                hosting.frame = container.bounds
                hosting.autoresizingMask = [.width, .height]
                container.addSubview(hosting)
                panel.contentView = container
                self.hosting = hosting
            }
        }
        panel.level = pane.level
        panel.appearanceSource = pane
        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: false)
        }
        if panel.parent !== pane {
            panel.parent?.removeChildWindow(panel)
            pane.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        observe(pane)
    }

    /// Takes the panel away.
    func hide() {
        stopObserving()
        guard let panel, panel.parent != nil || panel.isVisible else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// whether a frame can place a window: finite, with a size
    static func isSound(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width >= 1 && frame.height >= 1
    }

    private func observe(_ pane: NSWindow) {
        guard observedPane !== pane else {
            return
        }
        stopObserving()
        observedPane = pane
        paneObservers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: pane, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let source = self.source else {
                        return
                    }
                    self.setNeedsRefresh(source)
                }
            }
        }
    }

    private func stopObserving() {
        paneObservers.forEach(NotificationCenter.default.removeObserver)
        paneObservers = []
        observedPane = nil
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
        // He is laid out once, fully out; the slide is an offset, which only moves his drawing, so the animation never
        // asks for layout (and never for the window's constraints).
        let back = (1 - slide) * MenuPeekPanelController.shownWidth
        ButlerPeekFigure(
            edge: side == .right ? .left : .right, along: 0.5, slide: 1, hat: FunModel.peekHat(catches: fun.catches),
            length: MenuPeekPanelController.length)
            .offset(x: side == .right ? -back : back)
            .contentShape(Rectangle())
            .onTapGesture { _ = fun.catchButler() }
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

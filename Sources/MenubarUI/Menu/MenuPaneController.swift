import AppKit
import MenubarCore
import Observation
import SwiftUI

/// The pane's live state beside its views (`docs/design/panel.md`): the highlight and the open flyout
/// (``MenuNavigation``), the hover timing (``MenuHover``, ``MenuAim``), and the flyout's glass panel, put beside its
/// area row (``MenuFlyoutPlacement``) as a child window of the pane's window, so it moves and closes with the pane.
@MainActor
@Observable
final class MenuPaneController {
    /// the highlight and the open flyout, which the pane and the flyout draw
    var navigation = MenuNavigation()

    /// Returns the flyout of an area as the stores hold it now, for the keys (the flyout's rows) and Return.
    @ObservationIgnored var flyout: @MainActor (MainWindowSection) -> MenuFlyout? = { _ in nil }
    /// Returns the flyout panel's SwiftUI root, with the app's environment; the pane sets it when it appears.
    @ObservationIgnored var makeFlyoutRoot: (@MainActor () -> AnyView)?

    /// The area rows' AppKit views, kept weakly, whose frames place the flyout.
    private final class Anchor {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    @ObservationIgnored private var anchors: [MainWindowSection: Anchor] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingDecision: MenuHover.Decision?
    @ObservationIgnored private var lastPointer: CGPoint?
    @ObservationIgnored private var pointerInPane = false
    @ObservationIgnored private var pointerInFlyout = false
    @ObservationIgnored private var panel: MenuFlyoutPanel?
    @ObservationIgnored private var hosting: NSView?
    /// the flyout content's height, measured while it shows
    @ObservationIgnored private var contentHeight: CGFloat = 0
    /// the area the panel was last put beside, whose content the height is
    @ObservationIgnored private var placedArea: MainWindowSection?
    /// whether the pane is on screen; the flyout never shows without it
    @ObservationIgnored private(set) var isPaneVisible = false

    // MARK: - The pane's events

    /// Notes an area row's AppKit view.
    func register(_ section: MainWindowSection, view: NSView) {
        if anchors[section]?.view !== view {
            anchors[section] = Anchor(view)
        }
        if let window = view.window, window !== styledWindow {
            styledWindow = window
            Self.keepMaterialActive(in: window)
        }
    }

    /// the pane's window whose material was set active
    @ObservationIgnored private weak var styledWindow: NSWindow?

    /// Draws the pane's window material as a menu's, translucent: a visual effect view that follows the window's
    /// active state draws flat grey while the window isn't key, which the user saw in the menu bar (2026-10-29).
    private static func keepMaterialActive(in window: NSWindow) {
        var views = [window.contentView?.superview ?? window.contentView].compactMap { $0 }
        while let view = views.popLast() {
            if let effect = view as? NSVisualEffectView {
                effect.state = .active
            }
            views += view.subviews
        }
    }

    /// The pointer moved over a pane row: the highlight follows unless the pointer travels toward the open flyout, and
    /// the flyout opens, switches or closes as ``MenuHover`` decides.
    func hover(_ row: MenuNavigation.PaneRow) {
        pointerInPane = true
        let pointer = NSEvent.mouseLocation
        var isAiming = false
        if let previous = lastPointer, let panel, panel.isVisible {
            isAiming = MenuAim.isAiming(from: previous, to: pointer, toward: panel.frame)
        }
        lastPointer = pointer
        // The pointer moves often: the state changes, and the pane redraws, only when a value does.
        if !isAiming, navigation.highlight != row || navigation.focus != .pane {
            navigation.highlight = row
            navigation.focus = .pane
        }
        let target: MenuHover.Target
        if case .area(let section) = row {
            target = .area(section)
        } else {
            target = .otherRow
        }
        apply(MenuHover.decide(target, openArea: navigation.openArea, isAiming: isAiming), restart: isAiming)
    }

    /// The pointer left the pane: no row stays highlighted but the open area, and the flyout closes when the pointer
    /// isn't in it either, after a moment.
    func leavePane() {
        pointerInPane = false
        lastPointer = nil
        if navigation.focus == .pane, navigation.highlight != nil {
            navigation.highlight = nil
        }
        if !pointerInFlyout {
            apply(MenuHover.decide(.outside, openArea: navigation.openArea, isAiming: false), restart: false)
        }
    }

    /// The pointer moved over a flyout row, by its index, or into the flyout between rows (`nil`).
    func hoverFlyout(_ index: Int?) {
        pointerInFlyout = true
        apply(.keep, restart: false)
        if let index, navigation.flyoutHighlight != index || navigation.focus != .flyout {
            navigation.hoverFlyout(index)
        }
    }

    /// The pointer entered or left the flyout.
    func pointerInFlyout(_ inside: Bool) {
        pointerInFlyout = inside
        if inside {
            apply(.keep, restart: false)
        } else {
            if navigation.flyoutHighlight != nil {
                navigation.flyoutHighlight = nil
            }
            if !pointerInPane {
                apply(MenuHover.decide(.outside, openArea: navigation.openArea, isAiming: false), restart: false)
            }
        }
    }

    /// Handles a key, as a native menu: see ``MenuNavigation``.
    ///
    /// - Parameter key: the key
    /// - Returns: what the pane does beyond the highlight
    func handle(_ key: MenuNavigation.Key) -> MenuNavigation.Command {
        if navigation.focus == .pane, case .area(let section)? = navigation.highlight {
            navigation.flyoutCount = flyout(section)?.items.count ?? 0
        } else if let open = navigation.openArea {
            navigation.flyoutCount = flyout(open)?.items.count ?? 0
        }
        apply(.keep, restart: false)
        let command = navigation.handle(key)
        sync()
        return command
    }

    /// Opens an area's flyout at once, as a click on its row does.
    func open(_ section: MainWindowSection) {
        apply(.keep, restart: false)
        navigation.open(section)
        sync()
    }

    /// Notes the flyout content's height, which changes with the stores while it shows.
    func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else {
            return
        }
        contentHeight = height
        place(fade: false)
    }

    /// The pane appeared: the keys start on the pane, nothing highlighted, no flyout.
    func paneAppeared() {
        isPaneVisible = true
        navigation.highlight = nil
        navigation.closeFlyout()
    }

    /// The pane closed: the flyout goes with it, always.
    func paneDisappeared() {
        isPaneVisible = false
        pending?.cancel()
        pending = nil
        pendingDecision = nil
        lastPointer = nil
        pointerInPane = false
        pointerInFlyout = false
        navigation.highlight = nil
        navigation.closeFlyout()
        hidePanel()
    }

    // MARK: - Timing

    /// Carries out a decision: cancels what waits, or waits and then opens or closes. A decision that waits already
    /// keeps its timer, unless `restart` asks for a new one, as while the pointer aims at the flyout.
    private func apply(_ decision: MenuHover.Decision, restart: Bool) {
        if decision == pendingDecision, !restart {
            return
        }
        pending?.cancel()
        pending = nil
        pendingDecision = nil
        let delay: Duration
        switch decision {
        case .keep:
            return
        case .open(_, let after), .close(let after):
            delay = after
        }
        pendingDecision = decision
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            self.pendingDecision = nil
            switch decision {
            case .open(let section, _):
                self.navigation.open(section)
            case .close:
                self.navigation.closeFlyout()
            case .keep:
                break
            }
            self.sync()
        }
    }

    // MARK: - The flyout panel

    /// Shows the flyout beside its area row while one is open, and hides it otherwise.
    func sync() {
        if navigation.openArea != nil, isPaneVisible {
            place(fade: panel?.isVisible != true)
        } else {
            hidePanel()
        }
    }

    /// Puts the flyout beside the open area's row, sized to its content within the screen.
    private func place(fade: Bool) {
        guard isPaneVisible, let area = navigation.openArea, let anchor = anchors[area]?.view,
              let window = anchor.window, window.isVisible
        else {
            hidePanel()
            return
        }
        let panel = panel ?? makePanel()
        guard let panel else {
            return
        }
        if contentHeight <= 0 || placedArea != area, let flyout = flyout(area) {
            // Measured before it shows, so a new area's flyout opens at its own size.
            contentHeight = Self.measure(flyout)
        }
        placedArea = area
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let size = CGSize(width: MenuMetrics.flyoutWidth, height: min(contentHeight, MenuMetrics.flyoutCap))
        let placement = MenuFlyoutPlacement.frame(
            row: row, pane: window.frame, size: size, visible: visible, topInset: MenuMetrics.edge)
        panel.setFrame(placement.frame, display: true)
        guard panel.parent !== window || !panel.isVisible else {
            return
        }
        panel.appearanceSource = window
        panel.level = window.level
        if fade {
            panel.alphaValue = 0
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func makePanel() -> MenuFlyoutPanel? {
        guard let root = makeFlyoutRoot?() else {
            return nil
        }
        let panel = MenuFlyoutPanel()
        let hosting = MenuFlyoutHostingView(rootView: root)
        panel.setContent(hosting)
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func hidePanel() {
        guard let panel, panel.isVisible || panel.parent != nil else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        contentHeight = 0
        placedArea = nil
    }

    /// Returns the height of a flyout's content, measured before the panel shows, so it opens at its size.
    private static func measure(_ flyout: MenuFlyout) -> CGFloat {
        let view = NSHostingView(rootView: MenuFlyoutContent(flyout: flyout))
        return view.fittingSize.height
    }
}

/// The flyout's window: a borderless glass panel that never takes the keyboard, so the pane keeps it and stays open
/// (`docs/decisions.md`, the alert's glass panel, Q7). The pane's window is its parent.
final class MenuFlyoutPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MenuMetrics.flyoutWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        // The glass is the whole background: the window draws nothing, but keeps its shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    /// Never key: the pane keeps the keyboard, and a pane that loses it closes.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// Puts the hosted flyout on the panel's glass.
    func setContent(_ view: NSView) {
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
        glass.style = .regular
        glass.cornerRadius = MenuMetrics.flyoutCorner
        glass.autoresizingMask = [.width, .height]
        view.frame = glass.bounds
        view.autoresizingMask = [.width, .height]
        glass.contentView = view
        contentView = glass
    }
}

/// The flyout's hosting view: a click works at once, though the panel is never key.
final class MenuFlyoutHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

import CoreGraphics
import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuNavigation")
struct MenuNavigationTests {
    private static func pane() -> MenuNavigation {
        var navigation = MenuNavigation()
        navigation.paneRows = MenuNavigation.paneRows(
            problemIsLinked: false, areas: [.pipelines, .mergeRequests, .workItems])
        return navigation
    }

    @Test("APP-06 the keys move through the pane and its flyouts as in a native menu")
    func keys() {
        var navigation = Self.pane()
        // ↓ starts at the top, ↑ at the bottom, and both wrap.
        #expect(navigation.handle(.down) == .none)
        #expect(navigation.highlight == .area(.pipelines))
        #expect(navigation.handle(.up) == .none)
        #expect(navigation.highlight == .quit)
        _ = navigation.handle(.down)
        #expect(navigation.highlight == .area(.pipelines))

        // → opens the flyout and moves into it, its first row highlighted; the area stays highlighted.
        navigation.flyoutCount = 3
        _ = navigation.handle(.right)
        #expect(navigation.openArea == .pipelines)
        #expect(navigation.focus == .flyout)
        #expect(navigation.flyoutHighlight == 0)
        #expect(navigation.isHighlighted(.area(.pipelines)))
        _ = navigation.handle(.up)
        #expect(navigation.flyoutHighlight == 2)
        // Return opens the highlighted row.
        #expect(navigation.handle(.enter) == .activateFlyout(2))

        // ← or Esc goes back to the pane, the highlight on the area, the flyout closed.
        _ = navigation.handle(.left)
        #expect(navigation.openArea == nil)
        #expect(navigation.focus == .pane)
        #expect(navigation.highlight == .area(.pipelines))
        _ = navigation.handle(.enter)
        #expect(navigation.focus == .flyout)
        _ = navigation.handle(.escape)
        #expect(navigation.focus == .pane)

        // Return on a command performs it; Esc on the pane closes it.
        navigation.highlight = .checkNow
        #expect(navigation.handle(.enter) == .activate(.checkNow))
        #expect(navigation.handle(.right) == .none)
        #expect(navigation.handle(.escape) == .closePane)
    }

    @Test("APP-06 moving the highlight off an area closes its flyout")
    func moveOffClosesFlyout() {
        var navigation = Self.pane()
        navigation.open(.mergeRequests)
        #expect(navigation.highlight == .area(.mergeRequests))
        #expect(navigation.focus == .pane)
        _ = navigation.handle(.down)
        #expect(navigation.highlight == .area(.workItems))
        #expect(navigation.openArea == nil)

        // The pointer on a flyout row takes the keys there.
        navigation.open(.workItems)
        navigation.flyoutCount = 4
        navigation.hoverFlyout(1)
        #expect(navigation.focus == .flyout)
        _ = navigation.handle(.down)
        #expect(navigation.flyoutHighlight == 2)
    }

    @Test("APP-06 the flyout opens after a rest, switches, waits for an aiming pointer and closes outside")
    func hoverTiming() {
        // Nothing open: a rest on an area opens it; other rows and the outside change nothing.
        #expect(MenuHover.decide(.area(.pipelines), openArea: nil, isAiming: false) == .open(.pipelines, after: MenuHover.openDelay))
        #expect(MenuHover.decide(.otherRow, openArea: nil, isAiming: false) == .keep)
        #expect(MenuHover.decide(.outside, openArea: nil, isAiming: false) == .keep)

        // Its own area and the flyout keep it.
        #expect(MenuHover.decide(.area(.pipelines), openArea: .pipelines, isAiming: false) == .keep)
        #expect(MenuHover.decide(.flyout, openArea: .pipelines, isAiming: false) == .keep)

        // Another area switches; while the pointer travels toward the flyout, it waits longer.
        #expect(MenuHover.decide(.area(.workItems), openArea: .pipelines, isAiming: false) == .open(.workItems, after: MenuHover.openDelay))
        #expect(MenuHover.decide(.area(.workItems), openArea: .pipelines, isAiming: true) == .open(.workItems, after: MenuHover.aimDelay))
        #expect(MenuHover.decide(.otherRow, openArea: .pipelines, isAiming: false) == .close(after: MenuHover.openDelay))
        #expect(MenuHover.decide(.otherRow, openArea: .pipelines, isAiming: true) == .close(after: MenuHover.aimDelay))
        #expect(MenuHover.aimDelay > MenuHover.openDelay)

        // Outside both windows, it closes after a moment.
        #expect(MenuHover.decide(.outside, openArea: .pipelines, isAiming: false) == .close(after: MenuHover.leaveDelay))
    }

    @Test("APP-06 the pointer aims at the flyout inside the triangle to its near edge")
    func aim() {
        // A flyout to the right of the pane, 300 pt tall; the pointer leaves the row at (200, 500).
        let flyout = CGRect(x: 300, y: 300, width: 380, height: 300)
        let start = CGPoint(x: 200, y: 500)
        #expect(MenuAim.isAiming(from: start, to: CGPoint(x: 230, y: 470), toward: flyout))
        #expect(MenuAim.isAiming(from: start, to: CGPoint(x: 260, y: 520), toward: flyout))
        // Straight down along the rows, or away from the flyout: not aiming.
        #expect(!MenuAim.isAiming(from: start, to: CGPoint(x: 200, y: 470), toward: flyout))
        #expect(!MenuAim.isAiming(from: start, to: CGPoint(x: 180, y: 480), toward: flyout))
        // Steeper than the triangle: below the flyout's bottom corner.
        #expect(!MenuAim.isAiming(from: start, to: CGPoint(x: 210, y: 300), toward: flyout))
        #expect(!MenuAim.isAiming(from: start, to: start, toward: flyout))

        // A flyout on the left: the triangle opens to the left.
        let left = CGRect(x: -400, y: 300, width: 380, height: 300)
        #expect(MenuAim.isAiming(from: CGPoint(x: 20, y: 500), to: CGPoint(x: 0, y: 490), toward: left))
        #expect(!MenuAim.isAiming(from: CGPoint(x: 20, y: 500), to: CGPoint(x: 40, y: 490), toward: left))
    }

    @Test("APP-06 the flyout sits beside its row: right when it fits, else left, inside the screen")
    func placement() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let size = CGSize(width: 388, height: 300)
        let gap = MenuFlyoutPlacement.gap

        // A pane in the middle: on the right, the flyout's top at the row's top plus the inset.
        let pane = CGRect(x: 600, y: 500, width: 348, height: 370)
        let row = CGRect(x: 600, y: 800, width: 348, height: 42)
        let right = MenuFlyoutPlacement.frame(row: row, pane: pane, size: size, visible: visible, topInset: 5)
        #expect(right.side == .right)
        #expect(right.frame.minX == pane.maxX + gap)
        #expect(right.frame.maxY == row.maxY + 5)

        // Near the screen's right edge, as menu bar extras usually are: on the left.
        let edge = CGRect(x: 1080, y: 500, width: 348, height: 370)
        let left = MenuFlyoutPlacement.frame(row: row.offsetBy(dx: 480, dy: 0), pane: edge, size: size, visible: visible)
        #expect(left.side == .left)
        #expect(left.frame.maxX == edge.minX - gap)

        // A row near the bottom: pushed up inside the visible frame.
        let low = CGRect(x: 600, y: 40, width: 348, height: 42)
        let pushed = MenuFlyoutPlacement.frame(row: low, pane: pane, size: size, visible: visible)
        #expect(pushed.frame.minY == visible.minY + MenuFlyoutPlacement.margin)
        #expect(pushed.frame.height == 300)

        // Taller than the screen: as tall as the visible frame allows; the content scrolls.
        let tall = MenuFlyoutPlacement.frame(
            row: row, pane: pane, size: CGSize(width: 388, height: 2000), visible: visible)
        #expect(tall.frame.height == visible.height - 2 * MenuFlyoutPlacement.margin)
        #expect(visible.contains(tall.frame))
    }
}

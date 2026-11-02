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

        // Moving the highlight off an area closes its flyout.
        var moved = Self.pane()
        moved.open(.mergeRequests)
        #expect(moved.highlight == .area(.mergeRequests))
        #expect(moved.focus == .pane)
        _ = moved.handle(.down)
        #expect(moved.highlight == .area(.workItems))
        #expect(moved.openArea == nil)

        // The pointer on a flyout row takes the keys there.
        moved.open(.workItems)
        moved.flyoutCount = 4
        moved.hoverFlyout(1)
        #expect(moved.focus == .flyout)
        _ = moved.handle(.down)
        #expect(moved.flyoutHighlight == 2)
    }
}

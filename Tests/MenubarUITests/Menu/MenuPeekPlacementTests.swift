import AppKit
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuPeekPlacement")
@MainActor
struct MenuPeekPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1600, height: 900)
    private let pane = NSRect(x: 1100, y: 300, width: 384, height: 560)
    private let width: CGFloat = 70

    private func place(pane: NSRect? = nil, flyout: NSRect? = nil, screen: NSRect? = nil, along: CGFloat = 0.68) -> MenuPeekPanelController.Placement? {
        MenuPeekPanelController.placement(
            pane: pane ?? self.pane, flyout: flyout, visible: screen ?? self.screen, along: along, width: width)
    }

    @Test("FUN-11 the butler leans out of the pane's right edge when it has room, else the left; the panel starts on the edge")
    func sides() throws {
        let right = try #require(place())
        #expect(right.side == .right && right.frame.minX == pane.maxX && right.frame.width == width)
        // no room on the right: the left, ending on the pane's left edge
        let tight = try #require(place(screen: NSRect(x: 0, y: 0, width: 1500, height: 900)))
        #expect(tight.side == .left && tight.frame.maxX == pane.minX)
        // room on neither side: no peek
        #expect(place(pane: NSRect(x: 10, y: 300, width: 1490, height: 560), screen: NSRect(x: 0, y: 0, width: 1500, height: 900)) == nil)
    }

    @Test("FUN-11 the butler never leans out on the flyout's side: the other side, or none")
    func flyoutSide() throws {
        let flyoutRight = NSRect(x: pane.maxX + 4, y: 500, width: 388, height: 300)
        #expect(try #require(place(flyout: flyoutRight)).side == .left)
        let flyoutLeft = NSRect(x: pane.minX - 392, y: 500, width: 388, height: 300)
        #expect(try #require(place(flyout: flyoutLeft)).side == .right)
        // the flyout on the left and no room on the right: he skips
        #expect(place(flyout: flyoutLeft, screen: NSRect(x: 0, y: 0, width: 1500, height: 900)) == nil)
    }

    @Test("FUN-11 the panel is level with where he comes out and stays on the screen")
    func vertical() throws {
        // the footer rows are at 0.68 of the pane's height from its top
        let frame = try #require(place()).frame
        #expect(abs(frame.midY - (pane.maxY - pane.height * 0.68)) < 0.5)
        let high = try #require(place(along: 0.0)).frame
        #expect(high.maxY <= screen.maxY && high.minY >= screen.minY)
    }

    @Test("FUN-08 a surprise's line in the footer uses the lightbulb of the tip: sparkles mean Claude only")
    func footerSymbol() {
        let surprise = FunFooterLine(FunModel.FooterLine(text: "A fun fact", kind: .surprise))
        #expect(surprise.symbol == "lightbulb")
        #expect(FunFooterLine(FunModel.FooterLine(text: "tip", kind: .tip)).symbol == "lightbulb")
    }
}

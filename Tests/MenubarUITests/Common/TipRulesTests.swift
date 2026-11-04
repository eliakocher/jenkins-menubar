import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MenubarUI

@Suite("TipRules")
struct TipRulesTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// whether a wait is the expected one, to a microsecond: dates a thousand seconds from the epoch have no finer steps
    private func isAbout(_ wait: TimeInterval?, _ expected: TimeInterval) -> Bool {
        wait.map { abs($0 - expected) < 1e-6 } ?? false
    }

    @Test("TIP-01 the tooltip is due half a second after the pointer comes to rest, and not before")
    func showsAfterTheRest() {
        var timing = TipTiming()
        #expect(timing.delayLeft(at: at(0)) == nil)
        timing.pointerMoved(at: at(0), inShownArea: false)
        #expect(isAbout(timing.delayLeft(at: at(0.2)), 0.3))
        #expect(isAbout(timing.delayLeft(at: at(0.5)), 0))
        // every move starts the rest again
        timing.pointerMoved(at: at(0.4), inShownArea: false)
        #expect(isAbout(timing.delayLeft(at: at(0.5)), 0.4))
        #expect(isAbout(timing.delayLeft(at: at(0.9)), 0))
    }

    @Test("TIP-01 a shown tooltip hides the moment the pointer leaves its area, and stays while the pointer moves inside it")
    func hidesOnExit() {
        var timing = TipTiming()
        timing.pointerMoved(at: at(0), inShownArea: false)
        timing.didShow()
        #expect(timing.delayLeft(at: at(2)) == nil)
        let staysInside = timing.pointerMoved(at: at(2), inShownArea: true)
        #expect(!staysInside)
        #expect(timing.isShown)
        let hidesOnExit = timing.pointerMoved(at: at(3), inShownArea: false)
        #expect(hidesOnExit)
        #expect(!timing.isShown)
        // and the next one is due a half second later
        #expect(isAbout(timing.delayLeft(at: at(3)), 0.5))
    }

    @Test("TIP-01 a scroll hides the tooltip, and none shows while it goes on or in the 0.3 s after it, nor before a rest of 0.5 s")
    func staysAwayWhileScrolling() {
        var timing = TipTiming()
        timing.pointerMoved(at: at(0), inShownArea: false)
        timing.didShow()
        let hidesOnScroll = timing.scrolled(at: at(1))
        #expect(hidesOnScroll)
        #expect(!timing.isShown)
        // events keep coming: the due time moves with the last one
        timing.scrolled(at: at(1.4))
        timing.scrolled(at: at(1.8))
        #expect(isAbout(timing.delayLeft(at: at(1.9)), 0.4))
        #expect(isAbout(timing.delayLeft(at: at(2.3)), 0))
        // a scroll starts the rest again, so a pointer that rested long before still waits half a second after it
        var other = TipTiming()
        other.pointerMoved(at: at(0), inShownArea: false)
        other.scrolled(at: at(0.1))
        #expect(isAbout(other.delayLeft(at: at(0.4)), 0.2))
        #expect(isAbout(other.delayLeft(at: at(0.6)), 0))
    }

    @Test("TIP-01 a click, a key or the pointer leaving the window hides the tooltip and none is due until the pointer moves")
    func interruptions() {
        var timing = TipTiming()
        timing.pointerMoved(at: at(0), inShownArea: false)
        timing.didShow()
        let hidesOnClick = timing.interrupted()
        #expect(hidesOnClick)
        #expect(timing.delayLeft(at: at(5)) == nil)
        #expect(!timing.isWaiting)
        timing.pointerMoved(at: at(6), inShownArea: false)
        #expect(timing.isWaiting)
        // nothing under the pointer: nothing is due either
        timing.nothingToShow()
        #expect(timing.delayLeft(at: at(7)) == nil)
    }

    @Test("TIP-01 the area under the pointer is the innermost one, and none outside them")
    func hitTest() {
        let outer = TipArea(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let inner = TipArea(id: 2, frame: CGRect(x: 20, y: 20, width: 40, height: 20))
        let areas = [outer, inner]
        #expect(TipHitTest.area(at: CGPoint(x: 30, y: 30), in: areas)?.id == 2)
        #expect(TipHitTest.area(at: CGPoint(x: 30, y: 30), in: areas.reversed())?.id == 2)
        #expect(TipHitTest.area(at: CGPoint(x: 150, y: 30), in: areas)?.id == 1)
        #expect(TipHitTest.area(at: CGPoint(x: 250, y: 30), in: areas) == nil)
        #expect(TipHitTest.area(at: CGPoint(x: 1, y: 1), in: []) == nil)
    }

    @Test("TIP-01 of areas of one size the deeper view wins, and nested areas pick the smallest wherever the pointer is")
    func nestedAreas() {
        let row = TipArea(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 60), depth: 3)
        let title = TipArea(id: 2, frame: CGRect(x: 10, y: 20, width: 200, height: 20), depth: 5)
        let weight = TipArea(id: 3, frame: CGRect(x: 350, y: 20, width: 30, height: 20), depth: 5)
        let same = TipArea(id: 4, frame: weight.frame, depth: 6)
        let areas = [row, title, weight, same]
        #expect(TipHitTest.area(at: CGPoint(x: 100, y: 30), in: areas)?.id == 2)
        #expect(TipHitTest.area(at: CGPoint(x: 360, y: 30), in: areas)?.id == 4)
        #expect(TipHitTest.area(at: CGPoint(x: 360, y: 30), in: areas.reversed())?.id == 4)
        #expect(TipHitTest.area(at: CGPoint(x: 250, y: 30), in: areas)?.id == 1)
        // the edge: a rectangle owns its lower left, not its upper right
        #expect(TipHitTest.area(at: CGPoint(x: 410, y: 30), in: areas) == nil)
    }

    @Test("TIP-01 the tooltip goes below and right of the pointer, above it near the screen's bottom, and stays on the screen")
    func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 40)
        let normal = TipPlacement.origin(pointer: CGPoint(x: 400, y: 400), size: size, in: screen)
        #expect(normal == CGPoint(x: 410, y: 344))
        let low = TipPlacement.origin(pointer: CGPoint(x: 400, y: 30), size: size, in: screen)
        #expect(low.y > 30)
        let right = TipPlacement.origin(pointer: CGPoint(x: 990, y: 400), size: size, in: screen)
        #expect(right.x == 800)
        let corner = TipPlacement.origin(pointer: CGPoint(x: 995, y: 5), size: size, in: screen)
        #expect(screen.contains(CGRect(origin: corner, size: size)))
    }
}

@Suite("TipController")
@MainActor
struct TipControllerTests {
    /// A flipped page, like the one SwiftUI scrolls.
    private final class Page: NSView {
        override var isFlipped: Bool { true }
    }

    /// A window with a scrolled page of rows, each with a title, a weight and a bar anchor and one over the whole row.
    @MainActor private struct Scene {
        let window: NSWindow
        let scroll: NSScrollView
        let page: Page
        let controller: TipController

        init() throws {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
            window.contentView = content
            scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            page = Page(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
            scroll.documentView = page
            content.addSubview(scroll)
            window.orderBack(nil)
            for index in 0..<10 {
                let row = Page(frame: NSRect(x: 0, y: CGFloat(index) * 60, width: 400, height: 60))
                page.addSubview(row)
                Self.anchor("row \(index)", NSRect(x: 0, y: 0, width: 400, height: 60), in: row)
                Self.anchor("title \(index)", NSRect(x: 10, y: 10, width: 200, height: 20), in: row)
                Self.anchor("bar \(index)", NSRect(x: 220, y: 15, width: 80, height: 5), in: row)
                Self.anchor("weight \(index)", NSRect(x: 350, y: 10, width: 30, height: 20), in: row)
            }
            controller = try #require(TipHub.shared.existingController(for: window))
            controller.requiresActiveApp = false
        }

        private static func anchor(_ text: String, _ frame: NSRect, in row: NSView) {
            let view = TipAnchorView(frame: frame)
            view.source = .text(text)
            row.addSubview(view)
        }

        /// the window's point of a page point
        func windowPoint(_ x: CGFloat, row: Int, y: CGFloat) -> NSPoint {
            page.convert(NSPoint(x: x, y: CGFloat(row) * 60 + y), to: nil)
        }

        func text(at point: NSPoint) -> String? {
            guard case .text(let text)? = controller.resolve(at: point)?.source else { return nil }
            return text
        }

        func scroll(to offset: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @Test("TIP-01 the title, the bar and the weight of a row each give their own tooltip, the row's gap its own, and a scroll leaves no old frame behind")
    func hitTestFollowsTheScroll() throws {
        let scene = try Scene()
        // row 1 starts at page y 60
        #expect(scene.text(at: scene.windowPoint(100, row: 1, y: 20)) == "title 1")
        #expect(scene.text(at: scene.windowPoint(250, row: 1, y: 17)) == "bar 1")
        #expect(scene.text(at: scene.windowPoint(360, row: 1, y: 20)) == "weight 1")
        #expect(scene.text(at: scene.windowPoint(320, row: 1, y: 50)) == "row 1")

        let before = scene.windowPoint(100, row: 1, y: 20)
        scene.scroll(to: 60)
        // the same page point moved up with the page, and the window point it left now shows the next row
        #expect(scene.text(at: scene.windowPoint(100, row: 1, y: 20)) == "title 1")
        #expect(scene.text(at: before) == "title 2")
        #expect(scene.text(at: scene.windowPoint(360, row: 2, y: 20)) == "weight 2")
        // row 0 is scrolled out: its frames are above the scroll view, where nothing is shown
        #expect(scene.text(at: scene.windowPoint(100, row: 0, y: 20)) == nil)
        // and below the scroll view's end nothing either
        #expect(scene.text(at: scene.windowPoint(100, row: 5, y: 20)) == nil)
    }

    @Test("TIP-01 an anchor that is hidden, or sits in a hidden or transparent view, gives no tooltip")
    func hiddenAnchors() throws {
        let scene = try Scene()
        let point = scene.windowPoint(100, row: 0, y: 20)
        #expect(scene.text(at: point) == "title 0")
        let row = try #require(scene.page.subviews.first)
        row.alphaValue = 0
        #expect(scene.text(at: point) == nil)
        row.alphaValue = 1
        row.isHidden = true
        #expect(scene.text(at: point) == nil)
    }

    @Test("TIP-01 the tooltip shows half a second after the rest on the area under the pointer, hides at once on leaving it, and waits again")
    func showsAndHides() throws {
        let scene = try Scene()
        let controller = scene.controller
        controller.pointerMoved(at: scene.windowPoint(100, row: 1, y: 20))
        #expect(controller.shownAnchor == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        #expect(controller.shownAnchor == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        #expect(Self.shown(controller) == "title 1")
        // onto the weight: gone this very moment, and back after another rest
        controller.pointerMoved(at: scene.windowPoint(360, row: 1, y: 20))
        #expect(controller.shownAnchor == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        #expect(controller.shownAnchor == nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        #expect(Self.shown(controller) == "weight 1")
        // a scroll hides it, and none shows within 0.3 s of the last scroll event
        controller.scrolled()
        #expect(controller.shownAnchor == nil)
        controller.interrupt()
    }

    @Test("TIP-01 the bubble fits the whole text: one line when it fits, more lines at 280 pt, never cut")
    func bubbleSizes() {
        let short = TipBubble.measure("The people with items in this slot")
        let long = TipBubble.measure(
            "No weight, so it adds nothing to the progress of the slot, and a longer tail that needs a third line to be read whole")
        let line = TipBubble.measure("x").height
        #expect(short.height == line)
        #expect(short.width > 150)
        #expect(long.height >= 3 * line)
        #expect(long.width <= TipBubble.wrapWidth + 1)
        // the user's second screenshot: it fits on one line or wraps, but the height always covers all the text
        let sentence = TipBubble.measure("No weight, so it adds nothing to the progress")
        #expect(sentence.height >= line)
    }

    private static func shown(_ controller: TipController) -> String? {
        if case .text(let text)? = controller.shownAnchor?.source { return text }
        return nil
    }
}

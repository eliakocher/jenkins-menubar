import CoreGraphics
import Foundation

// The pure rules of the app's tooltip (see ``View/tip(_:)``): which area the pointer is on, when the tooltip may show,
// and where it goes. No AppKit here, so the tests drive them with plain dates and rectangles.

/// An area a tooltip is registered for, in the window's coordinates.
struct TipArea: Equatable {
    /// tells the area apart from the others in one hit test
    let id: Int
    let frame: CGRect
    /// how deep the area's view sits in the window; of two areas of one size, the deeper one is the inner
    var depth = 0
}

enum TipHitTest {
    /// Returns the area the point is on: the innermost one when areas overlap (the smallest; of equal sizes the deeper
    /// one, then the later), `nil` on none. Frames are compared as given, so they all have to be in one coordinate space.
    static func area(at point: CGPoint, in areas: [TipArea]) -> TipArea? {
        var best: TipArea?
        for area in areas where area.frame.contains(point) {
            guard let current = best else {
                best = area
                continue
            }
            if isInner(area, than: current) {
                best = area
            }
        }
        return best
    }

    private static func isInner(_ area: TipArea, than other: TipArea) -> Bool {
        let size = area.frame.width * area.frame.height
        let otherSize = other.frame.width * other.frame.height
        if size != otherSize { return size < otherSize }
        if area.depth != other.depth { return area.depth > other.depth }
        return area.id > other.id
    }
}

/// When the tooltip shows and hides: a small state machine on the clock's dates, so it needs no timer of its own.
///
/// The pointer has to rest for ``delay`` on an area; not a moment before the scroll that moved the page under it ended
/// for ``scrollQuiet``. It hides at once when the pointer leaves its area or the window, on a scroll, a click or a key.
/// Each method returns whether the tooltip has to hide now, for the ones that can hide it.
struct TipTiming: Equatable {
    /// how long the pointer rests before the tooltip shows
    static let delay: TimeInterval = 0.5
    /// how long after the last scroll event the tooltip stays away
    static let scrollQuiet: TimeInterval = 0.3

    private(set) var isShown = false
    private var restStart: Date?
    private var lastScroll: Date?

    /// whether a tooltip is due: the pointer moved or scrolled and hasn't had its rest yet
    var isWaiting: Bool { !isShown && restStart != nil }

    /// The pointer moved. A tooltip that is shown stays while the pointer stays on its area; else it hides and the rest
    /// starts again.
    ///
    /// - Parameters:
    ///   - now: the time of the move
    ///   - inShownArea: whether the pointer is on the area the shown tooltip belongs to
    @discardableResult
    mutating func pointerMoved(at now: Date, inShownArea: Bool) -> Bool {
        if isShown && inShownArea { return false }
        let hides = isShown
        isShown = false
        restStart = now
        return hides
    }

    /// The page scrolled under the pointer: the tooltip hides, and the rest starts after the scroll.
    @discardableResult
    mutating func scrolled(at now: Date) -> Bool {
        let hides = isShown
        isShown = false
        lastScroll = now
        restStart = now
        return hides
    }

    /// A click, a key, or the pointer left the window: the tooltip hides and none shows until the pointer moves again.
    @discardableResult
    mutating func interrupted() -> Bool {
        let hides = isShown
        isShown = false
        restStart = nil
        return hides
    }

    /// Returns how long until a tooltip may show, `0` when it may now; `nil` when none is due.
    func delayLeft(at now: Date) -> TimeInterval? {
        guard !isShown, let restStart else { return nil }
        var due = restStart.addingTimeInterval(Self.delay)
        if let lastScroll {
            due = max(due, lastScroll.addingTimeInterval(Self.scrollQuiet))
        }
        return max(0, due.timeIntervalSince(now))
    }

    /// The tooltip is on screen now.
    mutating func didShow() {
        isShown = true
    }

    /// The pointer rests on nothing with a tooltip: nothing is due until it moves again.
    mutating func nothingToShow() {
        restStart = nil
    }
}

enum TipPlacement {
    /// the gap between the pointer and the tooltip
    static let offset = CGPoint(x: 10, y: 16)

    /// Returns where the tooltip's lower left corner goes, in screen coordinates (y up): below and right of the pointer,
    /// above it when there is no room below, and inside the screen sideways.
    ///
    /// - Parameters:
    ///   - pointer: the pointer on the screen
    ///   - size: the tooltip's size
    ///   - screen: the part of the screen the tooltip may use
    static func origin(pointer: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        var x = pointer.x + offset.x
        var y = pointer.y - offset.y - size.height
        if y < screen.minY {
            y = pointer.y + offset.y - 4
        }
        x = min(x, screen.maxX - size.width)
        x = max(x, screen.minX)
        y = min(y, screen.maxY - size.height)
        y = max(y, screen.minY)
        return CGPoint(x: x, y: y)
    }
}

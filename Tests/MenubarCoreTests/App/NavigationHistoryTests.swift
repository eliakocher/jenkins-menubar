import Foundation
import Testing

@testable import MenubarCore

@Suite("NavigationHistory")
struct NavigationHistoryTests {
    private static func place(_ name: String) -> NavigationLocation {
        NavigationLocation(section: .mergeRequests, item: name)
    }

    private static let a = place("a")
    private static let b = place("b")
    private static let c = place("c")
    private static let d = place("d")

    private static func history(visiting places: [NavigationLocation]) -> NavigationHistory {
        var history = NavigationHistory(start: a)
        for place in places {
            history.visit(place)
        }
        return history
    }

    @Test("WIN-08 a visit pushes the place, and the place already shown is no visit")
    func visit() {
        var history = Self.history(visiting: [Self.b])
        #expect(history.current == Self.b)
        #expect(history.backEntries == [Self.a])
        #expect(!history.canGoForward)
        let repeated = history.visit(Self.b)
        #expect(!repeated)
        #expect(history.backEntries == [Self.a])
        // The same section with another selection, an item under "Opened" and a bare section are all different places.
        let bare = history.visit(NavigationLocation(section: .mergeRequests))
        #expect(bare)
        let opened = history.visit(NavigationLocation(section: .mergeRequests, opened: "x"))
        #expect(opened)
        #expect(history.backStack.count == 3)
    }

    @Test("WIN-08 back and forward walk the places in order, and stop at the ends")
    func walk() {
        var history = Self.history(visiting: [Self.b, Self.c])
        #expect(history.back() == Self.b)
        #expect(history.back() == Self.a)
        #expect(history.back() == nil)
        #expect(history.current == Self.a)
        #expect(history.forwardEntries == [Self.b, Self.c])
        #expect(history.forward() == Self.b)
        #expect(history.forward() == Self.c)
        #expect(history.forward() == nil)
        #expect(history.backEntries == [Self.b, Self.a])
    }

    @Test("WIN-08 going somewhere new after Back drops the places ahead")
    func branch() {
        var history = Self.history(visiting: [Self.b, Self.c])
        _ = history.back()
        history.visit(Self.d)
        #expect(!history.canGoForward)
        #expect(history.backEntries == [Self.b, Self.a])
        #expect(history.back() == Self.b)
    }

    @Test("WIN-08 remembers the last 50 places, the oldest drop out")
    func cap() {
        var history = NavigationHistory(start: Self.place("0"))
        for number in 1...80 {
            history.visit(Self.place(String(number)))
        }
        #expect(history.backStack.count == NavigationHistory.limit)
        #expect(history.backStack.first == Self.place("30"))
        #expect(history.current == Self.place("80"))
    }

    @Test("WIN-08 back and forward skip places that are gone, and drop them")
    func skipsVanished() {
        var history = Self.history(visiting: [Self.b, Self.c, Self.d])
        let gone: Set<NavigationLocation> = [Self.b, Self.c]
        #expect(history.back(isValid: { !gone.contains($0) }) == Self.a)
        #expect(history.backStack.isEmpty)
        #expect(history.forwardEntries == [Self.d])
        // Nothing valid left: nothing moves.
        var onlyGone = Self.history(visiting: [Self.b])
        #expect(onlyGone.back(isValid: { _ in false }) == nil)
        #expect(onlyGone.current == Self.b)
        // Forward skips too.
        var ahead = Self.history(visiting: [Self.b, Self.c, Self.d])
        _ = ahead.back()
        _ = ahead.back()
        _ = ahead.back()
        #expect(ahead.forward(isValid: { $0 != Self.b }) == Self.c)
        #expect(ahead.backEntries == [Self.a])
    }

    @Test("WIN-08 a jump from the menu keeps the order of everything in between")
    func jump() {
        var history = Self.history(visiting: [Self.b, Self.c, Self.d])
        let toB = history.jump(to: Self.b)
        #expect(toB)
        #expect(history.current == Self.b)
        #expect(history.backEntries == [Self.a])
        #expect(history.forwardEntries == [Self.c, Self.d])
        // Forward again to the far end, and back to the start: the same walk as one step at a time.
        let toD = history.jump(to: Self.d)
        #expect(toD)
        #expect(history.backEntries == [Self.c, Self.b, Self.a])
        #expect(!history.canGoForward)
        let unknown = history.jump(to: Self.place("never visited"))
        #expect(!unknown)
    }
}

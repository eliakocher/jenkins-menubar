import Testing

@testable import MenubarUI

/// The log's own selection (the rows draw their highlight inside the content width, so a `List` no longer selects).
@Suite("ActivityListSelection")
struct ActivityListSelectionTests {
    private static let ids = ["a", "b", "c", "d", "e"]

    @Test("LOG-04 a click selects one entry, ⌘ toggles one, ⇧ extends from the anchor")
    func clicks() {
        var state = ActivityListSelection()
        state.click("b", in: Self.ids, toggle: false, extend: false)
        #expect(state.selected == ["b"])
        state.click("d", in: Self.ids, toggle: true, extend: false)
        #expect(state.selected == ["b", "d"])
        state.click("d", in: Self.ids, toggle: true, extend: false)
        #expect(state.selected == ["b"])
        // The ⌘-click moved the anchor to d.
        state.click("e", in: Self.ids, toggle: false, extend: true)
        #expect(state.selected == ["d", "e"])
        state.click("b", in: Self.ids, toggle: false, extend: false)
        state.click("e", in: Self.ids, toggle: false, extend: true)
        #expect(state.selected == ["b", "c", "d", "e"])
        // Shift from a later anchor goes the other way.
        state.click("d", in: Self.ids, toggle: false, extend: false)
        state.click("a", in: Self.ids, toggle: false, extend: true)
        #expect(state.selected == ["a", "b", "c", "d"])
    }

    @Test(
        "LOG-04 the arrow keys move by one and stop at the ends, ⇧ extends, an empty selection starts at the edge",
        arguments: [
            (start: "c", step: ActivityListSelection.Step.previous, extend: false, expected: Set(["b"])),
            (start: "c", step: .next, extend: false, expected: ["d"]),
            (start: "a", step: .previous, extend: false, expected: ["a"]),
            (start: "e", step: .next, extend: false, expected: ["e"]),
            (start: "b", step: .next, extend: true, expected: ["b", "c"]),
            (start: "c", step: .first, extend: false, expected: ["a"]),
            (start: "c", step: .last, extend: true, expected: ["c", "d", "e"]),
        ] as [(start: String, step: ActivityListSelection.Step, extend: Bool, expected: Set<String>)])
    func keys(start: String, step: ActivityListSelection.Step, extend: Bool, expected: Set<String>) {
        var state = ActivityListSelection()
        state.click(start, in: Self.ids, toggle: false, extend: false)
        state.move(step, in: Self.ids, extend: extend)
        #expect(state.selected == expected)

        var empty = ActivityListSelection()
        #expect(empty.move(.next, in: Self.ids, extend: false) == "a")
        var none = ActivityListSelection()
        #expect(none.move(.previous, in: [], extend: false) == nil)
    }
}

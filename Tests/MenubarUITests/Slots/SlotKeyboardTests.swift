import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("SlotKeyboard")
@MainActor
struct SlotKeyboardTests {
    /// the gallery's plan: 2026.45 has a commitment with the design epic's items and #36, then the search epic's items
    private static let slots: [SlotSummary] = {
        let f = Fixtures()
        let items = SlotsGalleryView.items(f.workItemsScreen)
        let related = SlotsGalleryView.related(f.workItemsScreen)
        return SlotsGalleryView.plan(f, items: items, related: related, today: SlotsGalleryView.today).slots
    }()

    private static func ids(_ numbers: [Int]) -> [String] {
        numbers.map { "group/subgroup/project#\($0)" }
    }

    @Test("SLOT-09 the arrow keys walk a card in the order it is drawn: the commitment's epics first, then the rest, planned items in place")
    func walksACardTopToBottom() throws {
        let slot = try #require(Self.slots.first { $0.name.description == "2026.45" })
        #expect(SlotKeyboard.order(of: slot) == Self.ids([31, 35, 36, 44, 28]))
        // the same items the card's tables draw, once each
        let drawn = (slot.commitments.flatMap(\.groups) + slot.otherGroups).flatMap(\.items).map(\.id)
        #expect(SlotKeyboard.order(of: slot) == drawn)
    }

    @Test("SLOT-09 the keys go on from a card's last row to the next open card's first, skip closed and empty cards")
    func walksAcrossCards() {
        let open: (SlotSummary) -> Bool = { $0.name.description != "2026.48" }
        let ids = SlotKeyboard.visibleIDs(slots: Self.slots, isExpanded: open)
        #expect(ids == Self.ids([31, 35, 36, 44, 28, 60, 61, 70]))
        // down from 2026.45's last row lands on 2026.51's first, up goes back
        #expect(SlotKeyboard.neighbor(of: Self.ids([28])[0], by: 1, in: ids) == Self.ids([60])[0])
        #expect(SlotKeyboard.neighbor(of: Self.ids([60])[0], by: -1, in: ids) == Self.ids([28])[0])
        // nothing before the first row, nothing after the last, nothing for a row that isn't on screen
        #expect(SlotKeyboard.neighbor(of: Self.ids([31])[0], by: -1, in: ids) == nil)
        #expect(SlotKeyboard.neighbor(of: Self.ids([70])[0], by: 1, in: ids) == nil)
        #expect(SlotKeyboard.neighbor(of: Self.ids([51])[0], by: 1, in: ids) == nil)
        #expect(SlotKeyboard.visibleIDs(slots: Self.slots, isExpanded: { _ in false }).isEmpty)
    }
}

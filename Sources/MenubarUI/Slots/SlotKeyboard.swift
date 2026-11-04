import MenubarCore
import SwiftUI

/// What has the keyboard focus in the Slots list: a slot's header, or an item's row (SLOT-09).
enum SlotFocus: Hashable {
    case header(SlotName)
    case item(WorkItem.ID)
}

/// The order the arrow keys walk the item rows in, the order the rows are on screen. Pure, so the tests check it.
enum SlotKeyboard {
    /// Returns the items of one slot as its card draws them: the commitments first, each with its epics and their items,
    /// then the epics of the items no commitment has. An item under two commitments counts once, at its first place.
    ///
    /// - Parameter slot: the slot
    /// - Returns: the items' ids from the top of the card to the bottom
    static func order(of slot: SlotSummary) -> [WorkItem.ID] {
        guard !slot.allItems.isEmpty else { return [] }
        var seen = Set<WorkItem.ID>()
        var ids: [WorkItem.ID] = []
        let groups = slot.commitments.flatMap(\.groups) + slot.otherGroups
        for item in groups.flatMap(\.items) where seen.insert(item.id).inserted {
            ids.append(item.id)
        }
        return ids
    }

    /// Returns the item rows on screen, slot after slot: only the cards that are open have rows.
    ///
    /// - Parameters:
    ///   - slots: the slots, in the page's order
    ///   - isExpanded: whether a slot's card is open
    static func visibleIDs(slots: [SlotSummary], isExpanded: (SlotSummary) -> Bool) -> [WorkItem.ID] {
        var seen = Set<WorkItem.ID>()
        return slots.filter(isExpanded).flatMap(order(of:)).filter { seen.insert($0).inserted }
    }

    /// Returns the row `delta` places from an item: `nil` at either end of the list, and for an item that isn't in it.
    ///
    /// - Parameters:
    ///   - id: the item the keys are on
    ///   - delta: -1 for up, 1 for down
    ///   - ids: the rows on screen, see ``visibleIDs(slots:isExpanded:)``
    static func neighbor(of id: WorkItem.ID, by delta: Int, in ids: [WorkItem.ID]) -> WorkItem.ID? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        let target = index + delta
        return ids.indices.contains(target) ? ids[target] : nil
    }
}

/// What the rows and headers of the slot cards need for the keys, from the list that owns the focus.
struct SlotKeys {
    /// the list's focus, so a key can move it from one row to the next
    var focus: FocusState<SlotFocus?>.Binding
    /// whether the last input was a key: the focus shows only then, as the header's chevron always did
    var isKeyboard: Bool
    var setKeyboard: (Bool) -> Void
    /// returns the row above or below an item, `nil` at the ends
    var neighbor: (WorkItem.ID, Int) -> WorkItem.ID?
    /// selects an item, puts the focus on its row and scrolls it into view
    var go: (WorkItem.ID) -> Void
    /// closes the card of the row and puts the focus on its header; set by the card
    var fold: () -> Void = {}
    /// returns the first row of the card, `nil` for a closed or empty one; set by the card
    var first: () -> WorkItem.ID? = { nil }
    /// a row appeared: it takes the focus when the keys asked for it before the row existed (the rows are made as they
    /// scroll into view, so the row a key goes to may not be there yet)
    var focusOnAppear: (WorkItem.ID) -> Void = { _ in }
}

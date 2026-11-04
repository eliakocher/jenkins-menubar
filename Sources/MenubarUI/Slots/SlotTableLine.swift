import MenubarCore
import SwiftUI

/// One line of an open slot card's table, flat, so a lazy stack makes only the lines on screen: the commitments first,
/// each with its epics and their items, then "Not in a commitment" when there are commitments, and the epics of the
/// items no commitment has (SLOT-08, SLOT-14). Pure, so the tests check the order against the keyboard's.
enum SlotTableLine: Identifiable {
    case commitment(SlotCommitmentGroup, id: String)
    case epic(SlotEpicGroup, id: String, indented: Bool)
    case item(SlotItem, id: String, indented: Bool)
    case withoutCommitment(id: String)

    /// how far the epics and items of a commitment are indented
    static let indent: CGFloat = 14

    /// the line's identity, unique in the card: an item's own id, which lets the list scroll to it, for its first line, and
    /// "id#1", "id#2" for a line that shows again (an item under a second commitment)
    var id: String {
        switch self {
        case .commitment(_, let id): id
        case .epic(_, let id, _): id
        case .item(_, let id, _): id
        case .withoutCommitment(let id): id
        }
    }

    /// Returns the lines of a slot's card, top to bottom.
    static func lines(of slot: SlotSummary) -> [SlotTableLine] {
        var lines: [SlotTableLine] = []
        var copies: [String: Int] = [:]
        /// the id for a line: the base id the first time, then numbered
        func unique(_ base: String) -> String {
            let count = copies[base, default: 0]
            copies[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }
        func append(_ group: SlotEpicGroup, scope: String, indented: Bool) {
            lines.append(.epic(group, id: unique("epic:\(scope):\(group.id)"), indented: indented))
            for item in group.items {
                lines.append(.item(item, id: unique(item.id), indented: indented))
            }
        }
        for commitment in slot.commitments {
            lines.append(.commitment(commitment, id: unique("commitment:\(commitment.id)")))
            for group in commitment.groups {
                append(group, scope: commitment.id, indented: true)
            }
        }
        let others = slot.otherGroups
        if !slot.commitments.isEmpty, !others.isEmpty {
            lines.append(.withoutCommitment(id: unique("withoutCommitment")))
        }
        for group in others {
            append(group, scope: "other", indented: false)
        }
        return lines
    }
}

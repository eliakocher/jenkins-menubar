import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("SlotTableLine")
@MainActor
struct SlotTableLineTests {
    private static let slots: [SlotSummary] = {
        let f = Fixtures()
        let items = SlotsGalleryView.items(f.workItemsScreen)
        let related = SlotsGalleryView.related(f.workItemsScreen)
        return SlotsGalleryView.plan(f, items: items, related: related, today: SlotsGalleryView.today).slots
    }()

    @Test("SLOT-09 the card's lines come in the order the keys walk, with unique ids a scroll can go to")
    func linesFollowTheKeys() throws {
        for slot in Self.slots {
            let lines = SlotTableLine.lines(of: slot)
            #expect(Set(lines.map(\.id)).count == lines.count)
            var itemIDs: [String] = []
            for case .item(let item, _, _) in lines {
                itemIDs.append(item.id)
            }
            // an item under two commitments is a line under each, the keys count it once
            var seen = Set<String>()
            #expect(itemIDs.filter { seen.insert($0).inserted } == SlotKeyboard.order(of: slot))
        }
    }

    @Test("SLOT-14 a commitment's epics and items are indented, and the rest follows under a title when there are commitments")
    func commitmentsFirst() throws {
        let slot = try #require(Self.slots.first { $0.name.description == "2026.45" })
        let lines = SlotTableLine.lines(of: slot)
        guard case .commitment = lines.first else {
            Issue.record("the commitment leads")
            return
        }
        var markerIndex: Int?
        for (index, line) in lines.enumerated() {
            if case .withoutCommitment = line { markerIndex = index }
        }
        let marker = try #require(markerIndex)
        for line in lines[1..<marker] {
            switch line {
            case .epic(_, _, let indented), .item(_, _, let indented): #expect(indented)
            default: break
            }
        }
        for line in lines[(marker + 1)...] {
            switch line {
            case .epic(_, _, let indented), .item(_, _, let indented): #expect(!indented)
            default: Issue.record("only epics and items follow")
            }
        }
    }

    @Test("SLOT-09 an item shown under two commitments keeps its own id on the first line, the second gets another")
    func repeatedItem() throws {
        var slot = try #require(Self.slots.first { $0.name.description == "2026.45" })
        let first = try #require(slot.commitments.first)
        slot.commitments.append(first)
        let lines = SlotTableLine.lines(of: slot)
        let id = try #require(first.items.first?.id)
        let ids = lines.map(\.id)
        #expect(ids.filter { $0 == id }.count == 1)
        #expect(ids.contains("\(id)#1"))
        #expect(Set(ids).count == ids.count)
    }
}

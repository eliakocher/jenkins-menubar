import Foundation
import Testing

@testable import MenubarCore

/// The sidebar's order of the sections (WIN-01).
@Suite("Section order")
struct SectionOrderTests {
    private typealias Section = AppRoute.Section

    @Test("WIN-01 an empty order is the default; a saved order drops unknown names and repeats, and new sections take their default place")
    func mergesSavedOrder() {
        let all = Section.allCases
        #expect(SectionOrder.merged(stored: "") == all)
        // A reordered list.
        #expect(
            SectionOrder.merged(stored: "slots,digest,pipelines,merge-requests,work-items,activity,workspaces")
                == [.slots, .digest, .pipelines, .inbox, .mergeRequests, .workItems, .activity, .workspaces])
        // The Inbox, added later, takes its default place: right after Pipelines, so ⌘1 stays Pipelines.
        // A removed section's name, a repeat and a blank are ignored; the sections left out come back.
        let dropped = SectionOrder.merged(stored: "slots,gone,slots, ,pipelines")
        #expect(dropped.filter { $0 == .slots }.count == 1)
        #expect(Set(dropped) == Set(all))
        #expect(dropped.first == .slots)
        // New sections: a short saved order lacks the later sections, each comes after its default predecessor.
        #expect(SectionOrder.merged(stored: "digest,pipelines,work-items") == [.digest, .pipelines, .inbox, .mergeRequests, .workItems, .activity, .workspaces, .slots])
        // A section whose predecessor is missing too goes to the start.
        #expect(SectionOrder.merged(stored: "slots", sections: [.pipelines, .slots, .digest]) == [.pipelines, .slots, .digest])
        #expect(SectionOrder.merged(stored: "digest,slots", sections: [.pipelines, .slots, .digest]) == [.pipelines, .digest, .slots])
    }

    @Test("WIN-01 the default order is kept as nothing, so a new section lands in its place later")
    func keepsDefaultAsEmpty() {
        #expect(SectionOrder.stored(Section.allCases) == "")
        let swapped = Section.allCases.reversed() as [Section]
        #expect(SectionOrder.merged(stored: SectionOrder.stored(swapped)) == swapped)
    }

    @Test("WIN-01 a drag moves the shown rows, and a hidden section keeps its place")
    func dragKeepsHiddenPlace() {
        let order: [Section] = [.pipelines, .digest, .mergeRequests, .workItems, .slots]
        let shown = SectionOrder.ordered([.pipelines, .mergeRequests, .workItems, .slots], by: order)
        #expect(shown == [.pipelines, .mergeRequests, .workItems, .slots])
        // Slots dragged to the top.
        let moved = SectionOrder.moving(order, shown: shown, from: [3], to: 0)
        #expect(moved == [.slots, .digest, .pipelines, .mergeRequests, .workItems])
        // Pipelines dragged below Merge Requests (SwiftUI's destination is the offset it lands before).
        #expect(SectionOrder.moving(order, shown: shown, from: [0], to: 2) == [.mergeRequests, .digest, .pipelines, .workItems, .slots])
        // Dragged to the end.
        #expect(SectionOrder.moving(order, shown: shown, from: [0], to: 4) == [.mergeRequests, .digest, .workItems, .slots, .pipelines])
        // Nothing moves when dropped on itself.
        #expect(SectionOrder.moving(order, shown: shown, from: [1], to: 2) == order)
    }

    @Test("WIN-01 the order is in the personal settings backup")
    func isBackedUp() {
        #expect(PersonalSettingsBackup.allowlist.contains { $0.key == SectionOrder.key && $0.type == .string })
    }
}

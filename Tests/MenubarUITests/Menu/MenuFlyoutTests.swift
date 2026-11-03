import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuFlyout")
@MainActor
struct MenuFlyoutTests {
    private static let fixtures = Fixtures()

    @Test("APP-06 a flyout lists at most 20 entries, then Show All N in Window")
    func capsTheEntries() {
        let f = Self.fixtures
        let mine = (1...16).map { f.finished("MR-\($0)", 1, "Build \($0)", .success, durationMinutes: 10, finishedMinutesAgo: Double($0)) }
        let watched = (17...25).map {
            f.finished("MR-\($0)", 1, "Build \($0)", .success, durationMinutes: 10, finishedMinutesAgo: Double($0), kind: .watched)
        }
        let flyout = MenuFlyout(f.panel(mine: mine, watched: watched), area: .pipelines)
        #expect(flyout.total == 25)
        #expect(flyout.entries.count == MenuFlyout.cap)
        // My Builds whole, then as many watched as fit.
        #expect(flyout.sections.map(\.entries.count) == [16, 4])
        // The header still counts the whole section.
        #expect(flyout.sections.map(\.count) == ["16", "9"])
        #expect(flyout.commands.contains(.showInWindow(all: 25)))
        #expect(flyout.commands.map(\.title).contains("Show All 25 in Window"))
    }

    @Test("APP-06 a click on an entry shows it in the window, with Option it opens the page in the browser")
    func entryDestinations() {
        let f = Self.fixtures
        let data = f.panel(mine: f.typicalBuilds)
        let entries = [PanelAreaPick.pipelines, .mergeRequests, .workItems].compactMap {
            MenuFlyout(data, area: $0.area).entries.first
        }
        #expect(entries.count == 3)
        for entry in entries {
            #expect(entry.destination(option: false) == .window(entry.selection))
            #expect(entry.url != nil)
            #expect(entry.destination(option: true) == .browser(entry.url!))
        }
        #expect(entries.map(\.selection.section) == [.pipelines, .mergeRequests, .workItems])
        var withoutPage = entries[0]
        withoutPage.url = nil
        #expect(withoutPage.destination(option: true) == .window(withoutPage.selection))
    }

    @Test("APP-06 the work items flyout has no symbol column: the MR is a chip on line 2, closed says Closed")
    func workItemRowsHaveNoSymbolColumn() throws {
        let w = Self.fixtures.workItemsScreen
        let closed = w.item(52, "Retire the old export dialog", state: .closed)
        let lists = WorkItemLists(committed: WorkItemList(count: 2, items: [w.item31, w.item28]), others: WorkItemList(count: 2, items: [w.item40, closed]))
        let flyout = MenuFlyout(w.data(lists, filters: WorkItemFilters(state: .all)).panel, area: .workItems)
        #expect(flyout.entries.count == 4)
        #expect(flyout.entries.allSatisfy { $0.symbol == nil })
        #expect(!flyout.hasSymbolColumn)
        let rows = flyout.entries.compactMap { entry -> WorkItemRowModel? in
            if case .workItem(let row) = entry.kind { row } else { nil }
        }
        // The chip counts the item's own MRs of the panel's data: #31 has !14 open, and !11 only mentions it.
        #expect(rows.first?.mergeRequestChip?.text == "!14")
        #expect(rows.last?.secondLine?.contains("Closed") == true)
    }
}

private enum PanelAreaPick {
    case pipelines, mergeRequests, workItems

    var area: MainWindowSection {
        switch self {
        case .pipelines: .pipelines
        case .mergeRequests: .mergeRequests
        case .workItems: .workItems
        }
    }
}

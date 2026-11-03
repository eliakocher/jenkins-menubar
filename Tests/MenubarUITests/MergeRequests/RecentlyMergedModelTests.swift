import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

/// The Recently Merged section of the Merge Requests list (MR-17): its rows, its fold and the detail of a merged MR.
@Suite("RecentlyMergedModel")
@MainActor
struct RecentlyMergedModelTests {
    private static let fixtures = Fixtures()

    @Test("MR-17 the Recently Merged rows say when, where and by whom, and the list model holds them apart")
    func rows() throws {
        let m = Self.fixtures.mergeRequestsScreen
        let model = MergeRequestsListModel(MergeRequestsData(m.panel(merged: m.recentlyMerged)))
        let merged = try #require(model.merged)
        #expect(merged.title == "Recently Merged" && merged.rows.map(\.mergeRequest.iid) == [31, 27, 19, 11])
        #expect(!model.sections.contains { $0.title == "Recently Merged" })

        // Mine, merged by me: no "by". Another's, merged by them. Mine, merged by Sam Lee: named.
        #expect(merged.rows[0].details == "!31 · merged 2h ago · into develop")
        #expect(merged.rows[1].details == "!27 · merged 20h ago · into develop · by Sam Lee")
        #expect(merged.rows[2].details == "!19 · merged 2d ago · into release/2.4 · by Sam Lee")
        #expect(merged.rows.allSatisfy { $0.isMerged && $0.age.isEmpty && $0.status.kind == .merged })
        #expect(merged.rows[0].shortReference == "!31")
        // A click finds the row, and a search narrows the section.
        #expect(model.row(merged.rows[1].id)?.mergeRequest.iid == 27)
        let searched = MergeRequestsListModel(MergeRequestsData(m.panel(merged: m.recentlyMerged)), query: "sidebar")
        #expect(searched.merged?.rows.map(\.mergeRequest.iid) == [27] && searched.sections.isEmpty)
        let nothing = MergeRequestsListModel(MergeRequestsData(m.panel(merged: m.recentlyMerged)), query: "zzz")
        #expect(nothing.merged == nil && nothing.findsNothing)
    }

    @Test("MR-17 a list with only merged MRs has no empty state, and none without merged ones is still empty")
    func emptyState() {
        let m = Self.fixtures.mergeRequestsScreen
        let only = MergeRequestsListModel(MergeRequestsData(m.panel([], merged: m.recentlyMerged)))
        #expect(only.sections.isEmpty && only.merged != nil && !only.showsEmpty)
        let none = MergeRequestsListModel(MergeRequestsData(m.panel([])))
        #expect(none.merged == nil && none.showsEmpty)
    }

    @Test("MR-17 Recently Merged starts folded under open sections, open alone and while searching, and keeps the click")
    func fold() {
        // The default.
        #expect(!RecentlyMergedFold.isExpanded(stored: "", hasOpenSections: true, searching: false))
        #expect(RecentlyMergedFold.isExpanded(stored: "", hasOpenSections: false, searching: false))
        // The user's choice wins, a search opens it.
        #expect(RecentlyMergedFold.isExpanded(stored: "open", hasOpenSections: true, searching: false))
        #expect(!RecentlyMergedFold.isExpanded(stored: "closed", hasOpenSections: false, searching: false))
        #expect(RecentlyMergedFold.isExpanded(stored: "closed", hasOpenSections: true, searching: true))
        // A click flips what shows.
        #expect(RecentlyMergedFold.toggled(stored: "", isExpanded: false) == "open")
        #expect(RecentlyMergedFold.toggled(stored: "open", isExpanded: true) == "closed")
    }

    @Test("MR-17 a merged MR stays selected and shows its detail after the list refresh moves it to Recently Merged")
    func selectionSurvivesTheRefresh() throws {
        let m = Self.fixtures.mergeRequestsScreen
        let selected = m.mr21
        // Before the merge: open. After the refresh: gone from the open lists, in the merged one.
        let before = MergeRequestDetailModel(MergeRequestsData(m.panel(m.sections)), selection: selected.id)
        #expect(before?.mergeRequest.iid == 21)
        var merged = selected
        merged.mergedAt = Self.fixtures.minutesAgo(1)
        merged.targetBranch = "develop"
        let open = m.sections.filter { $0.id != selected.id }
        let data = MergeRequestsData(m.panel(open, merged: [merged]))
        let after = try #require(MergeRequestDetailModel(data, selection: selected.id))
        #expect(after.status.kind == .merged && after.mergeRequest.iid == 21)
        // The list moved the row; the selection id is the same, so the list keeps it selected.
        let list = MergeRequestsListModel(data)
        #expect(list.row(selected.id)?.isMerged == true && list.merged?.rows.map(\.mergeRequest.iid) == [21])
        #expect(!list.sections.contains { $0.rows.contains { $0.id == selected.id } })
    }
}

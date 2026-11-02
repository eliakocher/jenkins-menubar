import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuPaneModel")
@MainActor
struct MenuPaneModelTests {
    private static let fixtures = Fixtures()

    @Test("APP-06 the merge requests summary says what asks something of me")
    func mergeRequestsSummary() {
        let f = Self.fixtures
        // !24 waits for my review, !21 is ready to merge, !19's pipeline runs, !17 I reviewed.
        let area = MenuPaneModel(f.panel()).areas[1]
        #expect(area.summaryText == "1 to review · 1 ready to merge")
        #expect(area.count == 4)
        #expect(area.problem == nil)

        let blocked = f.mergeRequests([
            f.mergeRequest(30, "Fix the export", status: .notApproved, pipeline: .failed),
            f.mergeRequest(31, "Rebase me", status: .conflict, pipeline: .success),
        ])
        #expect(MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: blocked))).areas[1].summaryText == "2 blocked")
        // Nothing asks something of me: the open count.
        let quiet = f.mergeRequests([f.mergeRequest(32, "A draft", status: .notApproved, draft: true)])
        #expect(MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: quiet))).areas[1].summaryText == "1 open")
        let none = MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: f.mergeRequests([])))).areas[1]
        #expect(none.summaryText == "None open")
        #expect(none.count == nil)
    }

    @Test("APP-06 the summaries read quietly while loading, without a token and offline")
    func quietStates() {
        let f = Self.fixtures
        let loading = MenuPaneModel(f.panel(
            mergeRequests: PanelData.MergeRequests(isLoading: true), workItems: PanelData.WorkItems(isLoading: true)))
        #expect(loading.areas[1].summaryText == "Loading…")
        #expect(loading.areas[1].isLoading)
        #expect(loading.areas[2].summaryText == "Loading…")

        let noToken = MenuPaneModel(f.panel(
            mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab)),
            workItems: PanelData.WorkItems(problem: .noToken(.gitLab))))
        #expect(noToken.areas[1].summaryText == "Needs a token")
        #expect(noToken.areas[1].problem == nil)
        #expect(noToken.areas[2].summaryText == "Needs a token")

        // MR-05: a rejected token marks the area, over the cached counts.
        var mergeRequests = PanelData.MergeRequests(list: f.mergeRequestsInAllSections, problem: .rejectedToken(.gitLab))
        let rejected = MenuPaneModel(f.panel(mergeRequests: mergeRequests)).areas[1]
        #expect(rejected.problem == Problem.rejectedToken(.gitLab).message)
        #expect(rejected.summaryText == "1 to review · 1 ready to merge")

        // Offline (OD-05): the cached counts, no marker, no spinner.
        mergeRequests.isLoading = true
        let offline = MenuPaneModel(f.panel(problem: .offline, mine: f.typicalBuilds, mergeRequests: mergeRequests))
        #expect(offline.problem?.text == Problem.offline.message)
        #expect(offline.areas[1].problem == nil)
        #expect(!offline.areas[1].isLoading)
        #expect(offline.areas[0].summaryText == "1 running · 1 failed")
    }
}

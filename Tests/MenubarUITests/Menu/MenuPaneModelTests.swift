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
        let area = MenuPaneModel(f.panel()).area(.mergeRequests)!
        #expect(area.summaryText == "1 to review · 1 ready to merge")
        #expect(area.count == 4)
        #expect(area.problem == nil)

        let blocked = f.mergeRequests([
            f.mergeRequest(30, "Fix the export", status: .notApproved, pipeline: .failed),
            f.mergeRequest(31, "Rebase me", status: .conflict, pipeline: .success),
        ])
        #expect(MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: blocked))).area(.mergeRequests)!.summaryText == "2 blocked")
        // Nothing asks something of me: the open count.
        let quiet = f.mergeRequests([f.mergeRequest(32, "A draft", status: .notApproved, draft: true)])
        #expect(MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: quiet))).area(.mergeRequests)!.summaryText == "1 open")
        let none = MenuPaneModel(f.panel(mergeRequests: PanelData.MergeRequests(list: f.mergeRequests([])))).area(.mergeRequests)!
        #expect(none.summaryText == "None open")
        #expect(none.count == nil)
    }

    @Test("APP-06 the summaries read quietly while loading, without a token and offline")
    func quietStates() {
        let f = Self.fixtures
        let loading = MenuPaneModel(f.panel(
            mergeRequests: PanelData.MergeRequests(isLoading: true), workItems: PanelData.WorkItems(isLoading: true)))
        #expect(loading.area(.mergeRequests)!.summaryText == "Loading…")
        #expect(loading.area(.mergeRequests)!.isLoading)
        #expect(loading.area(.workItems)!.summaryText == "Loading…")

        let noToken = MenuPaneModel(f.panel(
            mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab)),
            workItems: PanelData.WorkItems(problem: .noToken(.gitLab))))
        #expect(noToken.area(.mergeRequests)!.summaryText == "Needs a token")
        #expect(noToken.area(.mergeRequests)!.problem == nil)
        #expect(noToken.area(.workItems)!.summaryText == "Needs a token")

        // MR-05: a rejected token marks the area, over the cached counts.
        var mergeRequests = PanelData.MergeRequests(list: f.mergeRequestsInAllSections, problem: .rejectedToken(.gitLab))
        let rejected = MenuPaneModel(f.panel(mergeRequests: mergeRequests)).area(.mergeRequests)!
        #expect(rejected.problem == Problem.rejectedToken(.gitLab).message)
        #expect(rejected.summaryText == "1 to review · 1 ready to merge")

        // Offline (OD-05): the cached counts, no marker, no spinner.
        mergeRequests.isLoading = true
        let offline = MenuPaneModel(f.panel(problem: .offline, mine: f.typicalBuilds, mergeRequests: mergeRequests))
        #expect(offline.problem?.text == Problem.offline.message)
        #expect(offline.area(.mergeRequests)!.problem == nil)
        #expect(!offline.area(.mergeRequests)!.isLoading)
        #expect(offline.area(.pipelines)!.summaryText == "1 running · 1 failed")
    }

    @Test("INBOX-07 the pane's Inbox row counts what waits by group, and the flyout lists the newest first")
    func inboxRow() {
        let f = Self.fixtures
        var data = f.panel()
        data.inbox = f.inboxPanel
        let area = MenuPaneModel(data).area(.inbox)!
        // The fixture has the coffee break too (added 2026-11-03): 11 waiting, coffee first in the default group order.
        #expect(area.count == 11)
        #expect(area.summaryText.hasPrefix("coffee · 1 from Claude · 3 mentions · 2 to review"))
        let flyout = MenuFlyout(data, area: .inbox)
        #expect(flyout.total == 11 && flyout.entries.count == 11)
        #expect(flyout.entries.first?.title == "Claude answered: Why Did It Fail?")
        data.inbox = PanelData.Inbox()
        #expect(MenuPaneModel(data).area(.inbox)!.summaryText == "Inbox zero")
        #expect(MenuFlyout(data, area: .inbox).note == "Inbox Zero")
    }
}

/// The pane's rows from Settings → Menu Bar (APP-11).
@Suite("MenuPaneModel layout")
@MainActor
struct MenuPaneLayoutTests {
    private static let fixtures = Fixtures()

    @Test("APP-11 the pane's rows follow the layout: order, rows that are off, flyouts and their entries")
    func rowsFollowLayout() {
        let f = Self.fixtures
        let data = f.panel(mine: f.typicalBuilds)
        #expect(MenuPaneModel(data).areas.map(\.section) == [.pipelines, .inbox, .mergeRequests, .workItems])

        var layout = MenuBarLayout()
        layout.moveRows(from: [2], to: 0)
        layout.updateRow(.inbox) { $0.isOn = false }
        layout.updateRow(.workItems) { $0.showsFlyout = false }
        layout.updateRow(.pipelines) { $0.flyoutRows = 5 }
        layout.paneWidth = .compact
        let pane = MenuPaneModel(data, layout: layout)
        #expect(pane.areas.map(\.section) == [.mergeRequests, .pipelines, .workItems])
        #expect(pane.flyoutless == [.workItems])
        #expect(pane.area(.pipelines)?.flyoutRows == 5)
        #expect(pane.width == .compact)
        #expect(MenuPaneView.rows(of: pane).prefix(3) == [.area(.mergeRequests), .area(.pipelines), .area(.workItems)])

        // A flyout lists the row's number of entries, then Show All N in Window.
        let many = f.panel(mine: (1...8).map {
            f.finished("MR-\($0)", 1, "Build \($0)", .success, durationMinutes: 5, finishedMinutesAgo: Double($0))
        })
        let flyout = MenuFlyout(many, area: .pipelines, limit: 5)
        #expect(flyout.entries.count == 5)
        #expect(flyout.commands.contains(.showInWindow(all: 8)))

        // Without a flyout, → does nothing on the row and Return opens it in the window.
        var navigation = MenuNavigation()
        navigation.paneRows = MenuPaneView.rows(of: pane)
        navigation.flyoutless = pane.flyoutless
        navigation.highlight = .area(.workItems)
        #expect(navigation.handle(.right) == .none)
        #expect(navigation.openArea == nil)
        #expect(navigation.handle(.enter) == .activate(.area(.workItems)))
    }
}

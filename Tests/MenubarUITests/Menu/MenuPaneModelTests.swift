import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MenuPaneModel")
@MainActor
struct MenuPaneModelTests {
    private static let fixtures = Fixtures()

    @Test("APP-06 the pane shows a problem row, the three areas and the footer")
    func paneInOrder() {
        let f = Self.fixtures
        let pane = MenuPaneModel(f.panel(problem: .rejectedToken(.jenkins), mine: f.typicalBuilds))
        #expect(pane.problem?.text == "Jenkins rejected the token")
        #expect(pane.problem?.pane == .accounts)
        #expect(pane.areas.map(\.section) == [.pipelines, .mergeRequests, .workItems])
        #expect(pane.areas.map(\.title) == ["Pipelines", "Merge Requests", "Work Items"])
        // The sidebar's own symbols.
        #expect(pane.areas.map(\.symbol) == [MainWindowSection.pipelines, .mergeRequests, .workItems].map(\.systemImage))
        #expect(pane.footer.subtitle?.hasPrefix("Last checked ") == true)
        #expect(MenuPaneModel(f.panel(isChecking: true)).footer.subtitle == "Checking…")
        // The keys move over the linked problem row, the areas and the footer, in that order.
        #expect(MenuPaneView.rows(of: pane) == [
            .problem, .area(.pipelines), .area(.mergeRequests), .area(.workItems), .checkNow, .openWindow,
            .settings, .quit,
        ])

        // No problem, no row; the team values missing show their row alone, without areas (TEAM-03).
        #expect(MenuPaneModel(f.panel(mine: f.typicalBuilds)).problem == nil)
        let team = MenuPaneModel(f.panel(problem: .teamValuesMissing))
        #expect(team.problem?.pane == .team)
        #expect(team.areas.isEmpty)
    }

    @Test("APP-06 the pipelines summary counts the builds by state, then the watched ones")
    func pipelinesSummary() {
        let f = Self.fixtures
        let watched = f.finished(
            "MR-2", 14, "Retry the upload", .success, durationMinutes: 20, finishedMinutesAgo: 8, kind: .watched,
            author: "Sam Lee")
        let area = MenuPaneModel(f.panel(mine: f.typicalBuilds, watched: [watched])).areas[0]
        #expect(area.summaryText == "1 running · 1 failed · 1 passed · 1 watched")
        #expect(area.count == 3)
        // The status icon's symbols, in their colors.
        #expect(area.summary.first == .count(symbol: "hourglass", tint: .build(.running), text: "1 running"))
        #expect(area.summary[1] == .count(symbol: "xmark.circle.fill", tint: .build(.failed), text: "1 failed"))

        // Before the first check, without builds, and with no job of mine.
        let loading = MenuPaneModel(f.panel(hasLoaded: false, isChecking: true)).areas[0]
        #expect(loading.summaryText == "Checking Jenkins…")
        #expect(loading.isLoading)
        #expect(loading.count == nil)
        #expect(MenuPaneModel(f.panel(emptyState: .noJobs(user: "jdoe"))).areas[0].summaryText == "No builds by jdoe")
        #expect(MenuPaneModel(f.panel(emptyState: .noBuilds)).areas[0].summaryText == "No builds to show")
    }

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

    @Test("APP-06 the work items summary shows the slot, the committed and the open count")
    func workItemsSummary() {
        let f = Self.fixtures
        let area = MenuPaneModel(f.panel()).areas[2]
        #expect(area.summaryText == "Q1 · 2 committed · 45 open")
        // The slot is its value as a pill, in the slot label's GitLab color.
        guard case .pill(let slot)? = area.summary.first else {
            Issue.record("no slot pill in \(area.summary)")
            return
        }
        #expect(slot.title == "slot::Q1")
        #expect(slot.color == "#9B59B6")
        #expect(area.count == 2)

        // Without a committed label, one list: its count, as the sidebar's badge.
        var team = f.team
        team.committedLabel = ""
        let single = MenuPaneModel(f.panel(team: team)).areas[2]
        #expect(single.summaryText == "45 open")
        #expect(single.count == 45)
    }

    @Test("APP-06 the committed slot's pill is followed by the Slots section's countdown to its next date")
    func slotCountdown() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let team = TeamValues(slotLabelPrefix: "slot::")
        // 2026.45 releases on Monday 2 Nov, its code freeze was Friday 9 Oct, early access Monday 19 Oct
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
        let slot = LabelPillModel(Label(title: "slot::2026.45"))
        #expect(MenuPaneModel.countdown(of: slot, team: team, now: now, calendar: calendar) == "Release in 3 days")
        // a label that is no slot name with dates says nothing
        #expect(MenuPaneModel.countdown(of: LabelPillModel(Label(title: "slot::Q1")), team: team, now: now, calendar: calendar) == nil)
        #expect(MenuPaneModel.countdown(of: LabelPillModel(Label(title: "slot::2027.53")), team: team, now: now, calendar: calendar) == nil)
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

import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("PanelModel")
@MainActor
struct PanelModelTests {
    private static let fixtures = Fixtures()

    // MARK: APP-06

    @Test("APP-06 panel sections in order")
    func sectionsInOrder() {
        let f = Self.fixtures
        let watched = f.running("MR-2", 14, "Retry the upload", startedMinutesAgo: 8, estimateMinutes: 20, kind: .watched, author: "Sam Lee")
        let model = PanelModel(f.panel(problem: .rejectedToken(.jenkins), mine: f.typicalBuilds, watched: [watched]))
        #expect(model.sections == [.problems, .myBuilds, .watching, .allBuilds, .mergeRequests, .workItems])
        #expect(model.problems.map(\.text) == ["Jenkins rejected the token"])
        #expect(model.myBuilds?.rows.map(\.title) == ["Fix the login redirect after a timeout", "Add a retry to the export job"])

        // Watching shows only while a watched build shows; no problem, no row.
        #expect(PanelModel(f.panel(mine: f.typicalBuilds)).sections == [.myBuilds, .allBuilds, .mergeRequests, .workItems])
    }

    @Test("APP-06 panel sections in order: the summaries' text and the footer")
    func countsAndFooter() {
        let f = Self.fixtures
        // An update the app offers or fails to build is the main window's business, not the panel's.
        let model = PanelModel(f.panel(mine: f.typicalBuilds, hiddenCount: 2, update: .updateReady))
        // One summary row each; it opens the main window at its section, where the lists and the filters are.
        #expect(model.mergeRequests?.section == .mergeRequests)
        #expect(model.mergeRequests?.text == "2 open · 1 to review")
        #expect(model.workItems?.section == .workItems)
        #expect(model.workItems?.text == "2 committed")
        #expect(model.workItems?.isCommitted == true)
        #expect(model.footer.showHidden == "Show 2 Hidden Builds")
        #expect(model.footer.lastChecked?.hasPrefix("Last checked ") == true)
    }

    @Test("APP-06 search filters the builds and hides the summaries")
    func searchFilters() {
        let f = Self.fixtures
        let data = f.panel(problem: .rejectedToken(.jenkins), mine: f.typicalBuilds)

        let model = PanelModel(data, query: "  login ")
        #expect(model.query == "login")
        // Case-insensitive over titles; non-matching builds, the Jenkins link and the summaries hide.
        #expect(model.myBuilds?.rows.map(\.title) == ["Fix the login redirect after a timeout"])
        #expect(model.allBuilds == nil)
        #expect(model.summaries.isEmpty)
        // Problem rows stay.
        #expect(model.problems.count == 1)
        #expect(!model.findsNothing)

        // The reference matches too.
        #expect(PanelModel(data, query: "!16").myBuilds?.rows.map(\.build.job) == ["MR-16"])

        let nothing = PanelModel(data, query: "zzz")
        #expect(nothing.findsNothing)
        #expect(nothing.myBuilds == nil)
    }

    @Test("APP-06 showing the panel marks its sections visible")
    func showingMarksVisible() {
        // The summary rows show the GitLab counts, so those load while the panel is open (OD-02).
        #expect(PanelView.surfaces == [.mergeRequests, .workItems])

        let router = WindowRouter { _ in }
        #expect(router.surfaces(PanelView.surfaces, shownBy: PanelView.host) == [.mergeRequests, .workItems])
        // Another host's surfaces stay while the panel closes; the union goes to the scheduler.
        #expect(router.surfaces([.workItems], shownBy: "window") == [.mergeRequests, .workItems])
        #expect(router.surfaces([], shownBy: PanelView.host) == [.workItems])
        #expect(router.surfaces([], shownBy: "window") == [])
    }

    // MARK: States the panel shows

    @Test("TEAM-03 missing team values show their row alone")
    func teamValuesMissing() {
        let f = Self.fixtures
        let model = PanelModel(f.panel(problem: .teamValuesMissing, mine: f.typicalBuilds, team: TeamValues()))
        #expect(model.sections == [.problems])
        #expect(model.problems == [PanelModel.ProblemItem(
            text: "Fill in the team settings: your Jenkins job and GitLab project", pane: .team)])
        #expect(model.problems.first?.help == "Opens Settings → Projects")
    }

    @Test("OD-05 offline shows the cached data without other problems or spinners")
    func offline() {
        let f = Self.fixtures
        var workItems = f.typicalWorkItems
        workItems.isLoading = true
        workItems.problem = .unreachable(.gitLab)
        let model = PanelModel(f.panel(
            problem: .offline, mine: f.typicalBuilds,
            mergeRequests: PanelData.MergeRequests(list: f.mergeRequestsInAllSections, problem: .unreachable(.gitLab), lastLoadAt: f.now),
            workItems: workItems))
        #expect(model.problems.map(\.text) == ["Offline: checks resume when the network is back"])
        #expect(model.myBuilds?.rows.count == 2)
        #expect(model.mergeRequests?.problem == nil)
        #expect(model.mergeRequests?.text == "2 open · 1 to review")
        #expect(model.workItems?.isLoading == false)
        #expect(model.workItems?.problem == nil)
    }

    @Test("OD-01 panel shows placeholders before the first load")
    func placeholders() {
        let f = Self.fixtures
        let model = PanelModel(f.panel(
            hasLoaded: false, isChecking: true, lastChecked: false,
            mergeRequests: PanelData.MergeRequests(isLoading: true), workItems: PanelData.WorkItems(isLoading: true)))
        #expect(model.myBuilds?.isPlaceholder == true)
        // Nothing is known yet: no text, only the spinner.
        #expect(model.mergeRequests?.text == nil)
        #expect(model.mergeRequests?.isLoading == true)
        #expect(model.workItems?.text == nil)
        #expect(model.workItems?.isLoading == true)
        #expect(model.footer.isChecking)
        #expect(model.footer.lastChecked == nil)
    }

    @Test("JERR-05 without a cached job list the problem row shows alone above the Jenkins link")
    func jenkinsProblemWithoutCache() {
        let f = Self.fixtures
        let model = PanelModel(f.panel(problem: .unreachable(.jenkins)))
        #expect(model.sections == [.problems, .allBuilds, .mergeRequests, .workItems])
        // Unreachable isn't fixed in Settings: the row isn't a link.
        #expect(model.problems.first?.pane == nil)
    }

    @Test("PIPE-06 names the user when no jobs were found")
    func emptyStates() {
        let f = Self.fixtures
        #expect(PanelModel(f.panel(emptyState: .noJobs(user: "jdoe"))).myBuilds?.note == "No merge request builds by jdoe in Jenkins")
        #expect(PanelModel(f.panel(emptyState: .noBuilds, hiddenCount: 3)).myBuilds?.note == "No builds to show")
    }

    @Test("MR-04 explains how to get a GitLab token")
    func noGitLabToken() {
        let f = Self.fixtures
        let model = PanelModel(f.panel(
            mine: f.typicalBuilds,
            mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab)),
            workItems: PanelData.WorkItems(problem: .noToken(.gitLab))))
        // A missing token is a setup step, not a problem: the summaries say so without the red marker.
        #expect(model.mergeRequests?.text == "Needs a token")
        #expect(model.mergeRequests?.problem == nil)
        #expect(model.workItems?.text == "Needs a token")
        #expect(model.workItems?.problem == nil)
        #expect(PanelModel.SetupText.needsToken == "Needs a GitLab token with the api scope")
    }

    @Test("MR-05 reports a rejected token above the cached MRs, with the header marker")
    func gitLabProblemCached() {
        let f = Self.fixtures
        var workItems = f.typicalWorkItems
        workItems.problem = .workItemsFailed(status: 502)
        let model = PanelModel(f.panel(
            mergeRequests: PanelData.MergeRequests(list: f.mergeRequestsInAllSections, problem: .rejectedToken(.gitLab), lastLoadAt: f.now),
            workItems: workItems))
        // The summary keeps the cached counts and adds the marker, whose tooltip is the problem.
        #expect(model.mergeRequests?.problem == "GitLab rejected the token (expired, or without the api scope?)")
        #expect(model.mergeRequests?.text == "2 open · 1 to review")
        #expect(model.workItems?.problem == "Work items request failed (HTTP 502)")

        // A filter label GitLab no longer has marks the work items too.
        workItems.problem = nil
        workItems.missingLabels = ["workflow::gone"]
        #expect(PanelModel(f.panel(workItems: workItems)).workItems?.problem == "Filter label workflow::gone is not in GitLab any more")
    }

    @Test("WI-01 the work items summary says the committed count, else the shown count")
    func workItemsSummary() {
        let f = Self.fixtures
        func summary(_ lists: WorkItemLists, team: TeamValues? = nil) -> PanelModel.Summary? {
            var workItems = PanelData.WorkItems(lists: lists, lastLoadAt: f.now)
            workItems.filters = WorkItemFilters()
            return PanelModel(f.panel(workItems: workItems, team: team ?? f.team)).workItems
        }
        let items = [f.workItem(40, "Speed up the index")]
        let others = WorkItemList(count: 45, items: items)
        #expect(summary(WorkItemLists(committed: WorkItemList(count: 3, items: items), others: others))?.text == "3 committed")
        var single = f.team
        single.committedLabel = ""
        #expect(summary(WorkItemLists(others: others), team: single)?.text == "1 of 45 items")
        #expect(summary(WorkItemLists(others: WorkItemList(count: 1, items: items)), team: single)?.text == "1 item")
        #expect(summary(WorkItemLists(committed: WorkItemList(count: 0, items: []), others: WorkItemList(count: 0, items: [])))?.text == "None match")
    }

    @Test("WI-01 the commitment takes the committed label's color, else its slot's")
    func commitmentColor() {
        let f = Self.fixtures
        let team = f.team
        func color(_ labels: [Label], known: [String: String] = [:]) -> String? {
            let item = WorkItem(
                reference: "group/project#1", title: "A work item", webURL: URL(string: "https://gitlab.example.com/1")!, labels: labels,
                updatedAt: f.now)
            let state = PanelData.WorkItems(
                lists: WorkItemLists(committed: WorkItemList(count: 1, items: [item]), others: nil), labelColors: known)
            return PanelModel.committedColor(state, committedLabel: team.committedLabel, slotPrefix: team.slotLabelPrefix)
        }
        let committed = Label(title: team.committedLabel, color: "#6F42C1")
        let slot = Label(title: "slot::Q1", color: "#9B59B6")
        #expect(color([committed, slot]) == "#6F42C1")
        #expect(color([Label(title: team.committedLabel), slot]) == "#9B59B6")
        #expect(color([Label(title: team.committedLabel), slot], known: [team.committedLabel: "#112233"]) == "#112233")
        #expect(color([Label(title: team.committedLabel)]) == nil)
    }
}

import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("PanelModel")
@MainActor
struct PanelModelTests {
    private static let fixtures = Fixtures()

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
            return PanelModel.committedColor(state, committedLabel: team.committedLabel, slotPrefix: team.slotPrefix)
        }
        let committed = Label(title: team.committedLabel, color: "#6F42C1")
        let slot = Label(title: "slot::Q1", color: "#9B59B6")
        #expect(color([committed, slot]) == "#6F42C1")
        #expect(color([Label(title: team.committedLabel), slot]) == "#9B59B6")
        #expect(color([Label(title: team.committedLabel), slot], known: [team.committedLabel: "#112233"]) == "#112233")
        #expect(color([Label(title: team.committedLabel)]) == nil)
    }
}

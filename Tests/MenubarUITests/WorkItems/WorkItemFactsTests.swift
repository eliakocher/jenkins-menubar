import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("WorkItemFacts")
struct WorkItemFactsTests {
    private static var team: TeamValues {
        var team = TeamValues(committedLabel: "workflow::committed", slotLabelPrefix: "slot::")
        team.slotScheduledLabelPrefix = "slot-scheduled::"
        team.statusLabelPrefix = "status::"
        team.typeLabelPrefix = "type::"
        team.priorityLabelPrefix = "priority::"
        team.squadLabelPrefix = "squad::"
        return team
    }

    @Test(
        "WI-04 the header's facts: Team's labels first in a fixed order, then a line per other scope, the rest as labels",
        arguments: [
            // Team's labels in their order, whatever GitLab's; the due slot only when it differs; squads together.
            (
                ["design", "type::Bug", "slot::2026.51", "squad::Bravo", "status::InProgress", "slot-scheduled::2026.49",
                 "squad::Alpha", "workflow::committed", "release-train::north"],
                ["Slot: 2026.49", "Due slot: 2026.51", "Status: In progress", "Type: Bug", "Squad: Bravo, Alpha",
                 "Commitment: Committed", "Release train: North"],
                ["design"]
            ),
            // The same week twice is one line; a nested scope keeps its parts; plain labels keep GitLab's order.
            (
                ["slot::2026.51", "slot-scheduled::2026.51", "frontend", "team::web::iOS", "earlyAccess::yes", "docs"],
                ["Slot: 2026.51", "Team › Web: iOS", "Early access: Yes"],
                ["frontend", "docs"]
            ),
            // Past the limit, the other scoped labels go with the plain ones.
            (
                ["a::1", "b::2", "c::3", "d::4", "e::5", "f::6", "g::7", "h::8", "i::9", "j::10", "k::11", "l::12", "m::13",
                 "plain"],
                ["A: 1", "B: 2", "C: 3", "D: 4", "E: 5", "F: 6", "G: 7", "H: 8", "I: 9", "J: 10", "K: 11", "L: 12"],
                ["m::13", "plain"]
            ),
            // A scheme's one-letter mark before a capital is dropped; a value's "group:" part too; a second scheme's
            // label with a fact's name and value is left out, with another value it joins the line.
            (
                ["xFooBarStatus::Ready", "squad::xGroup:Alpha", "xSquad::Alpha", "priority::High", "xPriority::Low",
                 "zPriority:High", "QA::done"],
                ["Priority: High, Low", "Squad: Alpha", "Foo bar status: Ready", "QA: Done"],
                []
            ),
        ])
    func facts(labels: [String], facts: [String], others: [String]) {
        let pills = labels.map { LabelPillModel(MenubarCore.Label(title: $0)) }
        let made = WorkItemFacts(labels: pills, team: Self.team)
        #expect(made.facts.map { "\($0.name): \($0.value)" } == facts)
        #expect(made.otherLabels.map(\.title) == others)
    }
}

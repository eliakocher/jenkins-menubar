import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("WorkItemsModel")
@MainActor
struct WorkItemsModelTests {
    private static let fixtures = Fixtures()

    @Test(
        "WIN-02 work item detail lists ignored related MRs greyed",
        arguments: [
            // The cascade MR is open, yet it counts for nothing: last, greyed, with the footer.
            ("[cascade]", ["!43", "!42", "!44"], [false, false, true], RelatedMergeRequestMarker.merged),
            // Without a prefix in Team every MR counts: open first.
            ("", ["!44", "!43", "!42"], [false, false, false], .open),
        ])
    func ignoredRelatedGreyed(prefix: String, order: [String], ignored: [Bool], marker: RelatedMergeRequestMarker) throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        var team = f.team
        team.ignoredMergeRequestPrefix = prefix
        var state = w.data(team: team)
        state.panel.workItems.markers[w.item28.reference] = state.related.marker(of: w.item28, ignoredPrefix: prefix)
        let detail = try #require(WorkItemDetailModel(state.data, selection: w.item28.id))
        guard case .rows(let rows) = detail.related else {
            Issue.record("no related rows: \(detail.related)")
            return
        }
        #expect(rows.map { GitLabText.shortReference($0.mergeRequest.reference, project: team.gitLabProject) } == order)
        #expect(rows.map(\.isIgnored) == ignored)
        #expect(detail.marker == marker)
        let footer = "Merge requests starting with [cascade] don't count for the marker"
        #expect(detail.relatedFooters == (prefix.isEmpty ? [] : [footer]))
    }

    @Test(
        "WIN-02 related MR that is in Merge Requests offers Show in Merge Requests",
        arguments: [
            // !14 of #31 is in Review Requested too; !11 is merged, so it isn't.
            (true, [true, false]),
            (false, [false, false]),
        ])
    func showInMergeRequests(loadedInMergeRequests: Bool, offers: [Bool]) throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        let m = f.mergeRequestsScreen
        let state = w.data(mergeRequests: loadedInMergeRequests ? m.sections : w.otherMergeRequests)
        let detail = try #require(WorkItemDetailModel(state.data, selection: w.item31.id))
        guard case .rows(let rows) = detail.related else {
            Issue.record("no related rows: \(detail.related)")
            return
        }
        #expect(rows.map(\.showsInMergeRequests) == offers)
        if loadedInMergeRequests {
            // The button selects the MR there by its web URL, the Merge Requests list's id.
            #expect(rows.first?.id == m.mr14.id)
        }
    }

    @Test(
        "WI-04 the second line hides the labels every shown item has",
        arguments: [
            // One item has nothing to tell apart from: all its labels show.
            ([["team::core", "status::ready", "bug"]], [["team::core · status::ready · bug"]]),
            // All share two routine labels: only what differs shows, and an item with nothing else has no line.
            (
                [["team::core", "status::ready", "bug"], ["team::core", "status::ready"]],
                [["bug"], []]
            ),
            // Only some share a label: it still tells items apart.
            (
                [["team::core", "status::ready"], ["team::core", "status::blocked"], ["team::core"]],
                [["status::ready"], ["status::blocked"], []]
            ),
        ] as [([[String]], [[String]])])
    func sharedLabelsLeaveTheSecondLine(labels: [[String]], lines: [[String]]) {
        let items = labels.enumerated().map { index, titles in
            WorkItem(
                reference: "acme/main/app#\(index + 1)", title: "Item", webURL: URL(string: "https://gitlab.example/\(index)")!,
                labels: titles.map { Label(title: $0) }, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        }
        let team = Self.fixtures.team
        let shared = WorkItemRowModel.sharedLabels(of: items)
        let shown = items.map { WorkItemRowModel.secondLine(of: $0, team: team, filters: WorkItemFilters(), sharedLabels: shared) }
        #expect(shown == lines.map { $0.isEmpty ? nil : $0.joined(separator: " · ") })
    }
}

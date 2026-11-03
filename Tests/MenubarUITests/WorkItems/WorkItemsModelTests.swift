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
            // The item's own MR first, then the ones that mention it. The cascade MR is open, yet it counts for nothing:
            // last, greyed, with the footer.
            ("[cascade]", ["!43", "!41", "!42", "!44"], [false, false, false, true], RelatedMergeRequestMarker.merged),
            // Without a prefix in Team every mentioning MR is listed, open first; the marker counts the own MR only.
            ("", ["!43", "!44", "!41", "!42"], [false, false, false, false], .merged),
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

    @Test("WI-05 the detail lists the item's own MRs first and the ones that only mention it apart; the chips count the own ones")
    func ownAndMentionedMergeRequests() throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        let item = w.item28
        let detail = try #require(WorkItemDetailModel(w.data().data, selection: item.id))
        // !43's branch starts with the item's number; !44, !41 and !42 only mention it.
        #expect(detail.ownMergeRequests.map { $0.mergeRequest.iid } == [43])
        #expect(detail.mentionedMergeRequests.map { $0.mergeRequest.iid } == [41, 42, 44])
        #expect(detail.countedMergeRequests.map { $0.mergeRequest.iid } == [43])

        // None is its own: all of them are listed and count, as before.
        let mentionOnly = [item.reference: [w.related(44, "Merge release into main", .opened), w.related(41, "Show the size", .merged)]]
        let all = try #require(WorkItemDetailModel(w.data(related: mentionOnly).data, selection: item.id))
        #expect(all.mentionedMergeRequests.isEmpty)
        #expect(all.ownMergeRequests.map { $0.mergeRequest.iid } == [44, 41])
        #expect(all.countedMergeRequests.count == 2)
    }

    @Test("WI-05 the row's MR chip shows the first counted MR and +N for the others, with a draft and a merged MR told apart")
    func rowChip() {
        let w = Self.fixtures.workItemsScreen
        let project = "group/subgroup/project"
        func chip(_ mergeRequests: [RelatedMergeRequest], prefix: String = "[cascade]") -> WorkItemMergeRequestChip? {
            WorkItemMergeRequestChip.make(mergeRequests, marker: nil, project: project, ignoredPrefix: prefix)
        }
        let open = w.related(14, "Rework the color tokens", .opened)
        let merged = w.related(11, "Move the values", .merged)
        let cascade = w.related(44, "[cascade] Merge release/2.4 into main", .opened)
        let closed = w.related(42, "Old try", .closed)
        let draft = w.related(15, "Draft: Try it", .opened)
        // open first, then merged; the first and "+N" of the counted ones; cascade and closed MRs don't count
        let several = chip([merged, cascade, closed, open, draft])
        #expect(several?.text == "!14 +2")
        #expect(several?.help.components(separatedBy: "\n").count == 3)
        #expect(several?.help.hasPrefix("!14 · open · Rework the color tokens") == true)
        #expect(chip([merged])?.text == "!11")
        #expect(chip([merged])?.help == "!11 · merged · Move the values")
        #expect(chip([draft])?.help == "!15 · draft · Draft: Try it")
        #expect(chip([w.related(8, "Fix it", .opened, project: "group/subgroup/web")])?.text == "web!8")
        #expect(chip([cascade, closed]) == nil)
        #expect(chip([]) == nil)
        // without a prefix in Team the cascade MR counts
        #expect(chip([cascade], prefix: "")?.text == "!44")
        // the marker alone, before the MRs are known, gives a chip without text
        let only = WorkItemMergeRequestChip.make([], marker: .merged, project: project, ignoredPrefix: "")
        #expect(only?.text == nil)
        #expect(only?.help == RelatedMergeRequestMarker.merged.text)
    }

    @Test("MR-13 a work item has a slot name, so Show in Slots shows, only with a slot label")
    func slotNameOfDetail() throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        let slotted = w.item(31, "Rework the color tokens", labels: ["workflow::committed", WorkItemDetailGalleryView.slotLabel(now: f.now)])
        let lists = WorkItemLists(committed: WorkItemList(count: 1, items: [slotted]), others: WorkItemList(count: 1, items: [w.item40]))
        let data = w.data(lists).data
        let withSlot = try #require(WorkItemDetailModel(data, selection: slotted.id))
        let without = try #require(WorkItemDetailModel(data, selection: w.item40.id))
        #expect(withSlot.slotName == SlotPlan.slot(of: slotted, team: f.team))
        #expect(withSlot.slotName != nil)
        #expect(without.slotName == nil)
    }

    @Test("SLOT-03 the work item detail shows each merge request's build, the item's flags and its slot's next date")
    func detailReality() throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        let slot = WorkItemDetailGalleryView.slotLabel(now: f.now)
        let item = w.item(31, "Rework the color tokens", labels: ["workflow::committed", slot])
        let related = [item.reference: [w.related(14, "Rework the color tokens", .opened), w.related(11, "Move the values", .merged)]]
        let lists = WorkItemLists(committed: WorkItemList(count: 1, items: [item]))
        let data = w.data(lists, related: related).data
        let red = BuildReality(signal: .red, url: URL(string: "https://jenkins.example.com/job/project/job/MR-14/7/"), label: "#7")
        let reality = try #require(
            SlotPlan.make(
                workItems: [item], mergeRequests: { related[$0.reference] }, build: { $0.iid == 14 ? red : nil },
                team: f.team, today: f.now
            ).slots.flatMap(\.items).first)
        let detail = try #require(WorkItemDetailModel(data, selection: item.id, reality: reality))
        guard case .rows(let rows) = detail.related else {
            Issue.record("no related rows: \(detail.related)")
            return
        }
        #expect(rows.map(\.build) == [red, nil])
        #expect(detail.flags.map(\.kind) == [.redPipeline])
        #expect(detail.countedMergeRequests.count == 2)
        // The release is five weeks ahead: nothing is overdue.
        #expect(detail.slot?.isOverdue == false)
        // Another item's reality is never shown.
        var other = reality
        other.workItem = w.item40
        let unrelated = try #require(WorkItemDetailModel(data, selection: item.id, reality: other))
        #expect(unrelated.flags.isEmpty)
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

    @Test(
        "WI-04 the second line hides labels by prefix and shows scoped labels by their value; the item keeps them all",
        arguments: [
            // hidden prefixes, value only, the line
            ([String](), false, "group:SquadA · triage::Maintainer · affects::1.0 · bug"),
            (["group:", "affects::"], false, "triage::Maintainer · bug"),
            ([], true, "group:SquadA · Maintainer · 1.0 · bug"),
            (["GROUP:"], true, "Maintainer · 1.0 · bug"),
            // everything hidden leaves no line
            (["group:", "triage", "affects", "bug"], false, nil),
        ] as [([String], Bool, String?)])
    func rowLabelsPreference(hidden: [String], valueOnly: Bool, line: String?) {
        let item = Self.fixtures.workItemsScreen.item(
            40, "Labels", labels: ["group:SquadA", "triage::Maintainer", "affects::1.0", "bug"])
        let rows = WorkItemRowLabels(hidden: hidden, showsScopedValueOnly: valueOnly)
        #expect(
            WorkItemRowModel.secondLine(of: item, team: Self.fixtures.team, filters: WorkItemFilters(), rowLabels: rows) == line)
        // The search and the detail read the item's own labels.
        #expect(item.labels.count == 4)
        var data = Self.fixtures.workItemsScreen.data().data
        data.workItems.rowLabels = rows
        let row = WorkItemRowModel(item, data: data)
        #expect(row.secondLine == line)
        #expect(row.matches("group:squada"))
    }

    @Test("WI-04 the pill and the Slot card show the scheduled slot, the Slot card names a different due slot")
    func scheduledSlotLeadsTheDueSlot() throws {
        let f = Self.fixtures
        let w = f.workItemsScreen
        var team = f.team
        team.slotLabelPrefix = "slot::"
        team.slotScheduledLabelPrefix = "slot-scheduled::"
        let item = w.item(31, "Rework", labels: ["workflow::committed", "slot::2026.45", "slot-scheduled::2026.47"])
        let same = w.item(32, "Same", labels: ["slot::2026.45", "slot-scheduled::2026.45"])
        let state = w.data(WorkItemLists(committed: WorkItemList(count: 2, items: [item, same]), others: nil), team: team)

        let row = WorkItemRowModel(item, data: state.data)
        #expect(row.slot == "2026.47")
        #expect(row.slotLabel?.title == "slot-scheduled::2026.47")
        // The due slot's label stays on the second line only when it names another slot.
        #expect(row.secondLine == "slot::2026.45")
        #expect(WorkItemRowModel(same, data: state.data).secondLine == nil)

        let detail = try #require(WorkItemDetailModel(state.data, selection: item.id))
        #expect(detail.slotName?.description == "2026.47")
        #expect(detail.slot?.name.description == "2026.47")
        #expect(detail.dueSlot?.description == "2026.45")
        let sameDetail = try #require(WorkItemDetailModel(state.data, selection: same.id))
        #expect(sameDetail.dueSlot == nil)
    }
}

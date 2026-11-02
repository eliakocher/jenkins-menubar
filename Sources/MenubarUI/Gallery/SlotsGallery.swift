#if DEBUG
import MenubarCore
import SwiftUI

/// The Slots section in the whole main window, as the gallery shows it on Fri 30 Oct 2026: 2026.45 current (release Mon
/// 2 Nov), 2026.48 freezing today, 2026.51, 2027.03, and a slot whose name isn't a week. Made-up items of
/// `group/subgroup/project` with epics, types, statuses, priorities, weights and assignees, by their scheduled slot, two
/// teams by person; the selected one has its detail, Work Items' own, beside the list.
struct SlotsGalleryView: View {
    let fixtures: Fixtures
    let size: CGSize
    /// the selected work item's reference
    var selected: String?
    /// the work items haven't loaded yet: the skeleton
    var loading = false
    /// why the slot group didn't load
    var problem: String?
    /// no teams in Team: the chips come from the squad labels, with the hint under them
    var squads = false
    /// the cards the user opened or closed; none follows the default, the current slot open
    var expansion = SlotExpansion()
    /// the chips that are on
    var chips: SlotChipSelection?

    var body: some View {
        let today = Self.today
        let team = Self.team(fixtures)
        let w = fixtures.workItemsScreen
        let items = Self.items(w)
        let related = Self.related(w)
        let plan = Self.plan(fixtures, items: items, related: related, today: today)
        let state = w.data(WorkItemLists(committed: WorkItemList(count: items.count, items: items), others: WorkItemList(count: 0, items: [])), related: related)
        MainWindowGalleryView(model: MainWindowShellModel(state.panel, section: .slots), section: .slots, size: size) {
            SlotsContent(
                model: SlotsListModel(
                    plan: loading ? SlotPlan() : plan, team: team, hasLoaded: !loading, needsToken: false, query: "", labelsProblem: problem,
                    groupItems: items.count),
                chips: squads ? SlotChip.chips(squads: ["Alpha", "Bravo"]) : SlotChip.chips(squads: [], teams: ["Alpha", "Bravo"]),
                selectedChips: .constant(
                    chips ?? (squads ? SlotChipSelection([.squad("Alpha")]) : SlotChipSelection([.openBugs, .team("Alpha"), .me]))),
                suggestedTeams: squads ? "Alpha: akim, jdoe; Bravo: cnovak, slee" : "", expansion: .constant(expansion),
                selection: .constant(selected),
                today: today, actions: .none, retry: {}
            ) { id in
                detail(id, state: state, plan: plan, items: items)
            }
            .environment(\.slotOpenInTab) { _ in }
        } detail: {
            EmptyView()
        }
    }

    private func detail(_ id: String, state: WorkItemsGalleryState, plan: SlotPlan, items: [WorkItem]) -> some View {
        let w = fixtures.workItemsScreen
        let item = items.first { $0.id == id }
        let reality = plan.slots.lazy.flatMap { $0.items + $0.planned }.first { $0.id == id }
        return WorkItemDetailContent(
            model: item.map { WorkItemDetailModel(state.data, workItem: $0, reality: reality) }, actions: .none
        )
        .environment(\.descriptionFixtures, DescriptionFixtures(descriptions: [id: .loaded(w.description31)]))
        .environment(\.discussionFixtures, [id: .loaded(w.discussion31)])
    }

    /// Fri 30 Oct 2026, 10:42
    static var today: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10, minute: 42))!
    }

    static func team(_ f: Fixtures) -> TeamValues {
        var team = f.team
        team.statusLabelPrefix = "status::"
        team.typeLabelPrefix = "type::"
        team.inProgressLabel = "status::InProgress"
        team.committedLabel = "commitment::Committed"
        team.slotLabelPrefix = "slot::"
        team.slotScheduledLabelPrefix = "slot-scheduled::"
        team.blockedLabel = "prerequisite::Blocked"
        team.sizeLabelPrefix = "size::"
        team.priorityLabelPrefix = "priority::"
        team.slotTeams = "Alpha: jdoe, akim; Bravo: slee, cnovak"
        team.slotMemberWorkDays = "akim: 4"
        return team
    }

    /// The slots' items: epics, types, statuses, weights and assignees, by made-up people.
    static func items(_ w: WorkItemsFixtures) -> [WorkItem] {
        let design = WorkItemEpic(
            reference: "group/subgroup&12", title: "Design system refresh",
            webURL: URL(string: "https://gitlab.example.com/groups/group/subgroup/-/epics/12")!,
            labels: [Label(title: "size::S")])
        let search = WorkItemEpic(
            reference: "group/subgroup&15", title: "Faster search",
            webURL: URL(string: "https://gitlab.example.com/groups/group/subgroup/-/epics/15")!)
        let jane = MergeRequest.Person(username: "jdoe", name: "Jane Doe")
        let alex = MergeRequest.Person(username: "akim", name: "Alex Kim")
        let sam = MergeRequest.Person(username: "slee", name: "Sam Lee")
        let chris = MergeRequest.Person(username: "cnovak", name: "Chris Novak")
        func item(
            _ iid: Int, _ title: String, slot: String, committed: Bool = true, type: String, status: String, weight: Int?,
            epic: WorkItemEpic?, people: [MergeRequest.Person], blocked: Bool = false, closed: Bool = false,
            priority: String? = nil, due: String? = nil
        ) -> WorkItem {
            var labels = ["slot-scheduled::\(slot)", "type::\(type)", "status::\(status)"]
            if committed { labels += ["slot::\(due ?? slot)", "commitment::Committed"] }
            if blocked { labels.append("prerequisite::Blocked") }
            if let priority { labels.append("priority::\(priority)") }
            var item = w.item(iid, title, state: closed ? .closed : .opened, labels: labels)
            item.weight = weight
            item.epic = epic
            item.assignees = people
            item.author = sam
            item.isBlocked = blocked
            return item
        }
        return [
            item(31, "Rework the color tokens so the badges, the panel and the main window share one source of truth", slot: "2026.45",
                 type: "Feature", status: "InProgress", weight: 5, epic: design, people: [jane, alex]),
            item(28, "Speed up the search index rebuild", slot: "2026.45", type: "Bug", status: "InVerification", weight: 3,
                 epic: search, people: [jane], priority: "Critical"),
            item(35, "Fix the focus ring on the sidebar", slot: "2026.45", type: "Bug", status: "Verified", weight: 1, epic: design,
                 people: [alex], closed: true),
            item(36, "Add a keyboard shortcuts overview", slot: "2026.45", type: "Feature", status: "Todo", weight: 3, epic: nil,
                 people: [sam], blocked: true, due: "2026.48"),
            item(44, "Document the export formats", slot: "2026.45", committed: false, type: "Task", status: "Triage", weight: 2,
                 epic: search, people: []),
            item(51, "Group the settings by what people change", slot: "2026.48", type: "Feature", status: "Todo", weight: 8,
                 epic: design, people: [chris, sam]),
            item(52, "Cache the label colors between launches", slot: "2026.48", type: "Task", status: "InProgress", weight: 2,
                 epic: search, people: [jane]),
            item(53, "Crash when the token is removed during a load", slot: "2026.48", type: "Bug", status: "Todo", weight: nil,
                 epic: nil, people: [alex], priority: "Major"),
            item(54, "Remember the window's split between launches", slot: "2026.48", type: "Task", status: "Todo", weight: 3,
                 epic: nil, people: []),
            item(60, "Show the build history as a timeline", slot: "2026.51", type: "Feature", status: "Todo", weight: 13, epic: design,
                 people: [chris]),
            item(70, "Hotfix the export of long names", slot: "hotfix_2026-11-12", type: "Bug", status: "InProgress", weight: 2,
                 epic: nil, people: [alex], priority: "Blocker"),
            item(61, "Retry the related merge request lookup after a timeout", slot: "2026.51", committed: false, type: "Task",
                 status: "Triage", weight: 1, epic: search, people: [jane]),
        ]
    }

    static func related(_ w: WorkItemsFixtures) -> [String: [RelatedMergeRequest]] {
        [
            "group/subgroup/project#31": [
                w.related(14, "Rework the color tokens", .opened), w.related(11, "Move the color values into one file", .merged),
            ],
            "group/subgroup/project#28": [w.related(17, "Speed up the search index rebuild", .merged)],
            "group/subgroup/project#52": [w.related(19, "Cache the label colors", .opened)],
            "group/subgroup/project#35": [w.related(9, "Fix the sidebar focus ring", .merged)],
            "group/subgroup/project#36": [],
        ]
    }

    /// A commitment of 2026.45, blocked by the design epic, #36 and an item of a later slot.
    static var commitments: [SlotCommitment] {
        [
            SlotCommitment(
                reference: "group/commitments&5", title: "Dark mode for the support desk",
                webURL: URL(string: "https://gitlab.example.com/groups/group/commitments/-/epics/5")!,
                labels: [Label(title: "slot-scheduled::2026.45"), Label(title: "commitment::Committed")], dueDate: "2026-11-02",
                committed: [
                    .init(reference: "group/subgroup&12"), .init(reference: "group/subgroup/project#36"),
                    .init(reference: "group/subgroup/project#60"),
                ])
        ]
    }

    static func plan(_ f: Fixtures, items: [WorkItem], related: [String: [RelatedMergeRequest]], today: Date) -> SlotPlan {
        let builds: [Int: BuildReality] = [
            14: BuildReality(signal: .red, label: "#215"), 11: BuildReality(signal: .green, label: "#198"),
            17: BuildReality(signal: .green, label: "#212"), 19: BuildReality(signal: .running, label: "#221"),
            9: BuildReality(signal: .green, label: "#190"),
        ]
        let known = ["2026.43", "2026.44", "2026.45", "2026.48", "2026.51", "2027.03"].map { Label(title: "slot-scheduled::\($0)", color: "#9B59B6") }
        let team = team(f)
        return SlotPlan.make(
            workItems: items, mergeRequests: { related[$0.reference] }, build: { builds[$0.iid] }, knownLabels: known,
            team: team, capacity: SlotChip.all.capacity(team: team, squads: [], me: "jdoe"),
            epicWeights: ["group/subgroup&12": 27, "group/subgroup&15": 6], commitments: commitments, today: today)
    }
}

extension GalleryCatalog {
    /// The Slots section in the whole window: wide with an item's detail beside the list, wide without a selection, at the
    /// default width, and at the least width, where the detail slides over the list (SLOT-09).
    static var slotsEntries: [GalleryEntry] {
        let wide = CGSize(width: 1400, height: 900)
        let standard = MainWindowGallerySize.standard
        let narrow = CGSize(width: MainWindowGallerySize.minimum.width, height: 900)
        let selected = "group/subgroup/project#31"
        return [
            GalleryEntry(screen: "slots", state: "wide-detail", size: wide) { f in
                SlotsGalleryView(fixtures: f, size: wide, selected: selected)
            },
            GalleryEntry(screen: "slots", state: "wide", size: wide) { f in
                SlotsGalleryView(fixtures: f, size: wide)
            },
            // every card closed, the header rows at a glance
            GalleryEntry(screen: "slots", state: "collapsed", size: wide) { f in
                SlotsGalleryView(
                    fixtures: f, size: wide,
                    expansion: SlotExpansion(closed: ["2026.45"]), chips: SlotChipSelection([.team("Alpha")]))
            },
            GalleryEntry(screen: "slots", state: "expanded-two", size: wide) { f in
                SlotsGalleryView(fixtures: f, size: wide, expansion: SlotExpansion(opened: ["2026.48"]))
            },
            GalleryEntry(screen: "slots", state: "collapsed-narrow", size: narrow) { f in
                SlotsGalleryView(fixtures: f, size: narrow, expansion: SlotExpansion(closed: ["2026.45"]))
            },
            GalleryEntry(screen: "slots", state: "default-detail", size: standard) { f in
                SlotsGalleryView(fixtures: f, size: standard, selected: selected)
            },
            GalleryEntry(screen: "slots", state: "narrow-detail", size: narrow) { f in
                SlotsGalleryView(fixtures: f, size: narrow, selected: selected)
            },
            GalleryEntry(screen: "slots", state: "narrow", size: narrow) { f in
                SlotsGalleryView(fixtures: f, size: narrow)
            },
            GalleryEntry(screen: "slots", state: "loading", size: standard) { f in
                SlotsGalleryView(fixtures: f, size: standard, loading: true)
            },
            GalleryEntry(screen: "slots", state: "squad-chips", size: standard) { f in
                SlotsGalleryView(fixtures: f, size: standard, squads: true)
            },
            GalleryEntry(screen: "slots", state: "suggest-members", size: CGSize(width: 400, height: 240)) { _ in
                SlotMemberSuggestion(suggestion: "Alpha: akim, jdoe; Bravo: cnovak, slee")
                    .background(.windowBackground)
            },
            GalleryEntry(screen: "slots", state: "problem", size: wide) { f in
                SlotsGalleryView(fixtures: f, size: wide, problem: "GitLab did not answer for the slot group: the request timed out")
            },
        ]
    }
}
#endif

#if DEBUG
import MenubarCore
import SwiftUI

/// The whole main window with Work Items selected, as the gallery shows it: the shell from fixtures, the list and the
/// selected item's detail.
struct WorkItemsGalleryView: View {
    let state: WorkItemsGalleryState
    var selection: WorkItem.ID?
    var query = ""
    var size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize

    var body: some View {
        let data = state.data
        MainWindowGalleryView(
            model: MainWindowShellModel(state.panel, section: .workItems), section: .workItems, searchText: query, size: size
        ) {
            WorkItemsListContent(model: WorkItemsListModel(data, query: query), selection: .constant(selection), actions: .none)
        } detail: {
            WorkItemDetailContent(model: WorkItemDetailModel(data, selection: selection), actions: .none)
        }
    }
}

/// The work item detail alone, at a width of its own (Task 7.0): a typical item, with a long description, merge requests
/// with their builds, a flag and a slot whose code freeze is ahead; or a sparse one, with nothing but its title.
struct WorkItemDetailGalleryView: View {
    let fixtures: Fixtures
    let sparse: Bool
    let size: CGSize
    /// the item's own text, discussion and merge requests still on their way: skeleton cards
    var loading = false

    var body: some View {
        let w = fixtures.workItemsScreen
        let item = sparse ? sparseItem : typicalItem
        let related: [String: [RelatedMergeRequest]] = sparse ? [item.reference: []] : [
            item.reference: [
                w.related(14, "Rework the color tokens", .opened),
                w.related(11, "Move the color values into one file", .merged),
                w.related(44, "[cascade] Merge release/2.4 into main", .opened),
            ]
        ]
        let lists = WorkItemLists(
            committed: WorkItemList(count: 1, items: sparse ? [] : [item]), others: WorkItemList(count: 1, items: sparse ? [item] : []))
        let data = w.data(lists, related: related, mergeRequests: fixtures.mergeRequestsScreen.sections).data
        let builds: [Int: BuildReality] = [
            14: BuildReality(signal: .red, url: URL(string: "https://jenkins.example.com/job/project/job/MR-14/215/"), label: "#215"),
            11: BuildReality(signal: .green, url: URL(string: "https://jenkins.example.com/job/project/job/MR-11/198/"), label: "#198"),
        ]
        let reality = SlotPlan.make(
            workItems: [item], mergeRequests: { related[$0.reference] }, build: { builds[$0.iid] }, team: fixtures.team,
            today: fixtures.now
        ).slots.flatMap(\.items).first
        WorkItemDetailContent(model: WorkItemDetailModel(data, selection: item.id, reality: reality), actions: .none)
            .environment(
                \.descriptionFixtures,
                DescriptionFixtures(descriptions: [item.reference: loading ? .loading : .loaded(sparse ? "" : w.description31)])
            )
            .environment(
                \.discussionFixtures,
                [item.reference: loading ? .loading : .loaded(sparse ? WorkItemDiscussion() : w.discussion31)])
            .frame(width: size.width, height: size.height)
            .background(.windowBackground)
    }

    /// #31, committed to the slot whose release is five weeks ahead, by Sam Lee for Jane Doe and Alex Kim
    private var typicalItem: WorkItem {
        let w = fixtures.workItemsScreen
        var item = w.item(31, "Rework the color tokens so the badges, the panel and the main window share one source of truth", labels: [
            "workflow::committed", Self.slotLabel(now: fixtures.now), "type::feature", "priority::high", "design", "frontend",
            "team::web::frontend",
        ])
        // GitLab's slot color, as `WorkItemsFixtures.colors` has it for the other slots.
        item.labels = item.labels.map { $0.title.hasPrefix("slot::") ? MenubarCore.Label(title: $0.title, color: "#9B59B6") : $0 }
        item.author = MergeRequest.Person(username: "slee", name: "Sam Lee")
        item.assignees = [MergeRequest.Person(username: "jdoe", name: "Jane Doe"), MergeRequest.Person(username: "akim", name: "Alex Kim")]
        return item
    }

    /// #40, a task with one label, nobody assigned and no description
    private var sparseItem: WorkItem {
        var item = fixtures.workItemsScreen.item(40, "Update the onboarding checklist", type: .task, labels: ["docs"], updatedMinutesAgo: 1440)
        item.author = MergeRequest.Person(username: "jdoe", name: "Jane Doe")
        item.assignees = []
        return item
    }

    /// the slot label of the ISO week five weeks from now, so its code freeze is about a week ahead
    static func slotLabel(now: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let release = calendar.date(byAdding: .day, value: 35, to: now) ?? now
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: release)
        return "slot::\(String(parts.yearForWeekOfYear ?? 2026)).\(String(format: "%02d", parts.weekOfYear ?? 1))"
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/work-items.md`.
    static var workItemsEntries: [GalleryEntry] {
        let size = MainWindowGalleryView<EmptyView, EmptyView>.defaultSize
        let minimum = MainWindowGalleryView<EmptyView, EmptyView>.minimumSize
        // The least width, tall enough for the labels and the related merge request (WORK-ITEMS-02).
        let tall = CGSize(width: minimum.width, height: 1100)
        // The default width, tall enough for the whole templated description.
        let descriptionSize = CGSize(width: size.width, height: 1900)
        let wide = CGSize(width: 1100, height: 1160)
        let narrow = CGSize(width: 600, height: 1480)
        return [
            // The detail alone, wide (two columns of cards) and narrow (one), typical and sparse (Task 7.0).
            GalleryEntry(screen: "work-items", state: "detail-typical-wide", size: wide) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: false, size: wide)
            },
            GalleryEntry(screen: "work-items", state: "detail-typical-narrow", size: narrow) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: false, size: narrow)
            },
            // The description and the discussion still loading: their cards as skeletons, the header and the rest real.
            GalleryEntry(screen: "work-items", state: "detail-loading", size: CGSize(width: 1100, height: 900)) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: false, size: CGSize(width: 1100, height: 900), loading: true)
            },
            GalleryEntry(screen: "work-items", state: "detail-sparse-wide", size: CGSize(width: 1100, height: 520)) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: true, size: CGSize(width: 1100, height: 520))
            },
            GalleryEntry(screen: "work-items", state: "detail-sparse-narrow", size: CGSize(width: 600, height: 560)) { f in
                WorkItemDetailGalleryView(fixtures: f, sparse: true, size: CGSize(width: 600, height: 560))
            },
            GalleryEntry(screen: "work-items", state: "sections", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "single-list", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(
                    state: w.data(w.singleList, filters: WorkItemFilters(), team: w.teamWithoutLabels), selection: w.item40.id)
            },
            GalleryEntry(screen: "work-items", state: "detail-merged", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.item28.id)
            },
            GalleryEntry(screen: "work-items", state: "related-in-merge-requests", size: size) { f in
                let w = f.workItemsScreen
                let m = f.mergeRequestsScreen
                // !14 of the work item is the Merge Requests store's !14 too, in Review Requested.
                return WorkItemsGalleryView(state: w.data(mergeRequests: m.sections), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "detail-epic", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.epic12.id)
            },
            GalleryEntry(screen: "work-items", state: "detail-other-project", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.web34.id)
            },
            GalleryEntry(screen: "work-items", state: "label-pills", size: size) { f in
                let w = f.workItemsScreen
                let item = w.labelPillsItem
                let lists = WorkItemLists(
                    committed: WorkItemList(count: 3, items: [w.item31, w.item28, item]),
                    others: WorkItemList(count: 45, items: [w.epic12, w.web34, w.item40]))
                var related = w.relatedAnswers
                related[item.reference] = []
                return WorkItemsGalleryView(state: w.data(lists, related: related), selection: item.id)
            },
            GalleryEntry(screen: "work-items", state: "related-loading", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(isLoading: true, related: [:]), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "related-unknown", size: size) { f in
                let w = f.workItemsScreen
                var related = w.relatedAnswers
                related[w.item31.reference] = nil
                return WorkItemsGalleryView(state: w.data(related: related), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "filter-any", size: size) { f in
                let w = f.workItemsScreen
                let lists = w.anyLists
                return WorkItemsGalleryView(
                    state: w.data(lists, filters: w.anyFilters, related: [:]), selection: lists.all[0].id)
            },
            GalleryEntry(screen: "work-items", state: "gone-filter-label", size: size) { f in
                let w = f.workItemsScreen
                let filters = WorkItemFilters(withLabels: ["frontend"], withoutLabels: ["wontfix", "workflow::gone"])
                return WorkItemsGalleryView(
                    state: w.data(filters: filters, missingLabels: ["workflow::gone"]), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "empty-with-problems", size: minimum) { f in
                // Problem rows above the empty view at the least height (WORK-ITEMS-03): a gone filter label and the
                // HTTP error of a reload.
                let w = f.workItemsScreen
                let empty = WorkItemLists(committed: WorkItemList(count: 0, items: []), others: WorkItemList(count: 0, items: []))
                let filters = WorkItemFilters(withLabels: ["frontend", "workflow::gone"], withoutLabels: ["wontfix"])
                return WorkItemsGalleryView(
                    state: w.data(
                        empty, problem: .workItemsFailed(status: 502), filters: filters, missingLabels: ["workflow::gone"],
                        related: [:]),
                    size: minimum)
            },
            GalleryEntry(screen: "work-items", state: "empty", size: size) { f in
                let w = f.workItemsScreen
                let empty = WorkItemLists(committed: WorkItemList(count: 0, items: []), others: WorkItemList(count: 0, items: []))
                let filters = WorkItemFilters(withLabels: ["frontend", "design"], withoutLabels: ["wontfix"])
                return WorkItemsGalleryView(state: w.data(empty, filters: filters, related: [:]))
            },
            GalleryEntry(screen: "work-items", state: "no-token", size: size) { f in
                let w = f.workItemsScreen
                var state = w.data(loaded: false, problem: .noToken(.gitLab))
                state.panel.mergeRequests = PanelData.MergeRequests(problem: .noToken(.gitLab))
                return WorkItemsGalleryView(state: state)
            },
            GalleryEntry(screen: "work-items", state: "gitlab-problem", size: size) { f in
                WorkItemsGalleryView(state: f.workItemsScreen.data(
                    loaded: false, problem: .graphQLErrors(messages: ["Field 'type' doesn't exist on type 'Issue'"])))
            },
            GalleryEntry(screen: "work-items", state: "gitlab-problem-cached", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(problem: .workItemsFailed(status: 502)), selection: w.item31.id)
            },
            GalleryEntry(screen: "work-items", state: "loading", size: size) { f in
                WorkItemsGalleryView(state: f.workItemsScreen.data(loaded: false, isLoading: true))
            },
            GalleryEntry(screen: "work-items", state: "offline", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(jenkinsProblem: .offline), selection: w.item28.id)
            },
            GalleryEntry(screen: "work-items", state: "no-team-values", size: size) { f in
                WorkItemsGalleryView(state: f.workItemsScreen.data(jenkinsProblem: .teamValuesMissing, team: TeamValues()))
            },
            GalleryEntry(screen: "work-items", state: "search-results", size: size) { f in
                WorkItemsGalleryView(state: f.workItemsScreen.data(), query: "design")
            },
            GalleryEntry(screen: "work-items", state: "search-no-results", size: size) { f in
                WorkItemsGalleryView(state: f.workItemsScreen.data(), query: "zzz")
            },
            GalleryEntry(screen: "work-items", state: "many-items", size: size) { f in
                let w = f.workItemsScreen
                let lists = w.manyLists
                return WorkItemsGalleryView(
                    state: w.data(lists, related: [lists.all[0].reference: w.tenRelated]), selection: lists.all[0].id)
            },
            GalleryEntry(screen: "work-items", state: "long-titles", size: tall) { f in
                let w = f.workItemsScreen
                let lists = w.longLists
                let longMR = w.related(90, f.longTitle, .opened)
                return WorkItemsGalleryView(
                    state: w.data(lists, filters: w.longFilters, related: [lists.all[0].reference: [longMR]]),
                    selection: lists.all[0].id, size: tall)
            },
            // The description (WIN-02): cut after about 20 lines with Show More, and whole in a tall window.
            GalleryEntry(screen: "work-items", state: "description", size: size) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.item31.id)
                    .environment(\.descriptionFixtures, DescriptionFixtures(descriptions: [w.item31.reference: .loaded(w.description31)]))
            },
            GalleryEntry(screen: "work-items", state: "description-expanded", size: descriptionSize) { f in
                let w = f.workItemsScreen
                return WorkItemsGalleryView(state: w.data(), selection: w.item31.id, size: descriptionSize)
                    .environment(\.descriptionFixtures, DescriptionFixtures(
                        descriptions: [w.item31.reference: .loaded(w.description31)], expanded: true))
            },
        ]
    }
}
#endif

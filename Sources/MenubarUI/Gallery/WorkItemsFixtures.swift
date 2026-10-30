#if DEBUG
import Foundation
import MenubarCore

/// The work items of `docs/design/work-items.md`, States: made up, with GitLab's label colors and the related MRs.
/// The team of `team.example.json`: committed label `workflow::committed`, slot prefix `slot::`, ignored MR prefix
/// `[cascade]`; the project `group/subgroup/project`, another one `group/subgroup/web`. The last load 10:42.
struct WorkItemsFixtures {
    let f: Fixtures

    /// GitLab's colors of the labels the items carry
    static let colors: [String: String] = [
        "workflow::committed": "#6F42C1", "slot::Q1": "#9B59B6", "slot::Q2": "#9B59B6", "type::feature": "#5CB85C",
        "type::bug": "#D9534F", "design": "#330066", "frontend": "#F0AD4E", "backend": "#8E44AD", "docs": "#FFFFFF",
        "priority::high": "#D9534F", "team::web::frontend": "#5CB85C", "release": "#000000",
    ]

    /// "Assigned to me · Open · +frontend · −wontfix"
    var filters: WorkItemFilters {
        WorkItemFilters(withLabels: ["frontend"], withoutLabels: ["wontfix"])
    }

    /// A work item with everything set; the labels get their GitLab colors.
    func item(
        _ iid: Int, _ title: String, project: String = "group/subgroup/project", type: WorkItemType = .issue,
        state: WorkItemState = .opened, labels: [String] = [], updatedMinutesAgo: Double = 5
    ) -> WorkItem {
        let epic = type == .epic
        let reference = epic ? "group/subgroup&\(iid)" : "\(project)#\(iid)"
        let path = epic ? "groups/group/subgroup/-/epics/\(iid)" : "\(project)/-/issues/\(iid)"
        return WorkItem(
            reference: reference, title: title, webURL: URL(string: "https://gitlab.example.com/\(path)")!, type: type,
            state: state, labels: labels.map { Label(title: $0, color: Self.colors[$0]) },
            updatedAt: f.minutesAgo(updatedMinutesAgo))
    }

    /// A merge request that mentions a work item.
    func related(_ iid: Int, _ title: String, _ state: RelatedMergeRequest.State, project: String = "group/subgroup/project") -> RelatedMergeRequest {
        RelatedMergeRequest(
            iid: iid, state: state, title: title,
            webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!, reference: "\(project)!\(iid)")
    }

    // MARK: - The items

    var item31: WorkItem {
        item(31, "Rework the color tokens", labels: ["workflow::committed", "slot::Q1", "type::feature", "design", "frontend"])
    }

    var item28: WorkItem {
        item(28, "Speed up the search index rebuild", labels: ["workflow::committed", "slot::Q2", "type::bug", "backend", "frontend"],
             updatedMinutesAgo: 40)
    }

    var epic12: WorkItem {
        item(12, "Plan the settings window redesign", type: .epic, labels: ["design", "frontend"], updatedMinutesAgo: 300)
    }

    var web34: WorkItem {
        item(34, "Fix the date format in the export dialog", project: "group/subgroup/web", type: .task,
             labels: ["type::bug", "frontend"], updatedMinutesAgo: 90)
    }

    var item40: WorkItem {
        item(40, "Update the onboarding checklist", labels: ["frontend", "docs"], updatedMinutesAgo: 1440)
    }

    /// #31's discussion (WIN-02): a question with four replies (folded to the last two), a comment with one reply and a
    /// lone comment, by made-up people
    var discussion31: WorkItemDiscussion {
        let page = "https://gitlab.example.com/group/subgroup/project/-/issues/31#note_"
        func note(_ id: Int, _ username: String, _ name: String, _ minutesAgo: Double, _ body: String) -> ThreadNote {
            ThreadNote(
                id: "gid://gitlab/Note/\(id)", author: .init(username: username, name: name), body: body,
                createdAt: f.now.addingTimeInterval(-minutesAgo * 60), url: URL(string: page + "\(id)"))
        }
        return WorkItemDiscussion(threads: [
            CommentThread(
                id: "d1", first: note(901, "slee", "Sam Lee", 4300, "Do we need the **dark variants** to match the badge in the list, or only the detail?"),
                replies: [
                    note(902, "akim", "Alex Kim", 4000, "Both, I think. The list is where people notice the drift."),
                    note(903, "jdoe", "Jane Doe", 2900, "Agreed. I'll start with the shared color table."),
                    note(904, "slee", "Sam Lee", 1500, "Please keep the old names as aliases for one release, see `BadgeColors`."),
                    note(905, "akim", "Alex Kim", 35, "Done in the first commit, a look would be nice."),
                ]),
            CommentThread(
                id: "d2", first: note(906, "cnovak", "Chris Novak", 1200, "Is there a design for the high contrast case?"),
                replies: [note(907, "jdoe", "Jane Doe", 600, "Not yet, I asked the design team.")]),
            CommentThread(id: "d3", first: note(908, "akim", "Alex Kim", 5, "Moving this to the next slot.")),
        ])
    }

    /// #31's description (WIN-02), a made-up work item template: `###` sections, an image, nested bullets, check boxes,
    /// a table, a code block, a quote, links and raw HTML
    var description31: String {
        """
        ### Problem

        The badge colors live in four files. Changing one color takes four edits, and the dark variants have drifted \
        apart, as the screenshot shows.

        ![screenshot](/uploads/7d21e0/badges-dark.png)

        ### Proposal

        - Move every badge color into **one token file**
        - Read the light and dark variants from the same entry
          - the panel's badges first
          - then the main window
        - Remove the old constants once nothing reads them

        ### Acceptance criteria

        - [x] One token per badge state
        - [ ] Light and dark come from the same token
        - [ ] No color constant left in `BadgeView`
        - [ ] The snapshot tests pass in both appearances

        | State | Light | Dark |
        |:------|:-----:|-----:|
        | Success | `#108548` | `#52B87A` |
        | Failed | `#DD2B0E` | `#EC5941` |
        | Running | `#1F75CB` | `#428FDC` |

        ### Technical notes

        ```swift
        enum ColorTokens {
            static func badge(_ state: BuildState, scheme: ColorScheme) -> Color
        }
        ```

        > The settings window still reads the old constants; keep them until #28 is done.

        <details><summary>Measurements</summary>Contrast ratios are in the design file.</details>

        ### Links

        - Design: [color tokens](https://design.example.com/color-tokens)
        - Related: #28, !14
        - Not a web link, shown as text: [settings](menubar-monitor://settings)
        """
    }

    /// Committed (2) and Not Committed (3 of 45)
    var sections: WorkItemLists {
        WorkItemLists(
            committed: WorkItemList(count: 2, items: [item31, item28]),
            others: WorkItemList(count: 45, items: [epic12, web34, item40]))
    }

    /// the answers of the related MRs: #31 has !14 open and !11 merged; #28 !43 merged, the cascade !44 open and !42
    /// closed; web#34 web!8 open; #40 none
    var relatedAnswers: [String: [RelatedMergeRequest]] {
        [
            item31.reference: [related(14, "Rework the color tokens", .opened), related(11, "Move the color values into one file", .merged)],
            item28.reference: [
                related(44, "[cascade] Merge release/2.4 into main", .opened),
                related(43, "Speed up the search index rebuild", .merged),
                related(42, "Cache the search index between runs", .closed),
            ],
            web34.reference: [related(8, "Fix the date format in the export dialog", .opened, project: "group/subgroup/web")],
            item40.reference: [],
        ]
    }

    /// The cache of related MRs with answers, all fetched at the last load.
    func cache(_ answers: [String: [RelatedMergeRequest]]) -> RelatedMergeRequestsCache {
        RelatedMergeRequestsCache(entries: answers.mapValues {
            RelatedMergeRequestsCache.Entry(workItemUpdatedAt: f.now, fetchedAt: f.now, mergeRequests: $0)
        })
    }

    // MARK: - Data

    /// the Merge Requests store's MRs outside `related-in-merge-requests`: none of them mentions an item, one asks my
    /// review, for the sidebar's badge
    var otherMergeRequests: [MergeRequest] {
        let m = f.mergeRequestsScreen
        return [
            m.mr21, m.mr24,
            m.mergeRequest(17, "Move the settings import to the new format", status: "NOT_APPROVED", author: m.samLee,
                           reviewers: [m.reviewer("jdoe", .unreviewed)], updatedMinutesAgo: 20, roles: [.reviewRequested]),
        ]
    }

    /// The work items' part of the stores' values, with the markers of their related MRs.
    func panelWorkItems(
        _ lists: WorkItemLists? = nil, loaded: Bool = true, problem: Problem? = nil, isLoading: Bool = false,
        filters: WorkItemFilters? = nil, missingLabels: [String] = [], related: RelatedMergeRequestsCache? = nil
    ) -> PanelData.WorkItems {
        let lists = lists ?? (loaded ? sections : nil)
        let related = related ?? cache(loaded ? relatedAnswers : [:])
        var markers: [String: RelatedMergeRequestMarker] = [:]
        for item in lists?.all ?? [] {
            markers[item.reference] = related.marker(of: item, ignoredPrefix: f.team.ignoredMergeRequestPrefix)
        }
        return PanelData.WorkItems(
            lists: lists, problem: problem, isLoading: isLoading, lastLoadAt: loaded || problem != nil ? f.now : nil,
            markers: markers, missingLabels: missingLabels, filters: filters ?? self.filters)
    }

    /// The section's values: the items as loaded at 10:42, their related MRs, the Merge Requests store's MRs and the
    /// app-wide state.
    ///
    /// - Parameters:
    ///   - lists: the loaded items; `nil` takes the `sections` items, or none when `loaded` is false
    ///   - loaded: whether a load ever answered
    ///   - problem: the load's problem
    ///   - isLoading: whether a load runs
    ///   - filters: the work item filters; `nil` takes ``filters``
    ///   - missingLabels: the filter labels GitLab no longer has
    ///   - related: the answers of the related MRs; `nil` takes ``relatedAnswers``, or none when `loaded` is false
    ///   - mergeRequests: the Merge Requests store's MRs; `nil` takes ``otherMergeRequests``
    ///   - jenkinsProblem: offline, the team values or Jenkins' own
    ///   - team: the team values
    func data(
        _ lists: WorkItemLists? = nil, loaded: Bool = true, problem: Problem? = nil, isLoading: Bool = false,
        filters: WorkItemFilters? = nil, missingLabels: [String] = [], related: [String: [RelatedMergeRequest]]? = nil,
        mergeRequests: [MergeRequest]? = nil, jenkinsProblem: Problem? = nil, team: TeamValues? = nil
    ) -> WorkItemsGalleryState {
        let cache = cache(related ?? (loaded ? relatedAnswers : [:]))
        var panel = f.mergeRequestsScreen.panel(mergeRequests ?? otherMergeRequests, jenkinsProblem: jenkinsProblem, team: team)
        panel.workItems = panelWorkItems(
            lists, loaded: loaded, problem: problem, isLoading: isLoading, filters: filters, missingLabels: missingLabels,
            related: cache)
        return WorkItemsGalleryState(panel: panel, related: cache)
    }

    // MARK: - Other states

    /// the team without a committed label and a slot prefix: one list, no slots
    var teamWithoutLabels: TeamValues {
        var team = f.team
        team.committedLabel = ""
        team.slotLabelPrefix = ""
        return team
    }

    /// "Work Items (20 of 45)": #40 first, then 19 others
    var singleList: WorkItemLists {
        let titles = [
            "Speed up the search index", "Fix the flaky upload test", "Translate the settings pane", "Document the release steps",
            "Cache the label colors per project",
        ]
        let others = (0..<19).map { index in
            item(60 + index, titles[index % titles.count], labels: index.isMultiple(of: 3) ? ["type::bug"] : ["docs"],
                 updatedMinutesAgo: Double(index * 13 + 30))
        }
        return WorkItemLists(others: WorkItemList(count: 45, items: [item40] + others))
    }

    /// #46 with nine labels: scoped, nested, plain, white, black and one without a color
    var labelPillsItem: WorkItem {
        var item = item(46, "Sort the release notes by component", labels: [
            "workflow::committed", "slot::Q1", "priority::high", "team::web::frontend", "frontend", "design", "docs", "release",
        ])
        item.labels.append(Label(title: "needs-review"))
        return item
    }

    /// Any mode, the committed label excluded: "Created by me · Tasks · Open and closed · +(bug or design) · −committed"
    var anyFilters: WorkItemFilters {
        WorkItemFilters(
            scope: .authored, type: .task, state: .all, withLabels: ["type::bug", "design"],
            withoutLabels: ["workflow::committed"], labelsMatch: .any)
    }

    /// Not Committed (4): four tasks, #52 closed
    var anyLists: WorkItemLists {
        WorkItemLists(others: WorkItemList(count: 4, items: [
            item(52, "Remove the unused color constants", type: .task, state: .closed, labels: ["design"], updatedMinutesAgo: 20),
            item(53, "Check the contrast of the badges", type: .task, labels: ["design", "frontend"], updatedMinutesAgo: 35),
            item(54, "Fix the crash on an empty label search", type: .task, labels: ["type::bug"], updatedMinutesAgo: 70),
            item(55, "Round the duration in the alert", type: .task, state: .closed, labels: ["type::bug", "backend"],
                 updatedMinutesAgo: 400),
        ]))
    }

    /// 50 committed, 100 of 240 others; #31 with 30 labels and 10 MRs
    var manyLists: WorkItemLists {
        let titles = [
            "Speed up the search index", "Fix the flaky upload test", "Translate the settings pane", "Document the release steps",
            "Cache the label colors per project", "Remove the unused color constants", "Check the contrast of the badges",
        ]
        let manyLabels = ["workflow::committed", "slot::Q1"] + (1...28).map { "area::part-\($0)" }
        let committed = [item(31, "Rework the color tokens", labels: manyLabels)] + (1..<50).map { index in
            item(100 + index, titles[index % titles.count], labels: ["workflow::committed", "slot::Q\(index % 4 + 1)", "frontend"],
                 updatedMinutesAgo: Double(index * 9 + 4))
        }
        let others = (0..<100).map { index in
            item(300 + index, titles[(index + 2) % titles.count], labels: ["frontend", index.isMultiple(of: 2) ? "backend" : "docs"],
                 updatedMinutesAgo: Double(index * 17 + 10))
        }
        return WorkItemLists(committed: WorkItemList(count: 50, items: committed), others: WorkItemList(count: 240, items: others))
    }

    /// ten MRs that mention #31, the most GitLab lists
    var tenRelated: [RelatedMergeRequest] {
        (0..<10).map { index in
            related(60 + index, "Rework the color tokens, part \(index + 1)", index < 2 ? .opened : index < 8 ? .merged : .closed)
        }
    }

    /// the long slot, label and project of `long-titles`
    var longSlot: String { "slot::2026-Q4-stretch-goal-for-the-search-index-rework" }
    var longLabel: String { "team::platform::a-very-long-label-name-for-the-search-index-rework" }
    var longProject: String { "group/subgroup/a-very-long-project-name-for-the-search-index-rework" }

    /// three long must-have labels, in the summary
    var longFilters: WorkItemFilters {
        WorkItemFilters(withLabels: [
            "component::the-search-index-rework-for-the-export-dialog", "frontend-and-backend-integration-reviewed",
            "release::2026-Q4-stretch-goals-of-the-platform-team",
        ])
    }

    /// 200-character titles, the long slot and label, and an item of the long project
    var longLists: WorkItemLists {
        let musts = longFilters.withLabels
        return WorkItemLists(
            committed: WorkItemList(count: 1, items: [
                item(31, f.longTitle, labels: ["workflow::committed", longSlot, longLabel, "design"] + musts),
            ]),
            others: WorkItemList(count: 2, items: [
                item(77, f.longTitle, project: longProject, labels: [longLabel] + musts),
                item(78, "Update the onboarding checklist", labels: ["docs"] + musts),
            ]))
    }
}

/// A Work Items gallery state: the stores' values and the related MRs.
struct WorkItemsGalleryState {
    var panel: PanelData
    var related: RelatedMergeRequestsCache

    /// the section's values
    var data: WorkItemsData {
        WorkItemsData(panel, related: related, labelColors: WorkItemsFixtures.colors)
    }
}

extension Fixtures {
    /// the fixtures of the Work Items section
    var workItemsScreen: WorkItemsFixtures { WorkItemsFixtures(f: self) }
}
#endif

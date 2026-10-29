#if DEBUG
import Foundation
import MenubarCore

/// The data of `docs/design/main-window.md`, States: badges 2 / 1 / 3 unless a state says otherwise.
extension Fixtures {
    /// Returns the main window's data: my three builds and the watched one (2 running), the panel's merge requests
    /// loaded at 10:41 (1 to review), and 3 committed work items.
    func mainWindow(
        problem: Problem? = nil, isChecking: Bool = false, lastChecked: Bool = true, mine: [Build]? = nil,
        watched: [Build]? = nil, emptyState: PipelinesEmptyState? = nil, mergeRequests: PanelData.MergeRequests? = nil,
        workItems: PanelData.WorkItems? = nil, update: UpdateState = .upToDate, team: TeamValues? = nil
    ) -> PipelinesData {
        pipelines(
            problem: problem, isChecking: isChecking, lastChecked: lastChecked, mine: mine, watched: watched,
            emptyState: emptyState,
            mergeRequests: mergeRequests ?? PanelData.MergeRequests(list: mergeRequestsInAllSections, lastLoadAt: minutesAgo(1)),
            workItems: workItems ?? threeCommittedWorkItems, update: update, team: team)
    }

    /// Returns lane S's work items state for the main window's data, with S's related merge requests.
    func mainWindowWorkItems(_ data: PipelinesData) -> WorkItemsGalleryState {
        WorkItemsGalleryState(panel: data.panel, related: workItemsScreen.data().related)
    }

    /// the id of the merge request in Review Requested, !24
    var reviewRequestID: String {
        "https://gitlab.example.com/group/subgroup/project/-/merge_requests/24"
    }

    /// 3 committed work items, #31 with a slot and an open MR, and 3 not committed of 45
    var threeCommittedWorkItems: PanelData.WorkItems {
        var items = typicalWorkItems
        let committed = (items.lists?.committed?.items ?? [])
            + [workItem(26, "Add keyboard shortcuts to the filter menu", labels: ["workflow::committed", "slot::Q2"])]
        items.lists?.committed = WorkItemList(count: committed.count, items: committed)
        return items
    }

    /// `main-window.counts-zero`: nothing running, nothing to review, nothing committed
    var mainWindowCountsZero: PipelinesData {
        let mine = mergeRequests([mergeRequest(21, "Remove the old onboarding page")])
        var workItems = typicalWorkItems
        workItems.lists?.committed = WorkItemList(count: 0, items: [])
        return mainWindow(
            mine: [failedBuild, unstableBuild], watched: [],
            mergeRequests: PanelData.MergeRequests(list: mine, lastLoadAt: minutesAgo(1)), workItems: workItems)
    }

    /// `main-window.many-items`: 40 builds, 12 running; 50 merge requests to review; 50 committed work items
    var mainWindowMany: PipelinesData {
        var mine = [runningBuild]
        for index in 1..<40 {
            let number = 100 + index
            if index < 12 {
                mine.append(pipelineBuild(
                    "MR-\(number)", index, "Running change number \(String(index))", phase: .running,
                    startedMinutesAgo: Double(5 + index), estimateMinutes: 30,
                    stages: stages([("checkout", .success, 0.5), ("build", .inProgress, 2)])))
            } else {
                mine.append(pipelineBuild(
                    "MR-\(number)", index, "Finished change number \(String(index))",
                    phase: .finished(result: index % 2 == 0 ? .success : .failure, duration: 600),
                    startedMinutesAgo: Double(60 + index * 10), stages: nil))
            }
        }
        let reviews = (0..<50).map { reviewRequest(200 + $0, "Review request number \(String($0 + 1))", updatedMinutesAgo: Double($0 + 1)) }
        let committed = (0..<50).map {
            workItem(300 + $0, "Committed work item number \(String($0 + 1))", labels: ["workflow::committed"])
        }
        var workItems = typicalWorkItems
        workItems.lists?.committed = WorkItemList(count: 50, items: committed)
        return mainWindow(
            mine: mine, watched: [],
            mergeRequests: PanelData.MergeRequests(list: mergeRequests(reviews), lastLoadAt: minutesAgo(1)), workItems: workItems)
    }

    /// `main-window.long-titles`: committed work items with 200-character titles
    var longWorkItems: PanelData.WorkItems {
        var items = threeCommittedWorkItems
        let committed = [
            workItem(31, longTitle, labels: ["workflow::committed", "slot::Q1"]),
            workItem(28, longTitle, labels: ["workflow::committed", "type::feature", "frontend", "design"]),
        ]
        items.lists?.committed = WorkItemList(count: 2, items: committed)
        return items
    }
}
#endif

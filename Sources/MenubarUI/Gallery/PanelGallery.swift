#if DEBUG
import MenubarCore
import SwiftUI

/// The panel's content as the gallery shows it: no actions, spinners at once, and the hover look forced on chosen
/// rows, since the gallery's inactive windows show no real hover.
struct PanelGalleryView: View {
    let data: PanelData
    var query = ""
    var highlights: Set<String> = []

    var body: some View {
        PanelContent(data: data, actions: .none, query: query)
            .environment(\.panelSpinnerDelay, .zero)
            .environment(\.panelForcedHighlights, highlights)
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/panel.md`.
    static var panelEntries: [GalleryEntry] {
        return [
            GalleryEntry(screen: "panel", state: "typical", size: CGSize(width: 420, height: 670)) { f in
                PanelGalleryView(data: f.panel(mine: f.typicalBuilds))
            },
            GalleryEntry(screen: "panel", state: "loading", size: CGSize(width: 420, height: 600)) { f in
                PanelGalleryView(data: f.panel(
                    hasLoaded: false, isChecking: true, lastChecked: false,
                    mergeRequests: PanelData.MergeRequests(isLoading: true),
                    workItems: PanelData.WorkItems(isLoading: true)))
            },
            GalleryEntry(screen: "panel", state: "loading-cached", size: CGSize(width: 420, height: 670)) { f in
                var workItems = f.typicalWorkItems
                workItems.isLoading = true
                return PanelGalleryView(data: f.panel(
                    isChecking: true, mine: f.typicalBuilds,
                    mergeRequests: PanelData.MergeRequests(list: f.mergeRequestsInAllSections, isLoading: true, lastLoadAt: f.now),
                    workItems: workItems))
            },
            GalleryEntry(screen: "panel", state: "empty", size: CGSize(width: 420, height: 470)) { f in
                PanelGalleryView(data: f.panel(
                    emptyState: .noJobs(user: f.me),
                    mergeRequests: PanelData.MergeRequests(list: f.mergeRequests([]), lastLoadAt: f.now),
                    workItems: PanelData.WorkItems(
                        lists: WorkItemLists(committed: WorkItemList(count: 0, items: []), others: WorkItemList(count: 0, items: [])),
                        lastLoadAt: f.now)))
            },
            GalleryEntry(screen: "panel", state: "builds-running", size: CGSize(width: 420, height: 490)) { f in
                PanelGalleryView(data: f.panel(mine: [
                    f.running("MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25, stages: ["build", "tests"]),
                    f.running("MR-14", 2, "Show the merge status in the tooltip", startedMinutesAgo: 9, estimateMinutes: nil, stages: ["build"]),
                    f.running("MR-15", 5, "Retry the upload when the connection drops", startedMinutesAgo: 31, estimateMinutes: 28, stages: ["integration-tests"]),
                ]))
            },
            GalleryEntry(screen: "panel", state: "builds-finished", size: CGSize(width: 420, height: 550)) { f in
                PanelGalleryView(data: f.panel(mine: [
                    f.finished("MR-21", 4, "Remove the old onboarding page", .success, durationMinutes: 18, finishedMinutesAgo: 12),
                    f.finished("MR-19", 6, "Show the build number in the alert", .unstable, durationMinutes: 25, finishedMinutesAgo: 45,
                               failedStages: ["tests"], tests: TestCounts(failed: 2, total: 1200)),
                    f.finished("MR-16", 3, "Add a retry to the export job", .failure, durationMinutes: 12, finishedMinutesAgo: 30,
                               failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200)),
                    f.finished("MR-11", 9, "Cache the label colors per project", .aborted, durationMinutes: 3, finishedMinutesAgo: 300),
                    f.finished("MR-10", 1, "Translate the settings pane", .notBuilt, durationMinutes: 0, finishedMinutesAgo: 4320),
                ]))
            },
            GalleryEntry(screen: "panel", state: "watching", size: CGSize(width: 420, height: 510)) { f in
                PanelGalleryView(data: f.panel(
                    mine: [f.running("MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25, stages: ["build"])],
                    watched: [
                        f.running("MR-2", 14, "Retry the upload when the connection drops", startedMinutesAgo: 8, estimateMinutes: 20,
                                  stages: ["tests"], kind: .watched, author: "Sam Lee"),
                        f.finished("feature%252Fsearch", 3, "Search the label picker", .success, durationMinutes: 21, finishedMinutesAgo: 50,
                                   kind: .watched, author: "Sam Lee"),
                    ]))
            },
            GalleryEntry(screen: "panel", state: "rebuilding", size: CGSize(width: 420, height: 490)) { f in
                let failed = f.finished(
                    "MR-16", 3, "Add a retry to the export job", .failure, durationMinutes: 12, finishedMinutesAgo: 30,
                    failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200))
                let unstable = f.finished(
                    "MR-19", 6, "Show the build number in the alert", .unstable, durationMinutes: 25,
                    finishedMinutesAgo: 45, failedStages: ["tests"], tests: TestCounts(failed: 2, total: 1200))
                var data = f.panel(mine: [
                    f.running(
                        "MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25,
                        stages: ["build"]),
                    failed, unstable,
                ])
                data.jenkins.rebuilds = f.rebuilds(queued: failed.id, failed: unstable.id)
                return PanelGalleryView(data: data)
            },
            GalleryEntry(screen: "panel", state: "hidden-builds", size: CGSize(width: 420, height: 380)) { f in
                PanelGalleryView(data: f.panel(emptyState: .noBuilds, hiddenCount: 3))
            },
            GalleryEntry(screen: "panel", state: "highlighted-row", size: CGSize(width: 420, height: 420)) { f in
                PanelGalleryView(
                    data: f.panel(mine: f.typicalBuilds),
                    highlights: ["build:MR-12 #7", "summary:work-items", "footer:open-window"])
            },
            GalleryEntry(screen: "panel", state: "search-results", size: CGSize(width: 420, height: 340)) { f in
                PanelGalleryView(data: f.panel(mine: f.typicalBuilds), query: "login")
            },
            GalleryEntry(screen: "panel", state: "search-no-results", size: CGSize(width: 420, height: 310)) { f in
                PanelGalleryView(data: f.panel(mine: f.typicalBuilds), query: "zzz")
            },
            GalleryEntry(screen: "panel", state: "many-items", size: CGSize(width: 420, height: 700)) { f in
                let titles = ["Fix the login redirect", "Add a retry to the export job", "Show the build number", "Cache the label colors",
                              "Rename the cache folders", "Split the settings store", "Keep the window position", "Drop the old icons",
                              "Speed up the job lookup", "Translate the settings pane"]
                let mine = titles.enumerated().map { index, title in
                    index < 5
                        ? f.running("MR-\(40 + index)", 3 + index, title, startedMinutesAgo: Double(3 + index * 4), estimateMinutes: 25, stages: ["tests"])
                        : f.finished("MR-\(40 + index)", 2, title, .success, durationMinutes: 20, finishedMinutesAgo: Double(index * 20))
                }
                let watched = (0..<3).map { index in
                    f.finished("MR-\(60 + index)", 5, "A watched build of Sam Lee number \(index + 1)", .success, durationMinutes: 15,
                               finishedMinutesAgo: Double(30 + index * 10), kind: .watched, author: "Sam Lee")
                }
                let mergeRequests = (0..<50).map { index in
                    index < 20 ? f.reviewRequest(100 + index, "A review asked of me, number \(index + 1)", updatedMinutesAgo: Double(index * 7))
                        : f.mergeRequest(100 + index, "One of my merge requests, number \(index - 19)", updatedMinutesAgo: Double(index * 7))
                }
                var workItems = f.typicalWorkItems
                workItems.lists = WorkItemLists(
                    committed: WorkItemList(count: 12, items: []), others: WorkItemList(count: 120, items: []))
                return PanelGalleryView(data: f.panel(
                    mine: mine, watched: watched, hiddenCount: 2,
                    mergeRequests: PanelData.MergeRequests(list: f.mergeRequests(mergeRequests), lastLoadAt: f.now),
                    workItems: workItems))
            },
            GalleryEntry(screen: "panel", state: "long-titles", size: CGSize(width: 420, height: 670)) { f in
                let author = "Maximiliane Konstanze Müller-Lüdenscheidt"
                let mine = [
                    f.running("MR-12", 7, f.longTitle, startedMinutesAgo: 5, estimateMinutes: 25,
                              stages: ["integration-tests-with-a-long-name", "deploy-to-the-staging-environment", "smoke-tests"]),
                    f.finished("feature%252Fa-very-long-branch-name-for-the-search-index-rework", 12, nil, .failure, durationMinutes: 65,
                               finishedMinutesAgo: 30, failedStages: ["integration-tests-with-a-long-name", "deploy-to-the-staging-environment"],
                               tests: TestCounts(failed: 12, total: 4200)),
                ]
                let watched = [f.running("MR-2", 14, f.longTitle, startedMinutesAgo: 8, estimateMinutes: 20, stages: ["tests"],
                                         kind: .watched, author: author)]
                return PanelGalleryView(data: f.panel(mine: mine, watched: watched))
            },
            GalleryEntry(screen: "panel", state: "jenkins-problem", size: CGSize(width: 420, height: 330)) { f in
                PanelGalleryView(data: f.panel(problem: .unreachable(.jenkins)))
            },
            GalleryEntry(screen: "panel", state: "jenkins-problem-cached", size: CGSize(width: 420, height: 450)) { f in
                PanelGalleryView(data: f.panel(problem: .rejectedToken(.jenkins), mine: f.typicalBuilds))
            },
            GalleryEntry(screen: "panel", state: "no-jenkins-token", size: CGSize(width: 420, height: 450)) { f in
                PanelGalleryView(data: f.panel(problem: .noToken(.jenkins), lastChecked: false))
            },
            GalleryEntry(screen: "panel", state: "no-gitlab-token", size: CGSize(width: 420, height: 530)) { f in
                PanelGalleryView(data: f.panel(
                    mine: [f.typicalBuilds[0]],
                    mergeRequests: PanelData.MergeRequests(problem: .noToken(.gitLab), lastLoadAt: f.now),
                    workItems: PanelData.WorkItems(problem: .noToken(.gitLab), lastLoadAt: f.now)))
            },
            GalleryEntry(screen: "panel", state: "gitlab-problem", size: CGSize(width: 420, height: 480)) { f in
                PanelGalleryView(data: f.panel(
                    mine: [f.typicalBuilds[0]],
                    mergeRequests: PanelData.MergeRequests(problem: .unreachable(.gitLab), lastLoadAt: f.now),
                    workItems: PanelData.WorkItems(problem: .unreachable(.gitLab), lastLoadAt: f.now)))
            },
            GalleryEntry(screen: "panel", state: "gitlab-problem-cached", size: CGSize(width: 420, height: 670)) { f in
                var workItems = f.typicalWorkItems
                workItems.problem = .workItemsFailed(status: 502)
                return PanelGalleryView(data: f.panel(
                    mine: [f.typicalBuilds[0]],
                    mergeRequests: PanelData.MergeRequests(
                        list: f.mergeRequestsInAllSections, problem: .rejectedToken(.gitLab), lastLoadAt: f.now),
                    workItems: workItems))
            },
            GalleryEntry(screen: "panel", state: "gone-filter-label", size: CGSize(width: 420, height: 510)) { f in
                var workItems = f.typicalWorkItems
                workItems.lists = WorkItemLists(others: WorkItemList(count: 3, items: [
                    f.workItem(40, "Speed up the search index", labels: ["workflow::gone"]),
                    f.workItem(38, "Fix the flaky upload test"),
                    f.workItem(35, "Translate the settings pane"),
                ]))
                workItems.missingLabels = ["workflow::gone"]
                workItems.filters = WorkItemFilters(withLabels: ["workflow::gone"])
                var team = f.team
                team.committedLabel = ""
                return PanelGalleryView(
                    data: f.panel(mine: [f.typicalBuilds[0]], workItems: workItems, team: team))
            },
            GalleryEntry(screen: "panel", state: "no-team-values", size: CGSize(width: 420, height: 240)) { f in
                PanelGalleryView(data: f.panel(problem: .teamValuesMissing, lastChecked: false, team: TeamValues()))
            },
            GalleryEntry(screen: "panel", state: "offline", size: CGSize(width: 420, height: 450)) { f in
                var workItems = f.typicalWorkItems
                workItems.isLoading = true
                return PanelGalleryView(
                    data: f.panel(
                        problem: .offline, mine: f.typicalBuilds,
                        mergeRequests: PanelData.MergeRequests(list: f.mergeRequestsInAllSections, problem: .unreachable(.gitLab), lastLoadAt: f.now),
                        workItems: workItems))
            },
        ]
    }
}
#endif

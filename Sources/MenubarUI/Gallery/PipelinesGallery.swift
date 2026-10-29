#if DEBUG
import MenubarCore
import SwiftUI

/// The whole main window with Pipelines selected, as the gallery shows it: the shell from fixtures, the Pipelines
/// list and the selected job's detail.
struct PipelinesGalleryView: View {
    let data: PipelinesData
    var selection: String?
    var query = ""
    var sidebarVisible = true
    var size = MainWindowGallerySize.standard
    var failedTests = FailedTestsFixtures.standard
    var flakyHints = FlakyHintFixtures(states: [:])

    var body: some View {
        MainWindowGalleryView(
            model: MainWindowShellModel(data.panel, section: .pipelines), section: .pipelines, searchText: query,
            sidebarVisible: sidebarVisible, size: size
        ) {
            PipelinesListContent(model: PipelinesListModel(data, query: query), selection: .constant(selection), actions: .none)
        } detail: {
            BuildDetailContent(model: selection.flatMap { BuildDetailModel(job: $0, data: data) }, actions: .none)
                .environment(\.failedTestsFixtures, failedTests)
                .environment(\.flakyHintFixtures, flakyHints)
        }
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/pipelines.md`.
    static var pipelinesEntries: [GalleryEntry] {
        let size = MainWindowGallerySize.standard
        let minimum = MainWindowGallerySize.minimum
        return [
            GalleryEntry(screen: "pipelines", state: "running", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(), selection: "MR-12")
            },
            GalleryEntry(screen: "pipelines", state: "running-no-estimate", size: size) { f in
                let build = f.pipelineBuild(
                    "MR-18", 2, "Speed up the search index rebuild", phase: .running, startedMinutesAgo: 2, stages: [])
                return PipelinesGalleryView(data: f.pipelines(mine: f.pipelineBuilds + [build]), selection: "MR-18")
            },
            GalleryEntry(screen: "pipelines", state: "running-past-estimate", size: size) { f in
                let build = f.pipelineBuild(
                    "MR-19", 5, "Migrate the settings storage", phase: .running, startedMinutesAgo: 41, estimateMinutes: 30,
                    stages: f.stages([("checkout", .success, 0.5), ("build", .success, 5), ("approval", .pausedPendingInput, 35)]))
                return PipelinesGalleryView(data: f.pipelines(mine: f.pipelineBuilds + [build]), selection: "MR-19")
            },
            GalleryEntry(screen: "pipelines", state: "failure", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(), selection: "MR-16")
            },
            GalleryEntry(screen: "pipelines", state: "failed-tests", size: size) { f in
                PipelinesGalleryView(
                    data: f.pipelines(mine: f.pipelineBuilds + [f.failedTestsBuild]), selection: "MR-24",
                    failedTests: .manyTests)
            },
            GalleryEntry(screen: "pipelines", state: "likely-flaky", size: size) { f in
                PipelinesGalleryView(
                    data: f.pipelines(), selection: "MR-16",
                    flakyHints: FlakyHintFixtures(states: [
                        f.failedBuild.id: .loaded([
                            .passedOnSameCommit(stage: "tests", build: 2),
                            .failedBefore(stage: "deploy", failed: 3, of: 10),
                        ])
                    ]))
            },
            GalleryEntry(screen: "pipelines", state: "rebuilding", size: size) { f in
                var data = f.pipelines()
                data.panel.jenkins.rebuilds = f.rebuilds(queued: f.failedBuild.id, failed: f.unstableBuild.id)
                return PipelinesGalleryView(data: data, selection: "MR-16")
            },
            GalleryEntry(screen: "pipelines", state: "unstable", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(), selection: "MR-9")
            },
            GalleryEntry(screen: "pipelines", state: "success", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: f.pipelineBuilds + [f.successfulBranchBuild]), selection: "feature%252Ffoo")
            },
            GalleryEntry(screen: "pipelines", state: "aborted", size: size) { f in
                let build = f.pipelineBuild(
                    "MR-21", 4, "Clean up the old report exporter", phase: .finished(result: .aborted, duration: 3 * 60),
                    startedMinutesAgo: 60, stages: nil)
                return PipelinesGalleryView(data: f.pipelines(mine: f.pipelineBuilds + [build]), selection: "MR-21")
            },
            GalleryEntry(screen: "pipelines", state: "other-result", size: size) { f in
                let build = f.pipelineBuild(
                    "MR-22", 1, "Try the new linter rules", phase: .finished(result: .notBuilt, duration: 0),
                    startedMinutesAgo: 90, stages: nil)
                return PipelinesGalleryView(data: f.pipelines(mine: f.pipelineBuilds + [build]), selection: "MR-22")
            },
            GalleryEntry(screen: "pipelines", state: "stages-unknown", size: size) { f in
                var build = f.failedBuild
                build.stages = nil
                return PipelinesGalleryView(data: f.pipelines(mine: [f.runningBuild, build, f.unstableBuild]), selection: "MR-16")
            },
            GalleryEntry(screen: "pipelines", state: "watched", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(), selection: "MR-14")
            },
            GalleryEntry(screen: "pipelines", state: "waiting", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(waiting: [f.waitingJob]), selection: "MR-2")
            },
            GalleryEntry(screen: "pipelines", state: "hidden-builds", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: [f.runningBuild, f.failedBuild], watched: [], hiddenCount: 2))
            },
            GalleryEntry(screen: "pipelines", state: "all-hidden", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: [], watched: [], emptyState: .noBuilds, hiddenCount: 3))
            },
            GalleryEntry(screen: "pipelines", state: "no-builds", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: [], watched: [], emptyState: .noBuilds))
            },
            GalleryEntry(screen: "pipelines", state: "no-jobs", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: [], watched: [], emptyState: .noJobs(user: f.me)))
            },
            GalleryEntry(screen: "pipelines", state: "no-jobs-watching", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(mine: [], emptyState: .noJobs(user: f.me)))
            },
            GalleryEntry(screen: "pipelines", state: "loading", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(
                    hasLoaded: false, isChecking: true, lastChecked: false, mine: [], watched: [],
                    mergeRequests: PanelData.MergeRequests(), workItems: PanelData.WorkItems()))
            },
            GalleryEntry(screen: "pipelines", state: "jenkins-problem", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(problem: .unreachable(.jenkins), mine: [], watched: []))
            },
            GalleryEntry(screen: "pipelines", state: "jenkins-problem-cached", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(problem: .rejectedToken(.jenkins)), selection: "MR-16")
            },
            GalleryEntry(screen: "pipelines", state: "no-token", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(problem: .noToken(.jenkins), lastChecked: false, mine: [], watched: []))
            },
            GalleryEntry(screen: "pipelines", state: "no-team-values", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(
                    problem: .teamValuesMissing, lastChecked: false, mine: [], watched: [], team: TeamValues()))
            },
            GalleryEntry(screen: "pipelines", state: "offline", size: size) { f in
                PipelinesGalleryView(
                    data: f.pipelines(problem: .offline, mine: [f.runningBuild, f.failedBuild], watched: []), selection: "MR-12")
            },
            GalleryEntry(screen: "pipelines", state: "search-results", size: size) { f in
                let export = f.pipelineBuild(
                    "MR-23", 1, "Speed up the CSV export", phase: .running, startedMinutesAgo: 6, estimateMinutes: 20,
                    stages: f.stages([("build", .inProgress, 3)]), kind: .watched, author: "Sam Lee")
                return PipelinesGalleryView(data: f.pipelines(watched: [f.watchedBuild, export]), query: "export")
            },
            GalleryEntry(screen: "pipelines", state: "search-no-results", size: size) { f in
                PipelinesGalleryView(data: f.pipelines(), query: "zzz")
            },
            GalleryEntry(screen: "pipelines", state: "many-items", size: size) { f in
                PipelinesGalleryView(data: f.manyPipelines, selection: "MR-5")
            },
            GalleryEntry(screen: "pipelines", state: "long-titles", size: minimum) { f in
                PipelinesGalleryView(data: f.longPipelines, selection: "MR-14", size: minimum)
            },
        ]
    }
}
#endif

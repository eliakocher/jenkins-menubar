import AppKit
import MenubarCore
import SwiftUI

/// The menubar panel (Task 4.3, `docs/design/panel.md`): problem rows, My Builds and Watching with a search over them,
/// one summary row each for Merge Requests and Work Items, and the footer's commands (APP-06).
///
/// It reads the stores and the router from the environment (``SwiftUICore/View/appEnvironment(_:router:)``) and
/// draws a ``PanelContent`` from them, refreshed at least every 10 s for the running builds' times.
/// - On open: it tells the scheduler its GitLab summaries show (OD-02), moves the hiding rules' time on (HIDE-02) and
///   checks for an update (APP-05). On close: they no longer show.
/// - Every action that opens a window, Settings or a web page closes the panel, which opening doesn't do by itself
///   (`docs/decisions.md`, Task 0.10).
public struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// the name the panel reports its surfaces under
    static let host = "panel"

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            PanelContent(data: Self.data(model, now: context.date), actions: actions)
        }
        .onAppear {
            // The summary rows show the GitLab counts, so those load while the panel is open (OD-02).
            router.report(Self.surfaces, shownBy: Self.host, to: model.scheduler)
            model.projects.refreshTime()
            let updates = model.updates
            Task { await updates.check() }
        }
        .onDisappear {
            router.report([], shownBy: Self.host, to: model.scheduler)
        }
    }

    /// the GitLab surfaces the panel's summary rows show while it is open (APP-06, OD-02)
    static let surfaces: Set<Surface> = [.mergeRequests, .workItems]

    private var actions: PanelActions {
        let model = model
        let router = router
        let dismiss = dismiss
        let openURL = openURL
        return PanelActions(
            open: { url in
                openURL(url)
                dismiss()
            },
            openSettings: { pane in
                router.open(.settings(pane: pane))
                dismiss()
            },
            openWindow: {
                router.open(.main)
                dismiss()
            },
            watchBuild: {
                router.open(.watch(WatchRequest()))
                dismiss()
            },
            checkNow: { model.checkNow() },
            showHidden: { model.projects.unhideAll() },
            rebuild: {
                let updates = model.updates
                Task {
                    if let app = await updates.rebuild() {
                        router.onRebuilt?(app)
                    }
                }
            },
            quit: { NSApp.terminate(nil) },
            hide: { model.projects.hide($0) },
            stopWatching: { model.pipelines.unwatch($0) },
            copy: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            },
            close: { dismiss() },
            // The panel stays open, so the row's "Rebuilding…" shows (PIPE-09).
            rebuildBuild: { model.projects.rebuild($0) },
            cancelRebuild: { job in
                let projects = model.projects
                Task { await projects.cancelRebuild(jobKey: job) }
            },
            // The panel's summary rows open the main window at their section.
            openSection: { section in
                router.open(section)
                dismiss()
            })
    }

    /// Returns every project's builds as the panel's plain values: the primary project's state, with the other
    /// projects' builds, problems and rebuilds added (plan Phase 13).
    static func jenkins(_ projects: ProjectsPipelines) -> PanelData.Jenkins {
        let primary = projects.primary
        let mine = projects.myBuilds
        let watched = projects.watchedBuilds
        var jenkins = PanelData.Jenkins(
            problem: projects.problem, hasLoaded: primary.hasLoaded, isChecking: projects.isChecking,
            lastCheckedAt: primary.lastCheckedAt, mine: mine, watched: watched,
            emptyState: PipelineRules.emptyState(state: primary.state, mine: mine, watched: watched),
            hiddenCount: projects.hiddenCount,
            rebuilds: projects.rebuilds,
            // Every project's jobs, by their keys, for "Watch Builds" on an MR (WATCH-01).
            myJobs: primary.state.myJobs.map { _ in
                projects.stores.flatMap { store in
                    (store.state.myJobs ?? []).map { BuildID.jobKey($0, project: store.projectID) }
                }
            },
            watchedJobs: projects.stores.flatMap { store in
                store.userState.watched.map { BuildID.jobKey($0.job, project: store.projectID) }
            })
        for store in projects.stores {
            jenkins.projects[store.projectID] = PanelData.Jenkins.ProjectInfo(
                name: projects.hasSeveral ? projects.names[store.projectID] : nil, jobURL: store.project.team.jenkinsJob,
                gitLabProject: store.project.team.gitLabProject)
        }
        jenkins.problemProject = projects.problemProjectName
        return jenkins
    }

    /// Returns what the stores hold now, as the panel's plain values.
    static func data(_ model: AppModel, now: Date) -> PanelData {
        let pipelines = model.pipelines
        let projects = model.projects
        let mergeRequests = model.mergeRequests
        let workItems = model.workItems
        let team = pipelines.project.team
        let filters = pipelines.preferences.workItems
        var markers: [String: RelatedMergeRequestMarker] = [:]
        for item in workItems.lists?.all ?? [] {
            markers[item.reference] = workItems.marker(of: item, ignoredPrefix: team.ignoredMergeRequestPrefix)
        }
        return PanelData(
            now: now,
            team: team,
            jenkins: Self.jenkins(projects),
            mergeRequests: PanelData.MergeRequests(
                list: mergeRequests.list, problem: mergeRequests.problem, isLoading: mergeRequests.isLoading,
                lastLoadAt: mergeRequests.lastLoadAt),
            workItems: PanelData.WorkItems(
                lists: workItems.lists, problem: workItems.problem, isLoading: workItems.isLoading,
                lastLoadAt: workItems.lastLoadAt, markers: markers,
                missingLabels: workItems.labels.missingFilterLabels(of: filters), filters: filters,
                labelColors: workItems.labels.colors),
            update: model.updates.state)
    }
}

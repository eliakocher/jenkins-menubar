import MenubarCore
import SwiftUI

/// The stores' values as the plain ``PanelData`` that the menu pane, its flyouts and the main window's lists read.
/// The glass panel this was once the view of is gone (the menu pane replaced it).
@MainActor
enum PanelView {
    /// the name the menu pane reports its surfaces under
    static let host = "panel"

    /// the GitLab surfaces the menu pane's overview rows show while it is open (APP-06, OD-02)
    static let surfaces: Set<Surface> = [.mergeRequests, .workItems]

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
        jenkins.notifications = projects.notifications
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

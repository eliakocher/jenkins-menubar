#if DEBUG
import Foundation
import MenubarCore

/// The fake data the gallery entries draw from, so every screen can be shown in every state without a network. The
/// phases that add the models add their fixtures here.
///
/// Made up throughout: the user `jdoe` ("Jane Doe"), "Sam Lee", the project `group/subgroup/project` on
/// `gitlab.example.com`, the job `https://jenkins.example.com/job/project` (as `team.example.json`). The time is
/// 10:42 today, local time, so the panel's "Last checked 10:42" reads the same in every time zone.
public struct Fixtures: Sendable {
    /// 10:42 today, local time
    public let now: Date

    public init() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 10
        components.minute = 42
        now = Calendar.current.date(from: components) ?? Date()
    }

    /// the team values of `team.example.json`
    public var team: TeamValues {
        TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "group/subgroup/project", committedLabel: "workflow::committed", slotLabelPrefix: "slot::",
            ignoredMergeRequestPrefix: "[cascade]")
    }

    public var me: String { "jdoe" }
    public var jobURL: URL { URL(string: "https://jenkins.example.com/job/project")! }

    func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    // MARK: - Builds

    /// A running build: started some minutes ago, with an estimate or none, and its running stages.
    func running(
        _ job: String, _ number: Int, _ title: String?, startedMinutesAgo: Double, estimateMinutes: Double?,
        stages: [String] = [], kind: JobKind = .mine, author: String? = nil
    ) -> Build {
        Build(
            job: job, number: number, title: title, gitLabURL: gitLabURL(of: job), author: author, kind: kind,
            phase: .running, startedAt: minutesAgo(startedMinutesAgo), estimatedDuration: estimateMinutes.map { $0 * 60 },
            stages: stages.map { Stage(name: $0, status: .inProgress, duration: 0) })
    }

    /// A finished build: its result, how long it took and how long ago it finished, its failed stages and tests.
    func finished(
        _ job: String, _ number: Int, _ title: String?, _ result: BuildResult, durationMinutes: Double,
        finishedMinutesAgo: Double, failedStages: [String] = [], tests: TestCounts? = nil, kind: JobKind = .mine,
        author: String? = nil
    ) -> Build {
        let stages = failedStages.isEmpty ? nil : failedStages.map { Stage(name: $0, status: .failed, duration: 60) }
        return Build(
            job: job, number: number, title: title, gitLabURL: gitLabURL(of: job), author: author, kind: kind,
            phase: .finished(result: result, duration: durationMinutes * 60),
            startedAt: minutesAgo(finishedMinutesAgo + durationMinutes), stages: stages, testCounts: tests)
    }

    /// The MR of an `MR-<iid>` job, or the branch in GitLab.
    private func gitLabURL(of job: String) -> URL? {
        if let iid = Build.mergeRequestIID(forJob: job) {
            return URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/\(iid)")
        }
        return URL(string: "https://gitlab.example.com/group/subgroup/project/-/tree/\(Build.label(forJob: job))")
    }

    // MARK: - Merge requests

    func mergeRequest(
        _ iid: Int, _ title: String, project: String = "group/subgroup/project", status: MergeRequest.MergeStatus? = .mergeable,
        draft: Bool = false, pipeline: MergeRequest.PipelineStatus? = .success, author: MergeRequest.Person? = nil,
        reviewers: [MergeRequest.Reviewer] = [], updatedMinutesAgo: Double = 5, roles: Set<MergeRequest.Role> = [.authored],
        diff: MergeRequest.DiffStats = MergeRequest.DiffStats(additions: 10, deletions: 2, fileCount: 3)
    ) -> MergeRequest {
        MergeRequest(
            iid: iid, title: title, webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
            reference: "\(project)!\(iid)", isDraft: draft, mergeStatus: status,
            author: author ?? MergeRequest.Person(username: me, name: "Jane Doe"), reviewers: reviewers,
            pipelineStatus: pipeline, diffStats: diff, updatedAt: minutesAgo(updatedMinutesAgo), roles: roles)
    }

    var samLee: MergeRequest.Person { MergeRequest.Person(username: "slee", name: "Sam Lee") }

    /// Someone else's MR whose review is asked of me.
    func reviewRequest(_ iid: Int, _ title: String, approved: Bool = false, updatedMinutesAgo: Double = 12) -> MergeRequest {
        mergeRequest(
            iid, title, status: .notApproved, author: samLee,
            reviewers: [MergeRequest.Reviewer(username: me, reviewState: approved ? .approved : .unreviewed, approved: approved)],
            updatedMinutesAgo: updatedMinutesAgo, roles: [.reviewRequested])
    }

    func mergeRequests(_ mergeRequests: [MergeRequest]) -> MergeRequestList {
        MergeRequestList(username: me, mergeRequests: mergeRequests)
    }

    /// One MR in each of the three sections.
    var mergeRequestsInAllSections: MergeRequestList {
        mergeRequests([
            mergeRequest(21, "Remove the old onboarding page"),
            mergeRequest(19, "Show the build number in the alert", status: .ciStillRunning, pipeline: .running, updatedMinutesAgo: 40),
            reviewRequest(24, "Cache the label colors per project"),
            reviewRequest(17, "Move the settings import to the new format", approved: true, updatedMinutesAgo: 180),
        ])
    }

    // MARK: - Work items

    func workItem(
        _ iid: Int, _ title: String, project: String = "group/subgroup/project", epic: Bool = false,
        labels: [String] = [], updatedMinutesAgo: Double = 30
    ) -> WorkItem {
        let reference = epic ? "group&\(iid)" : "\(project)#\(iid)"
        let path = epic ? "groups/group/-/epics/\(iid)" : "\(project)/-/issues/\(iid)"
        return WorkItem(
            reference: reference, title: title, webURL: URL(string: "https://gitlab.example.com/\(path)")!,
            type: epic ? .epic : .issue, labels: labels.map { Label(title: $0) }, updatedAt: minutesAgo(updatedMinutesAgo))
    }

    /// 2 committed work items (a slot with an open MR, one plain), 3 not committed of 45.
    var typicalWorkItems: PanelData.WorkItems {
        let committed = [
            workItem(31, "Rework the color tokens", labels: ["workflow::committed", "slot::Q1"]),
            workItem(28, "Document the release steps", labels: ["workflow::committed"]),
        ]
        let others = [
            workItem(40, "Speed up the search index"),
            workItem(38, "Fix the flaky upload test", labels: ["type::bug"]),
            workItem(35, "Translate the settings pane"),
        ]
        return PanelData.WorkItems(
            lists: WorkItemLists(committed: WorkItemList(count: 2, items: committed), others: WorkItemList(count: 45, items: others)),
            lastLoadAt: now, markers: ["group/subgroup/project#31": .open], filters: WorkItemFilters(),
            labelColors: ["workflow::committed": "#6F42C1", "slot::Q1": "#9B59B6"])
    }

    // MARK: - Panel

    /// my running build with an estimate and my failed build with stages and tests
    var typicalBuilds: [Build] {
        [
            running("MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25, stages: ["build", "tests"]),
            finished("MR-16", 3, "Add a retry to the export job", .failure, durationMinutes: 12, finishedMinutesAgo: 30,
                     failedStages: ["tests", "deploy"], tests: TestCounts(failed: 3, total: 1200)),
        ]
    }

    func panel(
        problem: Problem? = nil, hasLoaded: Bool = true, isChecking: Bool = false, lastChecked: Bool = true,
        mine: [Build] = [], watched: [Build] = [], emptyState: PipelinesEmptyState? = nil, hiddenCount: Int = 0,
        mergeRequests: PanelData.MergeRequests? = nil, workItems: PanelData.WorkItems? = nil,
        update: UpdateState = .upToDate, team: TeamValues? = nil
    ) -> PanelData {
        PanelData(
            now: now, team: team ?? self.team,
            jenkins: PanelData.Jenkins(
                problem: problem, hasLoaded: hasLoaded, isChecking: isChecking, lastCheckedAt: lastChecked ? now : nil,
                mine: mine, watched: watched, emptyState: emptyState, hiddenCount: hiddenCount),
            mergeRequests: mergeRequests ?? PanelData.MergeRequests(list: mergeRequestsInAllSections, lastLoadAt: now),
            workItems: workItems ?? typicalWorkItems,
            update: update)
    }

    // MARK: - Alerts

    /// the MR job's alert title, two lines in the alert
    var alertTitle: String { "Add a dark mode to the report page and the export dialog" }

    /// A finished build's alert, as `AlertPolicy` builds it.
    func alert(_ build: Build) -> BuildAlert {
        let content = AlertContent.finished(
            build, failedStages: build.failedStages ?? [], links: AlertContent.links(for: build, jobURL: jobURL))!
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    /// `MR-1 #7` with the dark mode title
    func mergeRequestAlert(_ result: BuildResult, minutes: Double, title: String? = nil, failedStages: [String] = [],
                           tests: TestCounts? = nil) -> BuildAlert {
        alert(finished("MR-1", 7, title ?? alertTitle, result, durationMinutes: minutes, finishedMinutesAgo: 0,
                       failedStages: failedStages, tests: tests))
    }

    /// `feature/dark-mode #3`, a branch build without an MR
    func branchAlert(_ result: BuildResult, minutes: Double, failedStages: [String] = [], tests: TestCounts? = nil) -> BuildAlert {
        var build = finished("feature%252Fdark-mode", 3, "Dark mode for the report page", result, durationMinutes: minutes,
                             finishedMinutesAgo: 0, failedStages: failedStages, tests: tests)
        build.gitLabURL = nil
        return alert(build)
    }

    // MARK: - Long texts

    /// a 200-character title
    var longTitle: String {
        "Rework how the export dialog chooses its default folder, remembers the last format per project, and reports "
            + "partial failures when some of the selected reports could not be written to the chosen disk"
    }
}
#endif

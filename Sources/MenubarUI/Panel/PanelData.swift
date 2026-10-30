import Foundation
import MenubarCore

/// Everything the panel shows, as plain values: what the stores hold at one moment. ``PanelView`` takes it from the
/// stores; the gallery and the tests build it from fixtures, so no state needs a network or a store.
public struct PanelData: Sendable {
    /// the time the rows count from: elapsed times, ETAs and ages
    public var now: Date
    public var team: TeamValues
    public var jenkins: Jenkins
    public var mergeRequests: MergeRequests
    public var workItems: WorkItems
    /// where the app's update stands (APP-05)
    public var update: UpdateState

    public init(now: Date, team: TeamValues, jenkins: Jenkins, mergeRequests: MergeRequests, workItems: WorkItems,
                update: UpdateState = .upToDate) {
        self.now = now
        self.team = team
        self.jenkins = jenkins
        self.mergeRequests = mergeRequests
        self.workItems = workItems
        self.update = update
    }

    /// My builds and the watched ones, from `PipelinesStore`.
    public struct Jenkins: Sendable {
        /// the problem to show, offline first (`PipelinesStore.problem`)
        public var problem: Problem?
        /// whether there are builds from the cache or a check; until then the section shows placeholders (OD-01)
        public var hasLoaded: Bool
        public var isChecking: Bool
        public var lastCheckedAt: Date?
        /// my builds that show, newest first
        public var mine: [Build]
        /// the watched builds that show, newest first
        public var watched: [Build]
        /// what My Builds says without builds (PIPE-06)
        public var emptyState: PipelinesEmptyState?
        /// the builds hidden by hand that would show otherwise (HIDE-01)
        public var hiddenCount: Int
        /// the rebuilds started from the app, per job (PIPE-09)
        public var rebuilds: [String: JenkinsRebuild]
        /// my jobs from the last Jenkins lookup; `nil` before the first one (PIPE-01)
        public var myJobs: [String]?
        /// the jobs watched now, whether or not their builds show yet, for "Watch Builds" on an MR (WATCH-01)
        public var watchedJobs: [String]
        /// each project's name, while there are several, and Jenkins job (plan Phase 13); empty puts every build in the
        /// team's job
        public var projects: [ProjectID: ProjectInfo] = [:]
        /// the name of the project the problem is of, while there are several; `nil` for a problem of all of them
        public var problemProject: String?
        /// which builds may alert; the rows mark the muted jobs and the menus set them (ALERT-08)
        public var notifications = NotificationPolicy()

        /// What a build row needs of its project.
        public struct ProjectInfo: Hashable, Sendable {
            /// the name; `nil` with a single project, so nothing names it
            public var name: String?
            /// the project's Jenkins multibranch job
            public var jobURL: URL?
            /// the project's GitLab path, like `group/project`, which a merge request's reference starts with
            public var gitLabProject: String

            public init(name: String?, jobURL: URL?, gitLabProject: String = "") {
                self.name = name
                self.jobURL = jobURL
                self.gitLabProject = gitLabProject
            }
        }

        /// Returns the project of a merge request, by the path of its reference.
        ///
        /// - Parameter mergeRequest: the MR
        /// - Returns: its project; ``ProjectID/main`` while no project is listed, `nil` for one not set up
        func project(of mergeRequest: MergeRequest) -> ProjectID? {
            guard !projects.isEmpty else {
                return .main
            }
            let path = mergeRequest.reference.split(separator: "!").dropLast().joined(separator: "!").lowercased()
            return projects.first { $0.value.gitLabProject.lowercased() == path }?.key
        }

        /// Returns a build's row, with its project's job and name and its rebuild.
        ///
        /// - Parameters:
        ///   - build: the build
        ///   - now: the time the row counts from
        ///   - jobURL: the team's job, for a build of a project not listed
        /// - Returns: the row
        func row(_ build: Build, now: Date, jobURL: URL?) -> BuildRowModel {
            let project = projects[build.project]
            var row = BuildRowModel(
                build: build, now: now, jobURL: project?.jobURL ?? jobURL, rebuild: rebuilds[build.jobKey],
                project: project?.name)
            row.notifications = JobNotifications(notifications, job: build.jobKey, group: .init(build))
            return row
        }

        /// the problem's row, with the project's name in front while there are several
        var problemItem: PanelModel.ProblemItem? {
            problem.map { problem in
                var item = PanelModel.problemItem(problem)
                if let problemProject {
                    item.text = "\(problemProject): \(item.text)"
                }
                return item
            }
        }

        public init(problem: Problem? = nil, hasLoaded: Bool = true, isChecking: Bool = false, lastCheckedAt: Date? = nil,
                    mine: [Build] = [], watched: [Build] = [], emptyState: PipelinesEmptyState? = nil, hiddenCount: Int = 0,
                    rebuilds: [String: JenkinsRebuild] = [:], myJobs: [String]? = nil, watchedJobs: [String] = []) {
            self.problem = problem
            self.hasLoaded = hasLoaded
            self.isChecking = isChecking
            self.lastCheckedAt = lastCheckedAt
            self.mine = mine
            self.watched = watched
            self.emptyState = emptyState
            self.hiddenCount = hiddenCount
            self.rebuilds = rebuilds
            self.myJobs = myJobs
            self.watchedJobs = watchedJobs
        }
    }

    /// My merge requests, from `MergeRequestsStore`.
    public struct MergeRequests: Sendable {
        /// `nil` before the first load
        public var list: MergeRequestList?
        public var problem: Problem?
        public var isLoading: Bool
        public var lastLoadAt: Date?

        public init(list: MergeRequestList? = nil, problem: Problem? = nil, isLoading: Bool = false, lastLoadAt: Date? = nil) {
            self.list = list
            self.problem = problem
            self.isLoading = isLoading
            self.lastLoadAt = lastLoadAt
        }
    }

    /// The work items, from `WorkItemsStore`, with what the rows need of the filters and the labels.
    public struct WorkItems: Sendable {
        /// `nil` before the first load
        public var lists: WorkItemLists?
        public var problem: Problem?
        public var isLoading: Bool
        public var lastLoadAt: Date?
        /// the related-MR marker of each work item, by reference (WI-05)
        public var markers: [String: RelatedMergeRequestMarker]
        /// the filter labels GitLab no longer has (WI-06)
        public var missingLabels: [String]
        public var filters: WorkItemFilters
        /// GitLab's label colors remembered from the work items and label searches, by title (WI-06), for the
        /// commitment's color in the summary row
        public var labelColors: [String: String]

        public init(lists: WorkItemLists? = nil, problem: Problem? = nil, isLoading: Bool = false, lastLoadAt: Date? = nil,
                    markers: [String: RelatedMergeRequestMarker] = [:], missingLabels: [String] = [],
                    filters: WorkItemFilters = WorkItemFilters(), labelColors: [String: String] = [:]) {
            self.lists = lists
            self.problem = problem
            self.isLoading = isLoading
            self.lastLoadAt = lastLoadAt
            self.markers = markers
            self.missingLabels = missingLabels
            self.filters = filters
            self.labelColors = labelColors
        }
    }
}

import Foundation
import Observation

/// The Pipelines stores of all projects, one per project in the order of Settings → Projects, and what the status
/// icon and the panel show of them together (plan Phase 13).
///
/// - The primary project's store is ``primary`` for the app's whole run: the primary project can't be removed.
/// - ``check(reason:)`` is what the `Scheduler` runs: the projects' rounds one after the other, so one check at a time
///   stays true (JERR-07). The GitLab user is asked once per check and handed on.
/// - ``syncProjects()`` follows Settings: a store for each added project, none for a removed one.
@Observable
@MainActor
public final class ProjectsPipelines {
    /// the primary project's store
    public let primary: PipelinesStore
    /// the other projects' stores, in the projects' order
    public private(set) var others: [PipelinesStore] = []
    /// each project's name, as the views and the alerts show it (PROJ-01)
    public private(set) var names: [ProjectID: String] = [:]

    /// the preferences of every store; a change applies at once (HIDE-02)
    public var preferences: Preferences {
        didSet { stores.forEach { $0.preferences = preferences } }
    }

    /// which builds may alert, for every store (ALERT-08)
    public var notifications = NotificationPolicy() {
        didSet { stores.forEach { $0.notifications = notifications } }
    }

    /// Asks for a check at once, as watching does (WATCH-01). ``AppModel`` sets it to the scheduler's Check now.
    @ObservationIgnored public var requestCheck: @MainActor () -> Void = {} {
        didSet { stores.forEach { $0.requestCheck = requestCheck } }
    }

    @ObservationIgnored private let services: PipelinesServices
    @ObservationIgnored private var isOffline = false

    /// Creates the stores of the stored projects, with what their caches hold. Nothing is asked yet.
    ///
    /// - Parameters:
    ///   - services: the transport, the tokens, the files and the logs
    ///   - preferences: the preferences at the start
    public init(services: PipelinesServices, preferences: Preferences) {
        self.services = services
        self.preferences = preferences
        primary = PipelinesStore(services: services, preferences: preferences)
        syncProjects()
    }

    /// every store, the primary one first
    public var stores: [PipelinesStore] { [primary] + others }

    /// whether there is more than one project, so the views and the alerts name them
    public var hasSeveral: Bool { !others.isEmpty }

    /// Returns a project's store.
    ///
    /// - Parameter project: the project
    /// - Returns: its store; `nil` for a project that isn't there (any more)
    public func store(for project: ProjectID) -> PipelinesStore? {
        stores.first { $0.projectID == project }
    }

    /// Follows the stored projects: keeps the stores of the projects still there, adds one for each new project and
    /// drops the removed ones'.
    public func syncProjects() {
        let projects = services.team.projects()
        var next: [PipelinesStore] = []
        for project in projects where project.id != primary.projectID {
            if let kept = others.first(where: { $0.projectID == project.id }) {
                next.append(kept)
            } else {
                let store = PipelinesStore(services: services, preferences: preferences, project: project.id)
                store.requestCheck = requestCheck
                store.notifications = notifications
                store.setOffline(isOffline)
                next.append(store)
            }
        }
        if next.map(\.projectID) != others.map(\.projectID) {
            others = next
        }
        let names = Project.names(of: projects.isEmpty ? [primary.project] : projects)
        if names != self.names {
            self.names = names
        }
        // The Activity log names the project only while there are several.
        for store in stores {
            store.logName = others.isEmpty ? nil : names[store.projectID]
        }
    }

    // MARK: - What the views show of all projects

    /// the problem to show: the primary project's first, then the others' in order (PIPE-05)
    public var problem: Problem? {
        stores.lazy.compactMap(\.problem).first
    }

    /// the project whose problem ``problem`` is; `nil` without one
    public var problemProject: ProjectID? {
        stores.first { $0.problem != nil }?.projectID
    }

    /// whether the status icon shows the problem marker: while any project has a Jenkins problem (PIPE-05)
    public var showsProblemMarker: Bool {
        stores.contains { $0.showsProblemMarker }
    }

    /// the status icon's counts, over every project's builds that show (PIPE-05)
    public var counts: BuildCounts {
        PipelineRules.counts(of: stores.flatMap { $0.myBuilds + $0.watchedBuilds })
    }

    /// whether a check runs now
    public var isChecking: Bool {
        stores.contains { $0.isChecking }
    }

    /// my builds that show, the primary project's first, each project's newest started first (PIPE-08)
    public var myBuilds: [Build] {
        stores.flatMap(\.myBuilds)
    }

    /// the watched builds that show, in the projects' order (WATCH-04)
    public var watchedBuilds: [Build] {
        stores.flatMap(\.watchedBuilds)
    }

    /// the builds hidden by hand that would show otherwise, in every project (HIDE-01)
    public var hiddenCount: Int {
        stores.reduce(0) { $0 + $1.hiddenCount }
    }

    /// the rebuilds started from the app, by the ``BuildID/jobKey`` of their job (PIPE-09)
    public var rebuilds: [String: JenkinsRebuild] {
        var rebuilds: [String: JenkinsRebuild] = [:]
        for store in stores {
            for (job, rebuild) in store.rebuilds {
                rebuilds[BuildID.jobKey(job, project: store.projectID)] = rebuild
            }
        }
        return rebuilds
    }

    /// the name of the project whose problem ``problem`` is, while there are several and the problem is the project's
    /// own; `nil` for a token, offline or with one project
    public var problemProjectName: String? {
        guard hasSeveral, let project = problemProject, let problem else {
            return nil
        }
        switch problem {
        case .offline, .noToken, .rejectedToken, .missingScope: return nil
        default: return names[project]
        }
    }

    /// the hat the butler wears: the party hat only while every project with builds is on a green streak (EGG-03)
    public var butlerHat: ButlerHat? {
        let hats = stores.filter { $0.hasLoaded && !$0.state.builds.isEmpty }.map(\.butlerHat)
        guard let hat = primary.butlerHat else {
            return nil
        }
        return hat == .party && hats.contains(nil) ? nil : hat
    }

    // MARK: - Intents

    /// Hides a build until its job has another build, in its project (HIDE-01).
    ///
    /// - Parameter id: the build
    public func hide(_ id: BuildID) {
        store(for: id.project)?.hide(id)
    }

    /// Hides a build until its job has another build, in its project (HIDE-01).
    ///
    /// - Parameter build: the build
    public func hide(_ build: Build) {
        hide(build.id)
    }

    /// Starts a build again, in its project (PIPE-09).
    ///
    /// - Parameter id: the build
    public func rebuild(_ id: BuildID) {
        store(for: id.project)?.rebuild(id)
    }

    /// Watches the job that a link or a number names, in the project the link points into, else in the chosen one
    /// (WATCH-01, plan Phase 13).
    ///
    /// - Parameters:
    ///   - text: what was pasted or typed
    ///   - chosen: the project the sheet has chosen; the primary one by default
    /// - Returns: what was watched, or why nothing was
    public func watch(_ text: String, in chosen: ProjectID? = nil) async -> Result<WatchOutcome, WatchRefusal> {
        let chosen = chosen.flatMap(store(for:)) ?? primary
        let project = WatchTarget.project(of: text, among: stores.map(\.project), chosen: chosen.projectID)
        return await (store(for: project) ?? chosen).watch(text)
    }

    /// Returns the store of the project a merge request belongs to, by the path of its reference, like
    /// `group/project!12`.
    ///
    /// - Parameter mergeRequest: the MR
    /// - Returns: the store; `nil` for an MR of a project that isn't set up
    public func store(forMergeRequest mergeRequest: MergeRequest) -> PipelinesStore? {
        let path = mergeRequest.reference.split(separator: "!").dropLast().joined(separator: "!").lowercased()
        return stores.first { $0.project.team.gitLabProject.lowercased() == path }
    }

    /// Shows every build hidden by hand again, in every project (HIDE-01).
    public func unhideAll() {
        stores.forEach { $0.unhideAll() }
    }

    /// Stops watching a job by hand, in its project (WATCH-05).
    ///
    /// - Parameter key: the job's ``BuildID/jobKey``
    public func unwatch(jobKey key: String) {
        let (project, job) = BuildID.split(jobKey: key)
        store(for: project)?.unwatch(job)
    }

    /// Removes a rebuild's new build from Jenkins's queue, in its project (PIPE-09).
    ///
    /// - Parameter key: the job's ``BuildID/jobKey``
    public func cancelRebuild(jobKey key: String) async {
        let (project, job) = BuildID.split(jobKey: key)
        await store(for: project)?.cancelRebuild(job: job)
    }

    /// Notes whether the Mac has a network path, for every project (OD-05).
    ///
    /// - Parameter offline: `true` without a network path
    public func setOffline(_ offline: Bool) {
        isOffline = offline
        stores.forEach { $0.setOffline(offline) }
    }

    /// Moves the time of the hiding rules on to now in every project (HIDE-02).
    public func refreshTime() {
        stores.forEach { $0.refreshTime() }
    }

    /// Reads the projects, their watched and hidden builds and their caches again, as after the import at launch.
    public func reload() {
        syncProjects()
        stores.forEach { $0.reload() }
    }

    // MARK: - The background check

    /// Runs one check of every project, one after the other, and announces each one's alerts. The `Scheduler` runs it,
    /// one at a time (JERR-07).
    ///
    /// - Parameter reason: why it runs; Check now looks my jobs up again (PIPE-07)
    /// - Returns: a failure only when no project's Jenkins could be reached, so one broken project never slows the
    ///   others' checks (OD-05)
    /// - Throws: `CancellationError` when the check was cancelled
    public func check(reason: CheckReason) async throws -> CheckOutcome {
        var outcome = try await primary.check(reason: reason)
        var gitLabUser = primary.knownGitLabUser
        for store in others {
            if try await store.check(reason: reason, gitLabUser: gitLabUser) == .success {
                outcome = .success
            }
            gitLabUser = store.knownGitLabUser ?? gitLabUser
        }
        return outcome
    }
}

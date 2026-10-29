import Foundation
import Observation

/// What Watch a Build… did with a job Jenkins confirmed (WATCH-01).
public enum WatchOutcome: Hashable, Sendable {
    /// the job is watched from now on; the title is Jenkins' `objectDisplayName`
    case watching(WatchedJob, title: String?)
    /// the job was watched already; nothing changed
    case alreadyWatching(WatchedJob)

    /// the watched job
    public var watched: WatchedJob {
        switch self {
        case .watching(let watched, _), .alreadyWatching(let watched): watched
        }
    }

    /// the sheet's text, like "Watching all builds of !2"
    public var message: String {
        switch self {
        case .watching(let watched, _): "Watching all builds of \(watched.label)"
        case .alreadyWatching(let watched): "Already watching all builds of \(watched.label)"
        }
    }

    /// the job's title under the message; `nil` when Jenkins gave none or the job was watched already
    public var title: String? {
        if case .watching(_, let title) = self { title } else { nil }
    }
}

/// My builds and the watched ones, as the panel, the main window and the status icon show them (Task 2.6).
///
/// - It keeps the Jenkins state of the last check, the watched jobs and the hidden builds, and the merged MRs, and
///   applies the hiding rules (HIDE-01 to HIDE-04) to what the views show.
/// - Its background check, ``check(reason:)``, is what the `Scheduler` runs: one ``PipelinesCheck`` round, whose
///   result it applies and whose alerts it announces.
/// - Its intents change the watched and hidden builds at once and store them.
@Observable
@MainActor
public final class PipelinesStore {
    /// the project whose builds this store keeps (plan Phase 13)
    public let projectID: ProjectID
    /// the project as Team had it at the last check
    public private(set) var project: Project
    /// the state of the last check: my jobs, the user they were looked up for, and the builds (PIPE-01)
    public private(set) var state: JenkinsState
    /// the watched jobs and the builds hidden by hand
    public private(set) var userState: UserState
    /// the iids of the merged MRs among the MR jobs (HIDE-03)
    public private(set) var merged: [Int]
    /// the problem of the last check (JERR, TEAM-03); `nil` when Jenkins answered
    public private(set) var checkProblem: Problem?
    /// whether the Mac has no network path (OD-05)
    public private(set) var isOffline = false
    /// whether a check runs now, for the spinner (OD-01)
    public private(set) var isChecking = false
    /// when the last check ended, for "Last checked HH:MM" (PIPE-07); `nil` before any
    public private(set) var lastCheckedAt: Date?
    /// whether there are builds to show, from the cache or a check; until then the sections show a loading row (OD-01)
    public private(set) var hasLoaded: Bool
    /// the time the hiding rules use, moved on at each check, each preference change and ``refreshTime()`` (HIDE-02)
    public private(set) var now: Date
    /// the preferences the hiding rules and the alerts follow; a change applies at once (HIDE-02)
    public var preferences: Preferences {
        didSet { now = services.now() }
    }

    /// the rebuilds started from the app, per job, until the new build shows or the rebuild failed (PIPE-09)
    public private(set) var rebuilds: [String: JenkinsRebuild] = [:]

    /// the project's name in the Activity log while there are several projects; `nil` with one (plan Phase 13)
    @ObservationIgnored public var logName: String?

    /// Asks for a check at once, as watching does (WATCH-01). ``AppModel`` sets it to the scheduler's Check now.
    @ObservationIgnored public var requestCheck: @MainActor () -> Void = {}

    @ObservationIgnored private let services: PipelinesServices
    @ObservationIgnored private let round: PipelinesCheck
    @ObservationIgnored private var alertStates: [String: AlertState]
    /// what the easter eggs remember, for the hat and the spellcheck demo count (EGG-03, EGG-07)
    public private(set) var eggMemory: EggMemory
    @ObservationIgnored private var gitLabUser: GitLabUser?
    /// whether a check since the launch was answered by Jenkins; the alerts stay quiet until then (ALERT-01)
    @ObservationIgnored private var alertsArmed = false
    /// the log entries in the order the intents made them
    @ObservationIgnored private var logging: Task<Void, Never>?
    /// the tasks that start the rebuilds and follow their queue items, per job (PIPE-09)
    @ObservationIgnored private var rebuildTasks: [String: Task<Void, Never>] = [:]
    /// the jobs whose queued rebuild is being cancelled, so that a second click sends nothing
    @ObservationIgnored private var cancellingRebuilds: Set<String> = []
    #if DEBUG
    /// the checks that ended, and the tests waiting for a number of them
    @ObservationIgnored private var checksEnded = 0
    @ObservationIgnored private var checkWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    #endif

    /// Creates the store with what the caches and the state file hold, so the views have something to show at once
    /// (OD-01). Nothing is asked yet.
    ///
    /// - Parameters:
    ///   - services: the transport, the tokens, the files and the logs
    ///   - preferences: the preferences at the start
    ///   - project: the project; the primary one by default
    public init(services: PipelinesServices, preferences: Preferences, project id: ProjectID? = nil) {
        self.services = services
        self.round = PipelinesCheck(services: services)
        self.preferences = preferences
        // A project removed meanwhile has empty values, so it checks nothing; it never falls back to another's.
        let project = id.map { services.team.project($0) ?? Project(id: $0, team: TeamValues()) }
            ?? services.team.primaryProject()
        projectID = project.id
        let cached = services.caches.load(.jenkins, for: projectID)
        self.project = project
        state = Self.stamped(cached?.value ?? JenkinsState(), projectID)
        checkProblem = cached?.problem
        hasLoaded = cached != nil
        lastCheckedAt = cached?.fetchedAt
        userState = services.userStates.load(project.id)
        merged = services.caches.load(.mergedMergeRequests, for: project.id)?.value ?? []
        alertStates = services.caches.load(.alertStates, for: project.id)?.value ?? [:]
        eggMemory = services.caches.load(.eggs, for: project.id)?.value ?? EggMemory()
        gitLabUser = services.caches.load(.gitLabUser, for: project.id)?.value
        now = services.now()
    }

    // MARK: - What the views show

    /// the problem to show: offline first, then the last check's (PIPE-05, OD-05)
    public var problem: Problem? {
        isOffline ? .offline : checkProblem
    }

    /// whether the status icon shows the problem marker: for a Jenkins problem, missing team values or offline; never
    /// for a GitLab problem (PIPE-05)
    public var showsProblemMarker: Bool {
        problem?.marksStatusIcon ?? false
    }

    /// my builds that show, newest started first (PIPE-08)
    public var myBuilds: [Build] {
        followed(.mine).filter { visibility(of: $0) == .shown }
    }

    /// the watched builds that show, newest started first, in the section after mine (WATCH-04)
    public var watchedBuilds: [Build] {
        followed(.watched).filter { visibility(of: $0) == .shown }
    }

    /// the builds hidden by hand that would show otherwise, for "Show N Hidden Builds" (HIDE-01, HIDE-04)
    public var hiddenCount: Int {
        (followed(.mine) + followed(.watched)).count { visibility(of: $0) == .hiddenByHand }
    }

    /// "Show 1 Hidden Build" or "Show N Hidden Builds"; `nil` when nothing is hidden by hand (HIDE-01)
    public var showHiddenTitle: String? {
        Self.showHiddenTitle(count: hiddenCount)
    }

    /// the counts of the status icon, of the builds that show (PIPE-05)
    public var counts: BuildCounts {
        PipelineRules.counts(of: myBuilds + watchedBuilds)
    }

    /// what the sections show without builds (PIPE-06)
    public var emptyState: PipelinesEmptyState? {
        PipelineRules.emptyState(state: state, mine: myBuilds, watched: watchedBuilds)
    }

    /// the watched jobs with their last builds, oldest watched first (WATCH-06)
    public var watchedJobs: [WatchedJobStatus] {
        let jobURL = project.team.jenkinsJob
        return userState.watched.map { watched in
            let build = state.builds.first { $0.job == watched.job }
            let url = jobURL.map { jobURL in
                build.map { AlertContent.buildURL(job: $0.job, number: $0.number, jobURL: jobURL) }
                    ?? PipelineRules.jobURL(job: watched.job, jobURL: jobURL)
            }
            return WatchedJobStatus(watched: watched, build: build, url: url)
        }
    }

    /// my GitLab username as GitLab last gave it, which the work items query also takes (PIPE-01); `nil` until GitLab
    /// has answered
    public var gitLabUsername: String? {
        gitLabUser?.username
    }

    /// the multibranch job, for "All Builds in Jenkins" (PIPE-08); `nil` without a job URL in Team
    public var allBuildsURL: URL? {
        project.team.jenkinsJob
    }

    /// Returns the links of a build's menu: its MR or branch, the build, the console and the test results (PIPE-03).
    ///
    /// - Parameter build: the build
    /// - Returns: the links; none without a Jenkins job URL in Team
    public func links(of build: Build) -> [BuildLink] {
        project.team.jenkinsJob.map { PipelineRules.links(of: build, jobURL: $0) } ?? []
    }

    /// Returns whether a build shows, and if not, why (HIDE-01 to HIDE-04).
    ///
    /// - Parameter build: one of the builds of ``state``
    /// - Returns: its visibility now
    public func visibility(of build: Build) -> BuildVisibility {
        PipelineRules.visibility(
            of: build, hidden: userState.hidden, merged: Set(merged), preferences: preferences, now: now)
    }

    /// Returns the title of the button that shows the hidden builds again (HIDE-01).
    ///
    /// - Parameter count: the builds hidden by hand that would show otherwise
    /// - Returns: "Show 1 Hidden Build", "Show N Hidden Builds", or `nil` for none
    nonisolated public static func showHiddenTitle(count: Int) -> String? {
        switch count {
        case ...0: nil
        case 1: "Show 1 Hidden Build"
        default: "Show \(count) Hidden Builds"
        }
    }

    // MARK: - Intents

    /// Hides a build until its job has another build (HIDE-01). Alerts go on.
    ///
    /// - Parameter build: the build
    public func hide(_ build: Build) {
        hide(build.id)
    }

    /// Hides a build until its job has another build (HIDE-01), for the alert window's and the banner's Hide, which
    /// know the build by its id. Alerts go on.
    ///
    /// - Parameter id: the build's job and number
    public func hide(_ id: BuildID) {
        guard userState.hidden[id.job] != id.number else {
            return
        }
        userState.hidden[id.job] = id.number
        saveUserState()
        log(.info, .app, "Hid \(id.label)")
    }

    /// Shows every build hidden by hand again (HIDE-01).
    public func unhideAll() {
        guard !userState.hidden.isEmpty else {
            return
        }
        userState.hidden = [:]
        saveUserState()
        log(.info, .app, "Showed the hidden builds again")
    }

    /// Watches the job that a link or a number names, once Jenkins confirms it, and starts a check (WATCH-01 to
    /// WATCH-03).
    ///
    /// A job watched already adds nothing and logs nothing. The confirmation runs to its end even when the caller
    /// stops waiting, as when the sheet closes: a success is applied.
    ///
    /// - Parameter text: what was pasted or typed
    /// - Returns: what was watched, or why nothing was
    public func watch(_ text: String) async -> Result<WatchOutcome, WatchRefusal> {
        let project = currentProject()
        let job: String
        switch WatchTarget.parse(text, project: project) {
        case .success(let parsed): job = parsed
        case .failure(let refusal): return .failure(refusal)
        }
        if let watched = userState.watched.first(where: { $0.job == job }) {
            return .success(.alreadyWatching(watched))
        }
        let services = services
        let myJobs = Set(state.myJobs ?? [])
        // A task of its own, so that the sheet closing doesn't cancel the confirmation.
        let confirmation = Task {
            let token = await services.token(.jenkins)
            let client = JenkinsClient.make(
                project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts)
            return try await WatchTarget.confirm(job, client: client, myJobs: myJobs)
        }
        let confirmed: WatchCandidate
        switch await confirmation.result {
        case .success(.success(let candidate)): confirmed = candidate
        case .success(.failure(let refusal)): return .failure(refusal)
        case .failure: return .failure(.problem(.unreachable(.jenkins)))
        }
        if let watched = userState.watched.first(where: { $0.job == confirmed.job }) {
            return .success(.alreadyWatching(watched))
        }
        let watched = WatchedJob(job: confirmed.job, label: confirmed.label, added: services.now())
        userState.watched.append(watched)
        saveUserState()
        log(.info, .jenkins, "Watching \(watched.label)", detail: confirmed.title)
        requestCheck()
        return .success(.watching(watched, title: confirmed.title))
    }

    /// Stops watching a job by hand (WATCH-05). A job that isn't watched changes nothing and logs nothing.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    public func unwatch(_ job: String) {
        guard let watched = userState.watched.first(where: { $0.job == job }) else {
            return
        }
        userState.watched.removeAll { $0.job == job }
        saveUserState()
        log(.info, .jenkins, "Stopped watching \(watched.label): stopped by hand")
    }

    // MARK: - Rebuild (PIPE-09)

    /// how long a rebuild waits before each look at its queue item: soon at first, since most items leave the queue
    /// after the quiet period, then every 15 s while the new build waits for an executor
    nonisolated public static let queueLookDelays: [Duration] = [
        .seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(15),
    ]

    /// Starts a build's job again with the build's parameters, and follows the queue item to the new build (PIPE-09).
    ///
    /// One click starts one rebuild: no confirmation, and nothing is retried by itself. While a rebuild of the job is
    /// under way, another click starts nothing. A failure shows as the rebuild's text until the job has another build
    /// or Rebuild is clicked again. A job that isn't followed yet is watched once its new build has a number, through
    /// Watch a Build…'s path (WATCH-01); a followed one gets a check at once.
    ///
    /// - Parameter build: the build to start again
    public func rebuild(_ build: BuildID) {
        if rebuilds[build.job]?.isUnderWay == true {
            return
        }
        rebuilds[build.job] = JenkinsRebuild(build: build, phase: .starting)
        log(.info, .jenkins, "Rebuilding \(build.label)", detail: state.builds.first { $0.id == build }?.title)
        let project = currentProject()
        let services = services
        rebuildTasks[build.job] = Task {
            let token = await services.token(.jenkins)
            let client: JenkinsClient
            switch JenkinsClient.make(
                project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts)
            {
            case .success(let made):
                client = made
            case .failure(let error):
                rebuildFailed(build, .problem(error.problem))
                return
            }
            let item: QueueItem
            do {
                item = try await client.rebuild(job: build.job, number: build.number)
            } catch let error as JenkinsRebuildError {
                rebuildFailed(build, error)
                return
            } catch {
                // Cancelled: nobody waits for the answer.
                return
            }
            rebuilds[build.job] = JenkinsRebuild(build: build, phase: .queued(item))
            await followQueue(item, of: build, client: client, project: project)
        }
    }

    /// Removes a rebuild's new build from Jenkins's queue while it waits there (PIPE-09). A new build that left the
    /// queue meanwhile goes on, and shows. A failure is logged, and the row keeps its Cancel.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    public func cancelRebuild(job: String) async {
        guard let rebuild = rebuilds[job], case .queued(let item) = rebuild.phase, !cancellingRebuilds.contains(job)
        else { return }
        cancellingRebuilds.insert(job)
        defer { cancellingRebuilds.remove(job) }
        let project = currentProject()
        let services = services
        let token = await services.token(.jenkins)
        do {
            let client = try JenkinsClient.make(
                project: project, token: token, transport: services.recorder(for: project), timeouts: services.timeouts
            ).mapError { JenkinsRebuildError.problem($0.problem) }.get()
            // Not removed: the build started meanwhile, and the next look at the queue item finds it.
            guard try await client.cancel(item), rebuilds[job]?.phase == .queued(item) else {
                return
            }
            rebuildTasks[job]?.cancel()
            rebuildTasks[job] = nil
            rebuilds[job] = nil
            log(.info, .jenkins, "Cancelled the rebuild of \(rebuild.build.label)")
        } catch let error as JenkinsRebuildError {
            log(
                .warning, .jenkins, "The rebuild of \(rebuild.build.label) wasn't cancelled: \(error.message)",
                outcome: .failed("CANCEL"))
        } catch {
            // Cancelled: nobody waits for the answer.
        }
    }

    #if DEBUG
    /// Waits until the rebuild of a job has ended: failed, cancelled, or followed to its new build. Debug builds only.
    ///
    /// - Parameter job: the job's name as in Jenkins URLs
    public func waitForRebuild(job: String) async {
        await rebuildTasks[job]?.value
    }
    #endif

    /// Looks at the queue item until the new build has its number, or the item was cancelled or forgotten. A look that
    /// fails is logged with its request, and the next one asks again.
    private func followQueue(_ item: QueueItem, of build: BuildID, client: JenkinsClient, project: Project) async {
        var looks = 0
        while true {
            let delays = Self.queueLookDelays
            do {
                try await services.clock.sleep(for: delays[min(looks, delays.count - 1)])
            } catch {
                return
            }
            looks += 1
            let queued: QueueItemState
            do {
                queued = try await client.state(of: item)
            } catch is CancellationError {
                return
            } catch {
                continue
            }
            // Cancelled by hand meanwhile.
            guard rebuilds[build.job]?.phase == .queued(item) else {
                return
            }
            switch queued {
            case .waiting:
                continue
            case .started(let number):
                await rebuildStarted(build, number: number, project: project)
            case .cancelled:
                rebuilds[build.job] = nil
                log(.info, .jenkins, "The rebuild of \(build.label) was cancelled in Jenkins")
            case .gone:
                // Jenkins forgot the item before a look saw it leave the queue; a check shows the new build, if any.
                rebuilds[build.job] = nil
                log(.info, .jenkins, "Lost the rebuild of \(build.label) in Jenkins's queue")
                requestCheck()
            }
            return
        }
    }

    /// Notes the new build's number, and gets the new build shown: a check for a followed job, watching for another.
    private func rebuildStarted(_ build: BuildID, number: Int, project: Project) async {
        rebuilds[build.job] = JenkinsRebuild(build: build, phase: .started(number: number))
        log(.info, .jenkins, "Rebuild of \(build.label) started as #\(number)", outcome: .running("RUNNING"))
        let followed = (state.myJobs ?? []).contains(build.job) || userState.watched.contains { $0.job == build.job }
        if followed {
            requestCheck()
        } else if let jobURL = project.team.jenkinsJob {
            // Watching starts a check once Jenkins confirmed the job (WATCH-01).
            _ = await watch(AlertContent.buildURL(job: build.job, number: number, jobURL: jobURL).absoluteString)
        }
    }

    private func rebuildFailed(_ build: BuildID, _ error: JenkinsRebuildError) {
        rebuilds[build.job] = JenkinsRebuild(build: build, phase: .failed(error.message))
        log(.warning, .jenkins, "Rebuild of \(build.label) failed: \(error.message)", outcome: .failed("REBUILD"))
    }

    /// the hat the butler wears now: the party hat during a green streak, the Santa hat from December 24 to 26, none with
    /// the eggs off (EGG-03, EGG-04)
    public var butlerHat: ButlerHat? {
        preferences.easterEggs ? EggRules.hat(memory: eggMemory, now: now) : nil
    }

    /// Counts one showing of the spellcheck demo note, and keeps the count (EGG-07).
    ///
    /// - Returns: which demo this is, from 1
    @discardableResult
    public func countSpellcheckDemo() -> Int {
        eggMemory.spellcheckDemos += 1
        try? services.caches.save(Cached(value: eggMemory, fetchedAt: services.now()), as: .eggs, for: project.id)
        return eggMemory.spellcheckDemos
    }

    /// Moves the time of the hiding rules on to now, as when the panel opens (HIDE-02).
    public func refreshTime() {
        now = services.now()
    }

    /// Reads the project, the watched and hidden builds and the caches again, as after the import at launch.
    public func reload() {
        let project = currentProject()
        self.project = project
        userState = services.userStates.load(project.id)
        if let cached = services.caches.load(.jenkins, for: project.id) {
            state = Self.stamped(cached.value, projectID)
            checkProblem = cached.problem
            lastCheckedAt = cached.fetchedAt
            hasLoaded = true
        }
        merged = services.caches.load(.mergedMergeRequests, for: project.id)?.value ?? merged
        alertStates = services.caches.load(.alertStates, for: project.id)?.value ?? alertStates
        eggMemory = services.caches.load(.eggs, for: project.id)?.value ?? eggMemory
        gitLabUser = services.caches.load(.gitLabUser, for: project.id)?.value ?? gitLabUser
        now = services.now()
    }

    /// Notes whether the Mac has a network path; while it has none, the offline problem shows (OD-05).
    ///
    /// - Parameter offline: `true` without a network path
    public func setOffline(_ offline: Bool) {
        if isOffline != offline {
            isOffline = offline
        }
    }

    // MARK: - The background check

    /// Runs one check of the background loop, applies what it found and announces its alerts. The `Scheduler` runs
    /// it, one at a time (JERR-07).
    ///
    /// - Parameter reason: why it runs; Check now looks my jobs up again (PIPE-07)
    /// - Returns: whether Jenkins could be reached, for the backoff (OD-05)
    /// - Throws: `CancellationError` when the check was cancelled; then nothing changes
    public func check(reason: CheckReason) async throws -> CheckOutcome {
        try await check(reason: reason, gitLabUser: nil)
    }

    /// Runs one check, with the GitLab user another project's round found this time, so it is asked once per check.
    ///
    /// - Parameters:
    ///   - reason: why it runs
    ///   - shared: the GitLab user the round before found; `nil` uses the one this store knows
    /// - Returns: whether Jenkins could be reached
    func check(reason: CheckReason, gitLabUser shared: GitLabUser?) async throws -> CheckOutcome {
        isChecking = true
        defer { isChecking = false }
        return try await ActivityLog.$project.withValue(logName) {
            try await runCheck(reason: reason, gitLabUser: shared)
        }
    }

    private func runCheck(reason: CheckReason, gitLabUser shared: GitLabUser?) async throws -> CheckOutcome {
        let input = PipelinesCheck.Input(
            userState: userState, state: state, alertStates: alertStates, merged: merged, gitLabUser: shared ?? gitLabUser,
            preferences: preferences, lookUpJobs: reason == .checkNow, alertsArmed: alertsArmed, eggs: eggMemory,
            project: projectID)
        let output = try await round.run(input)
        apply(output)
        await round.announce(output.alerts, preferences: preferences)
        #if DEBUG
        checksEnded += 1
        let ready = checkWaiters.filter { $0.count <= checksEnded }
        checkWaiters.removeAll { $0.count <= checksEnded }
        ready.forEach { $0.continuation.resume() }
        #endif
        return output.result.succeeded ? .success : .failure
    }

    /// Waits until the entries the intents logged so far are written.
    func waitForLog() async {
        await logging?.value
    }

    #if DEBUG
    /// Waits until at least `count` checks have ended since the start. Debug builds only.
    ///
    /// - Parameter count: the number of checks
    public func waitForChecks(_ count: Int) async {
        guard checksEnded < count else {
            return
        }
        await withCheckedContinuation { checkWaiters.append((count, $0)) }
    }
    #endif

    private func apply(_ output: PipelinesCheck.Output) {
        let result = output.result
        project = output.project
        state = result.state
        checkProblem = result.problem
        merged = output.merged
        alertStates = output.alertStates
        // A demo counted while the round ran stays counted.
        var eggs = output.eggs
        eggs.spellcheckDemos = max(eggs.spellcheckDemos, eggMemory.spellcheckDemos)
        eggMemory = eggs
        gitLabUser = output.gitLabUser
        hasLoaded = true
        now = services.now()
        lastCheckedAt = now
        if result.problem == nil {
            alertsArmed = true
        }

        var next = userState
        for job in result.droppedWatchedJobs {
            guard let watched = next.watched.first(where: { $0.job == job }) else {
                continue
            }
            next.watched.removeAll { $0.job == job }
            log(.info, .jenkins, "Stopped watching \(watched.label): Jenkins no longer has it")
        }
        // A build hidden by hand shows again with the next build of its job; a job that left the list takes its
        // entry along (HIDE-01). A job Jenkins didn't answer for keeps its build, so it stays hidden.
        let current = Set(state.builds.map(\.id))
        next.hidden = next.hidden.filter { current.contains(BuildID(job: $0.key, number: $0.value, project: projectID)) }
        if next != userState {
            userState = next
            saveUserState()
        }

        // A rebuild ends once a check shows its new build; a failure goes with the job's next build (PIPE-09).
        for (job, rebuild) in rebuilds {
            let shown = state.builds.first { $0.job == job }?.number
            switch rebuild.phase {
            case .started(let number) where shown.map({ $0 >= number }) ?? true:
                rebuilds[job] = nil
            case .failed where shown != rebuild.build.number:
                rebuilds[job] = nil
            default:
                break
            }
        }
    }

    /// the project as Team has it now; empty values for a project that was removed, which checks nothing (TEAM-03)
    private func currentProject() -> Project {
        services.team.project(projectID) ?? Project(id: projectID, team: TeamValues())
    }

    private static func stamped(_ state: JenkinsState, _ project: ProjectID) -> JenkinsState {
        var state = state
        state.builds = state.builds.map { $0.stamped(project) }
        return state
    }

    /// the GitLab user this store knows, for the next project's round (plan Phase 13)
    var knownGitLabUser: GitLabUser? { gitLabUser }

    private func saveUserState() {
        do {
            try services.userStates.save(userState, for: project.id)
        } catch {
            log(.error, .app, "The watched and hidden builds could not be saved", detail: error.localizedDescription)
        }
    }

    /// Returns the builds of the jobs followed as mine or as watched; a job no longer watched leaves at once
    /// (WATCH-05), though its build stays in the state until the next check.
    private func followed(_ kind: JobKind) -> [Build] {
        switch kind {
        case .mine:
            return state.builds.filter { $0.kind == .mine }
        case .watched:
            let watched = Set(userState.watched.map(\.job))
            return state.builds.filter { $0.kind == .watched && watched.contains($0.job) }
        }
    }

    private func log(
        _ level: ActivityEntry.Level,
        _ source: ActivityEntry.Source,
        _ message: String,
        detail: String? = nil,
        outcome: ActivityEntry.Outcome? = nil
    ) {
        let previous = logging
        let log = services.log
        let project = logName
        logging = Task {
            await previous?.value
            await ActivityLog.$project.withValue(project) {
                await log.log(level, source, message, detail: detail, outcome: outcome)
            }
        }
    }
}

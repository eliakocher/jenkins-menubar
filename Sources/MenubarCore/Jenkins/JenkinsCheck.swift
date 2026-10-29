import Foundation

/// One Jenkins check: my jobs, the last build of each followed job, its stages and test counts (PIPE-01 to PIPE-04,
/// JERR-01 to JERR-08).
///
/// It takes plain values in and gives plain values out: the store keeps the state between checks, and the alerts
/// compare the builds before and after. The requests follow each other, as in the old plugin, so the check can stop at
/// the first unreachable answer.
///
/// - My jobs are looked up when 10 minutes have passed since the last lookup, when *me* changes, and when asked.
///   Otherwise the last list is used.
/// - Each followed job is asked for its last build: mine, then the watched jobs that aren't mine.
/// - Stages are asked for a running build, and for a FAILURE or UNSTABLE build the check before didn't see finished.
/// - The test counts are asked once, when a build has just finished.
/// - A job that doesn't answer keeps its last build.
public struct JenkinsCheck: Sendable {
    /// how long a lookup of my jobs is used, 10 minutes (PIPE-01)
    public static let lookupInterval: TimeInterval = 600

    private let transport: any HTTPTransport
    private let timeouts: Timeouts
    private let log: ActivityLog?
    private let checkTimes: CheckTimes?
    private let problems: ProblemTracker?
    private let now: @Sendable () -> Date

    /// Creates the check.
    ///
    /// - Parameters:
    ///   - transport: the transport that sends the requests, usually a `RequestRecorder`
    ///   - timeouts: the time limits of the requests
    ///   - log: where the jobs found, the slow job list and the started builds are logged
    ///   - checkTimes: where the check's requests are recorded together as one check time (LOG-05)
    ///   - problems: where the check's problem is noted under the key `jenkins`, so it is logged once (LOG-01)
    ///   - now: the current time
    public init(
        transport: any HTTPTransport,
        timeouts: Timeouts = .standard,
        log: ActivityLog? = nil,
        checkTimes: CheckTimes? = nil,
        problems: ProblemTracker? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.timeouts = timeouts
        self.log = log
        self.checkTimes = checkTimes
        self.problems = problems
        self.now = now
    }

    /// Checks Jenkins once.
    ///
    /// - Parameters:
    ///   - project: the project, whose Jenkins job is asked
    ///   - userState: the watched jobs
    ///   - token: the stored Jenkins token; `nil` when there is none (JERR-01)
    ///   - gitLabUsername: *me* as GitLab knows me; `nil` until GitLab has answered, and then the Jenkins user of the
    ///     token stands in (PIPE-01)
    ///   - state: what the check before left
    ///   - lookUpJobs: whether to look my jobs up even when the last lookup is recent, as Check now does (PIPE-07)
    /// - Returns: what the check found
    /// - Throws: `CancellationError` when the task was cancelled; every other failure is in the result
    public func run(
        project: Project,
        userState: UserState,
        token: String?,
        gitLabUsername: String?,
        state: JenkinsState,
        lookUpJobs: Bool = false,
        problemKey: String = "jenkins"
    ) async throws -> JenkinsCheckResult {
        let check = {
            try await self.check(
                project: project, userState: userState, token: token, gitLabUsername: gitLabUsername, state: state,
                lookUpJobs: lookUpJobs)
        }
        let result = if let checkTimes { try await checkTimes.measure(.jenkins, check) } else { try await check() }
        await problems?.update(problemKey, to: result.problem, source: .jenkins)
        return result
    }

    private func check(
        project: Project,
        userState: UserState,
        token: String?,
        gitLabUsername: String?,
        state: JenkinsState,
        lookUpJobs: Bool
    ) async throws -> JenkinsCheckResult {
        let now = now()
        var result = JenkinsCheckResult(state: state, previousBuilds: state.builds, previousCheck: state.checkedAt)
        let client: JenkinsClient
        switch JenkinsClient.make(project: project, token: token, transport: transport, timeouts: timeouts) {
        case .success(let made):
            client = made
        case .failure(let error):
            result.problem = error.problem
            return result
        }
        let me = gitLabUsername.flatMap { $0.isEmpty ? nil : $0 } ?? token.flatMap(TokenStore.jenkinsUser(fromToken:)) ?? ""
        var next = state
        // The problem to show when no job answers; an unreachable Jenkins shows anyway.
        var problem: Problem?
        var unreachable = false

        if lookUpJobs || state.isLookupDue(for: me, at: now) {
            do {
                let mine = try await client.jobs().filter { $0.contributors.contains(me) }.map(\.job)
                next.me = me
                next.myJobs = mine
                next.jobsLookedUpAt = now
                await log?.log(.debug, .jenkins, "Found \(mine.count) MR job\(mine.count == 1 ? "" : "s") of \(me)", detail: mine.joined(separator: " "))
            } catch let error as JenkinsError {
                guard state.myJobs != nil else {
                    result.problem = error.problem == .slow ? .unreachable(.jenkins) : error.problem
                    return result
                }
                switch error.problem {
                case .slow:
                    // The next lookup waits the usual time, so a slow Jenkins doesn't hold up every check.
                    next.jobsLookedUpAt = now
                    problem = .unreachable(.jenkins)
                    await log?.log(.warning, .jenkins, Problem.slow.message, outcome: .warning("SLOW"))
                case .unreachable:
                    unreachable = true
                default:
                    problem = error.problem
                }
            }
        }

        let myJobs = next.myJobs ?? []
        let watched = userState.watched.map(\.job).filter { !myJobs.contains($0) }
        var builds: [Build] = []
        var gone: Set<String> = []
        var reached = false
        for (job, kind) in myJobs.map({ ($0, JobKind.mine) }) + watched.map({ ($0, JobKind.watched) }) {
            let old = state.builds.first { $0.job == job }
            if !unreachable {
                do {
                    let status = try await client.job(job)
                    reached = true
                    if let build = status.build(kind: kind) {
                        builds.append(
                            try await complete(build, old: old, previousCheck: state.checkedAt, client: client, unreachable: &unreachable))
                    }
                    continue
                } catch let error as JenkinsError {
                    switch error.problem {
                    case .gone:
                        // Jenkins drops the job of a merged or closed MR: nothing is left to show, nor to watch.
                        gone.insert(job)
                        if kind == .watched {
                            result.droppedWatchedJobs.append(job)
                        }
                        continue
                    case .unreachable:
                        unreachable = true
                    default:
                        problem = error.problem
                    }
                }
            }
            // The build stays as it was until Jenkins answers for its job again.
            if var old {
                old.kind = kind
                builds.append(old)
            }
        }

        next.myJobs = next.myJobs?.filter { !gone.contains($0) }
        next.builds = builds.sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.job < $1.job }
        if unreachable {
            problem = .unreachable(.jenkins)
        } else if reached {
            problem = nil
        }
        if problem == nil {
            next.checkedAt = now
        }
        result.state = next
        result.problem = problem
        return result
    }

    /// Adds what a last build needs beyond the job's answer: the newer build that replaced an aborted one, the stages
    /// and the test counts.
    private func complete(
        _ build: Build,
        old: Build?,
        previousCheck: Date?,
        client: JenkinsClient,
        unreachable: inout Bool
    ) async throws -> Build {
        var build = build
        // A build seen running and now aborted may have been replaced by a newer one, which is followed instead
        // (ALERT-06).
        if build.result == .aborted, let old, old.number == build.number, old.isRunning,
            let newer = try await ask(&unreachable, { try await client.job(build.job) })?.build(kind: build.kind),
            newer.number > build.number
        {
            build = newer
        }
        let job = build.job
        let number = build.number
        let same = old?.number == number ? old : nil
        let needsStages = build.isRunning || build.result == .failure || build.result == .unstable

        if let same, !same.isRunning, !build.isRunning, same.stages != nil || !needsStages {
            // The stages of a finished build don't change any more.
            build.stages = same.stages
        } else if needsStages {
            // Unknown this time: the last known ones keep a stage that failed before from getting a second banner.
            build.stages = try await ask(&unreachable, { try await client.stages(job: job, number: number) }) ?? same?.stages
        }

        if !build.isRunning {
            // Just finished, by the rule of the finish alert (ALERT-01): seen running by the check before, or started
            // after it while that check knew an earlier build of the job.
            let startedSince = previousCheck.map { build.startedAt > $0 } ?? false
            if let same, !same.isRunning {
                build.testCounts = same.testCounts
            } else if same?.isRunning == true || (old.map { $0.number < number } ?? false) && startedSince {
                build.testCounts = try await ask(&unreachable, { try await client.testCounts(job: job, number: number) }) ?? nil
            }
        }

        if build.isRunning, old?.number != number {
            await log?.log(.info, .jenkins, "\(build.id.label) started: \(build.title ?? build.label)", outcome: .running("RUNNING"))
        }
        return build
    }

    /// Sends a request unless Jenkins was unreachable before in this check.
    ///
    /// - Returns: the answer; `nil` when Jenkins wasn't asked or failed, which marks it unreachable when it didn't
    ///   answer
    private func ask<Answer>(_ unreachable: inout Bool, _ request: () async throws -> Answer) async throws -> Answer? {
        guard !unreachable else { return nil }
        do {
            return try await request()
        } catch let error as JenkinsError {
            if case .unreachable = error.problem {
                unreachable = true
            }
            return nil
        }
    }
}

/// What the Jenkins check keeps from one check to the next, in the project's `jenkins` cache file.
public struct JenkinsState: Codable, Hashable, Sendable {
    /// the user my jobs were looked up for: the GitLab username, or the Jenkins user until GitLab answered (PIPE-01,
    /// PIPE-06)
    public var me: String?
    /// my jobs from the last lookup, as in Jenkins URLs; `nil` before a lookup worked
    public var myJobs: [String]?
    /// when my jobs were looked up, or when a slow lookup was given up (JERR-06)
    public var jobsLookedUpAt: Date?
    /// the builds to show, mine and watched, newest started first (PIPE-08)
    public var builds: [Build]
    /// when Jenkins last answered a check without a problem, so when the builds were seen
    public var checkedAt: Date?

    public init(me: String? = nil, myJobs: [String]? = nil, jobsLookedUpAt: Date? = nil, builds: [Build] = [], checkedAt: Date? = nil) {
        self.me = me
        self.myJobs = myJobs
        self.jobsLookedUpAt = jobsLookedUpAt
        self.builds = builds
        self.checkedAt = checkedAt
    }

    /// Returns whether my jobs are looked up again (PIPE-01).
    ///
    /// - Parameters:
    ///   - me: the user the check looks the jobs up for
    ///   - now: the current time
    /// - Returns: `true` without a list, for another user, and once ``JenkinsCheck/lookupInterval`` has passed
    public func isLookupDue(for me: String, at now: Date) -> Bool {
        guard myJobs != nil, self.me == me, let jobsLookedUpAt else { return true }
        let age = now.timeIntervalSince(jobsLookedUpAt)
        return age >= JenkinsCheck.lookupInterval || age < 0
    }
}

extension CacheFile where Value == JenkinsState {
    /// what the Jenkins check keeps between checks: my jobs and the builds
    public static var jenkins: CacheFile { CacheFile("jenkins") }
}

/// What one Jenkins check found, for the store, the alerts and the scheduler.
public struct JenkinsCheckResult: Hashable, Sendable {
    /// the state to keep for the next check, with the builds to show
    public var state: JenkinsState
    /// the builds as the check before left them, which the alerts compare against (ALERT-01, ALERT-05, ALERT-06)
    public var previousBuilds: [Build]
    /// when the builds of ``previousBuilds`` were seen; `nil` before the first check that Jenkins answered
    ///
    /// It doesn't move on with a check that had a problem, so a build that started while Jenkins didn't answer still
    /// counts as started since. It comes from the cache and so survives a restart: the alerts' `lastCheck` is `nil` for
    /// the first check after the start instead (ALERT-01).
    public var previousCheck: Date?
    /// the problem to show and log (JERR); `nil` when Jenkins answered
    public var problem: Problem?
    /// the watched jobs Jenkins no longer has, which stop being watched (WATCH-05, JERR-04)
    public var droppedWatchedJobs: [String]

    public init(
        state: JenkinsState,
        previousBuilds: [Build],
        previousCheck: Date?,
        problem: Problem? = nil,
        droppedWatchedJobs: [String] = []
    ) {
        self.state = state
        self.previousBuilds = previousBuilds
        self.previousCheck = previousCheck
        self.problem = problem
        self.droppedWatchedJobs = droppedWatchedJobs
    }

    /// the builds to show, newest started first
    public var builds: [Build] { state.builds }

    /// whether Jenkins could be reached, the failure the scheduler backs off from (OD-05); a problem Jenkins answered
    /// with, like a rejected token, or a missing token counts as success
    public var succeeded: Bool { problem != .unreachable(.jenkins) }
}

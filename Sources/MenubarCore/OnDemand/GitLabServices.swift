import Foundation

/// What the merge request and work item stores reach: the transport, the time, the GitLab token, the team values, the
/// caches and the logs. `AppModel` builds it once from the `Dependencies`.
///
/// The token and the team values are read at each load, so a change in Settings applies at the next one.
public struct GitLabServices: Sendable {
    /// the transport of the requests; each load wraps it in a `RequestRecorder`
    public var transport: any HTTPTransport
    /// the clock that times the requests and the label search's pause
    public var clock: any Clock<Duration>
    public var timeouts: Timeouts
    /// the current time, for the dates the caches keep and the age of the data
    public var now: @Sendable () -> Date
    public var tokens: TokenStore
    public var team: TeamStore
    public var caches: CacheStore
    public var log: ActivityLog
    /// where each request is kept with its answer; `nil` keeps none
    public var capture: RequestCapture?
    /// where each load's requests are recorded together (LOG-05)
    public var checkTimes: CheckTimes?
    /// where the problems are noted, so each is logged once (LOG-01)
    public var problems: ProblemTracker?
    /// my GitLab username as the background check knows it (PIPE-01, OD-04); `nil` makes a work items load ask GitLab
    public var gitLabUsername: @Sendable () async -> String?

    public init(
        transport: any HTTPTransport,
        clock: any Clock<Duration>,
        timeouts: Timeouts = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        tokens: TokenStore,
        team: TeamStore,
        caches: CacheStore,
        log: ActivityLog,
        capture: RequestCapture? = nil,
        checkTimes: CheckTimes? = nil,
        problems: ProblemTracker? = nil,
        gitLabUsername: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.transport = transport
        self.clock = clock
        self.timeouts = timeouts
        self.now = now
        self.tokens = tokens
        self.team = team
        self.caches = caches
        self.log = log
        self.capture = capture
        self.checkTimes = checkTimes
        self.problems = problems
        self.gitLabUsername = gitLabUsername
    }

    /// Returns the problems the GitLab caches still hold from the last run, for `ProblemTracker(log:current:)`, so they
    /// aren't logged again as new.
    ///
    /// - Parameters:
    ///   - caches: the cache store
    ///   - project: the project
    /// - Returns: the problems under ``MergeRequestsStore/problemKey`` and ``WorkItemsStore/problemKey``
    public static func cachedProblems(in caches: CacheStore, for project: ProjectID) -> [String: (Problem, ActivityEntry.Source)] {
        var problems: [String: (Problem, ActivityEntry.Source)] = [:]
        if let problem = caches.load(.mergeRequestList, for: project)?.problem, !isSetupStep(problem) {
            problems[MergeRequestsStore.problemKey] = (problem, .gitlab)
        }
        if let problem = caches.load(.workItems, for: project)?.problem, !isSetupStep(problem) {
            problems[WorkItemsStore.problemKey] = (problem, .gitlab)
        }
        return problems
    }

    /// Opens a session for one load: the current project, and a client with the GitLab token behind a recorder.
    ///
    /// - Returns: the session; or ``Problem/teamValuesMissing`` without the GitLab URL or project (TEAM-03), or
    ///   ``Problem/noToken(_:)`` without a GitLab token, and then nothing is asked (MR-04)
    func session() async -> Result<GitLabSession, GitLabError> {
        let project = team.primaryProject()
        let path = project.team.gitLabProject.trimmingCharacters(in: .whitespaces)
        guard let gitLab = project.team.gitLab, !path.isEmpty else {
            return .failure(GitLabError(.teamValuesMissing))
        }
        // A keychain that fails counts as no token, as for Jenkins (JERR-01).
        guard let token = try? await tokens.token(.gitlab), !token.isEmpty else {
            return .failure(GitLabError(.noToken(.gitLab)))
        }
        let recorder = RequestRecorder(wrapping: transport, log: log, capture: capture, clock: clock)
        return .success(GitLabSession(project: project, path: path,
                                      client: GitLabClient(transport: recorder, gitLab: gitLab, token: token, timeouts: timeouts)))
    }

    /// Runs one load's requests as one check time (LOG-05), on the caller's actor.
    nonisolated(nonsending) func measure<Value>(_ operation: nonisolated(nonsending) () async throws -> Value) async throws -> Value {
        guard let checkTimes else {
            return try await operation()
        }
        return try await checkTimes.measure(.gitlab, operation)
    }

    /// Notes a load's problem, so it is logged once when it starts and once when resolved (LOG-01).
    ///
    /// Missing team values and a missing token aren't failures of the load but setup steps that the section shows
    /// (TEAM-03, MR-04): the Jenkins check already logs the team values, and the old tool logged no missing GitLab
    /// token. They leave the tracker as it was.
    func track(_ key: String, _ problem: Problem?) async {
        if let problem, Self.isSetupStep(problem) {
            return
        }
        await problems?.update(key, to: problem, source: .gitlab)
    }

    /// whether a problem is a setup step that the section shows rather than a failure to log
    static func isSetupStep(_ problem: Problem) -> Bool {
        problem == .teamValuesMissing || problem == .noToken(.gitLab)
    }

    /// The age of data loaded or tried at a time.
    func age(since date: Date?) -> Duration? {
        date.map { .seconds(max(0, now().timeIntervalSince($0))) }
    }
}

/// What one load works with: the project of the moment and a client that carries the GitLab token.
struct GitLabSession: Sendable {
    var project: Project
    /// the project's full path, like `group/project`
    var path: String
    var client: GitLabClient
}

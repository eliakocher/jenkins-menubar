import CryptoKit
import Foundation

/// What the Pipelines store and its background check reach: the transport, the time, the tokens, the files and the
/// logs. ``AppModel`` builds it once from the ``Dependencies``.
public struct PipelinesServices: Sendable {
    /// the transport of the requests; each check wraps it in a `RequestRecorder`
    public var transport: any HTTPTransport
    /// the clock that times the requests
    public var clock: any Clock<Duration>
    public var timeouts: Timeouts
    public var now: @Sendable () -> Date
    public var tokens: TokenStore
    /// where the team values are read at each check, so a change in Settings → Team applies at the next one
    public var team: TeamStore
    public var userStates: UserStateStore
    public var caches: CacheStore
    public var log: ActivityLog
    /// where each request is kept with its answer; `nil` keeps none
    public var capture: RequestCapture?
    /// where each check's requests are recorded together (LOG-05)
    public var checkTimes: CheckTimes?
    /// where the Jenkins problem is noted, so it is logged once (LOG-01)
    public var problems: ProblemTracker?
    /// the alert window, banners and sounds
    public var effects: any Effects

    public init(
        transport: any HTTPTransport,
        clock: any Clock<Duration>,
        timeouts: Timeouts = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        tokens: TokenStore,
        team: TeamStore,
        userStates: UserStateStore,
        caches: CacheStore,
        log: ActivityLog,
        capture: RequestCapture? = nil,
        checkTimes: CheckTimes? = nil,
        problems: ProblemTracker? = nil,
        effects: any Effects
    ) {
        self.transport = transport
        self.clock = clock
        self.timeouts = timeouts
        self.now = now
        self.tokens = tokens
        self.team = team
        self.userStates = userStates
        self.caches = caches
        self.log = log
        self.capture = capture
        self.checkTimes = checkTimes
        self.problems = problems
        self.effects = effects
    }

    /// Returns the transport for a project's requests: the recorder that logs and keeps them, with the Jenkins paths
    /// relative to the project's job URL.
    ///
    /// - Parameter project: the project
    /// - Returns: the recorder
    public func recorder(for project: Project) -> RequestRecorder {
        RequestRecorder(wrapping: transport, log: log, capture: capture, clock: clock, pathsRelativeTo: project.team.jenkinsJob)
    }

    /// Reads a token. A keychain that fails counts as no token, which the check reports (JERR-01).
    ///
    /// - Parameter account: the token's account
    /// - Returns: the token; `nil` when there is none or the keychain failed
    func token(_ account: TokenAccount) async -> String? {
        guard let token = try? await tokens.token(account), !token.isEmpty else {
            return nil
        }
        return token
    }
}

/// My GitLab username and the token it was asked with, kept until the token changes (OD-04, PIPE-01).
///
/// Only a fingerprint of the token is kept: the first 16 hex digits of its SHA-256, enough to notice a new token and
/// useless for anything else.
public struct GitLabUser: Codable, Hashable, Sendable {
    public var username: String
    /// the start of the token's SHA-256, in hex
    public var tokenFingerprint: String

    public init(username: String, tokenFingerprint: String) {
        self.username = username
        self.tokenFingerprint = tokenFingerprint
    }

    /// Returns the fingerprint of a token.
    ///
    /// - Parameter token: the GitLab token
    /// - Returns: the first 16 hex digits of its SHA-256
    public static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns whether the username was asked with this token.
    ///
    /// - Parameter token: the stored GitLab token
    /// - Returns: `true` when the fingerprints match
    public func belongs(to token: String) -> Bool {
        tokenFingerprint == Self.fingerprint(of: token)
    }
}

extension CacheFile where Value == GitLabUser {
    /// my GitLab username, with the fingerprint of the token it was asked with (OD-04)
    public static var gitLabUser: CacheFile { CacheFile("gitlab-user") }
}

/// One round of the background loop: the Jenkins check, and the only GitLab requests that run in the background
/// (OD-04, Task 3.5).
///
/// - `CurrentUser` is asked when no username is known for the stored GitLab token, next to the Jenkins check. The
///   check uses the username known before, or the Jenkins user until GitLab has answered (PIPE-01).
/// - `MergedMergeRequests` is asked after the check for the iids of the MR jobs among its builds, and not at all
///   without any. When it fails, the last known list stays (HIDE-03).
/// - The alerts compare the builds with the alert states of the round before (ALERT-01 to ALERT-06).
///
/// It takes plain values in and gives plain values out, and writes the caches; the store keeps the state.
public struct PipelinesCheck: Sendable {
    /// What the store hands to a round.
    public struct Input: Sendable {
        public var userState: UserState
        public var state: JenkinsState
        /// the alert states after the round before
        public var alertStates: [String: AlertState]
        /// the merged MRs' iids known so far
        public var merged: [Int]
        public var gitLabUser: GitLabUser?
        public var preferences: Preferences
        /// which builds may alert (ALERT-08)
        public var notifications: NotificationPolicy
        /// whether to look my jobs up even when the last lookup is recent (PIPE-07)
        public var lookUpJobs: Bool
        /// whether a round since the launch was answered by Jenkins; until then, no alert fires (ALERT-01)
        public var alertsArmed: Bool
        /// what the easter eggs remember (EGG-11)
        public var eggs: EggMemory
        /// the project to check; `nil` for the primary one (plan Phase 13)
        public var project: ProjectID?

        public init(
            userState: UserState,
            state: JenkinsState,
            alertStates: [String: AlertState],
            merged: [Int],
            gitLabUser: GitLabUser?,
            preferences: Preferences,
            lookUpJobs: Bool,
            alertsArmed: Bool,
            eggs: EggMemory = EggMemory(),
            project: ProjectID? = nil,
            notifications: NotificationPolicy = NotificationPolicy()
        ) {
            self.notifications = notifications
            self.project = project
            self.userState = userState
            self.state = state
            self.alertStates = alertStates
            self.merged = merged
            self.gitLabUser = gitLabUser
            self.preferences = preferences
            self.lookUpJobs = lookUpJobs
            self.alertsArmed = alertsArmed
            self.eggs = eggs
        }
    }

    /// What a round found.
    public struct Output: Sendable {
        /// the project the round checked, as Team had it
        public var project: Project
        public var result: JenkinsCheckResult
        public var merged: [Int]
        public var alertStates: [String: AlertState]
        /// what the easter eggs remember after the round
        public var eggs: EggMemory
        public var gitLabUser: GitLabUser?
        /// the alerts to announce, in order
        public var alerts: [BuildAlert]
        /// when the round started
        public var startedAt: Date
    }

    public let services: PipelinesServices

    public init(services: PipelinesServices) {
        self.services = services
    }

    /// Runs one round and writes the caches.
    ///
    /// - Parameter input: what the store knows
    /// - Returns: what the round found
    /// - Throws: `CancellationError` when the task was cancelled; every other failure is in the output
    public func run(_ input: Input) async throws -> Output {
        let startedAt = services.now()
        let primary = services.team.primaryProject()
        // A project removed meanwhile has empty values, so the round asks nothing; it never checks another's job.
        let project = input.project.map { services.team.project($0) ?? Project(id: $0, team: TeamValues()) } ?? primary
        let recorder = services.recorder(for: project)
        let jenkinsToken = await services.token(.jenkins)
        let gitLabToken = await services.token(.gitlab)
        let known = gitLabToken.flatMap { token in input.gitLabUser.flatMap { $0.belongs(to: token) ? $0 : nil } }

        async let asked = askCurrentUser(project: project, token: gitLabToken, known: known, transport: recorder)
        let check = JenkinsCheck(
            transport: recorder, timeouts: services.timeouts, log: services.log, checkTimes: services.checkTimes,
            problems: services.problems, now: services.now)
        var result = try await check.run(
            project: project, userState: input.userState, token: jenkinsToken, gitLabUsername: known?.username,
            state: input.state, lookUpJobs: input.lookUpJobs, problemKey: Self.problemKey(of: project.id, primary: primary.id))
        result.state.builds = result.state.builds.map { $0.stamped(project.id) }
        let gitLabUser = await asked ?? known

        let merged = try await askMerged(
            project: project, token: gitLabToken, builds: result.builds, known: input.merged, transport: recorder)

        var alerts: [BuildAlert] = []
        if let jobURL = project.team.jenkinsJob {
            alerts = AlertPolicy(jobURL: jobURL).alerts(
                previous: input.alertStates, current: result.builds,
                lastCheck: input.alertsArmed ? result.previousCheck : nil, preferences: input.preferences)
            // A muted job stays followed, so its alert state moves on; only the glass alert and the banners go (ALERT-08).
            alerts = input.notifications.filter(alerts)
        }
        let alertStates = AlertPolicy.states(after: result.builds, previous: input.alertStates)
        // The easter eggs add a line to the finished builds' alerts, and keep their streaks (EGG-11).
        var eggs = input.eggs
        alerts = EggRules.annotate(alerts, memory: &eggs, now: startedAt, enabled: input.preferences.easterEggs)
        // With several projects, an alert names its project (plan Phase 13).
        let projects = services.team.projects()
        if projects.count > 1, let name = Project.names(of: projects)[project.id] {
            alerts = alerts.map { alert in
                var alert = alert
                alert.content.project = name
                return alert
            }
        }

        let caches = services.caches
        try? caches.save(Cached(value: result.state, fetchedAt: startedAt, problem: result.problem), as: .jenkins, for: project.id)
        try? caches.save(Cached(value: alertStates, fetchedAt: startedAt), as: .alertStates, for: project.id)
        try? caches.save(Cached(value: merged, fetchedAt: startedAt), as: .mergedMergeRequests, for: project.id)
        if eggs != input.eggs {
            try? caches.save(Cached(value: eggs, fetchedAt: startedAt), as: .eggs, for: project.id)
        }
        if let gitLabUser, gitLabUser != input.gitLabUser {
            try? caches.save(Cached(value: gitLabUser, fetchedAt: startedAt), as: .gitLabUser, for: project.id)
        }
        return Output(
            project: project, result: result, merged: merged, alertStates: alertStates, eggs: eggs, gitLabUser: gitLabUser,
            alerts: alerts, startedAt: startedAt)
    }

    /// Returns the key a project's Jenkins problem is tracked under: `jenkins` for the primary project, as before there
    /// were several, and `jenkins:<id>` for the others.
    ///
    /// - Parameters:
    ///   - project: the project
    ///   - primary: the primary project's id
    /// - Returns: the key
    public static func problemKey(of project: ProjectID, primary: ProjectID) -> String {
        project == primary ? "jenkins" : "jenkins:\(project)"
    }

    /// Announces a round's alerts as the preferences say.
    ///
    /// - Parameters:
    ///   - alerts: the alerts, from ``Output/alerts``
    ///   - preferences: the alert style and stage alerts
    public func announce(_ alerts: [BuildAlert], preferences: Preferences) async {
        guard !alerts.isEmpty else {
            return
        }
        await AlertAnnouncer(effects: services.effects, log: services.log).announce(alerts, preferences: preferences)
    }

    /// Asks GitLab for my username, unless it is known for this token.
    ///
    /// - Returns: the username asked now; `nil` when it wasn't asked, or GitLab didn't give it
    private func askCurrentUser(
        project: Project,
        token: String?,
        known: GitLabUser?,
        transport: any HTTPTransport
    ) async -> GitLabUser? {
        guard known == nil, let token, let gitLab = project.team.gitLab else {
            return nil
        }
        let client = GitLabClient(transport: transport, gitLab: gitLab, token: token, timeouts: services.timeouts)
        guard let username = try? await measure({ try await client.send(.currentUser) }) else {
            return nil
        }
        return GitLabUser(username: username, tokenFingerprint: GitLabUser.fingerprint(of: token))
    }

    /// Asks GitLab which of the MR jobs' MRs are merged (HIDE-03).
    ///
    /// - Returns: the merged iids: empty without MR jobs, the known ones when GitLab can't be asked or fails
    private func askMerged(
        project: Project,
        token: String?,
        builds: [Build],
        known: [Int],
        transport: any HTTPTransport
    ) async throws -> [Int] {
        let iids = Set(builds.compactMap(\.mergeRequestIID)).sorted()
        guard !iids.isEmpty else {
            return []
        }
        let path = project.team.gitLabProject.trimmingCharacters(in: .whitespaces)
        guard let token, let gitLab = project.team.gitLab, !path.isEmpty else {
            return known
        }
        let client = GitLabClient(transport: transport, gitLab: gitLab, token: token, timeouts: services.timeouts)
        do {
            return try await measure { try await client.send(.mergedMergeRequests(project: path, iids: iids)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return known
        }
    }

    /// Runs GitLab requests as one check time of their own, apart from the Jenkins check's.
    private func measure<Value>(_ operation: () async throws -> Value) async throws -> Value {
        guard let checkTimes = services.checkTimes else {
            return try await operation()
        }
        return try await checkTimes.measure(.gitlab, operation)
    }
}

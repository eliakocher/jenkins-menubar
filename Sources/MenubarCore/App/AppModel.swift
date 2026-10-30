import Foundation
import Observation

/// The app's composition root: it puts together the logs, the files, the feature stores and the `Scheduler` from one
/// ``Dependencies`` value, and starts and stops the background loop.
///
/// The app builds it once at launch and hands its stores to the views; the tests and the gallery build it from
/// `Dependencies.fake(…)`. Nothing is asked of Jenkins or GitLab before ``start()``.
@Observable
@MainActor
public final class AppModel {
    /// what the model was built from
    @ObservationIgnored public let dependencies: Dependencies
    /// the Activity log (LOG-01)
    @ObservationIgnored public let log: ActivityLog
    /// the check times of the Activity chart (LOG-05)
    @ObservationIgnored public let checkTimes: CheckTimes
    /// the captured requests (LOG-02)
    @ObservationIgnored public let requestCapture: RequestCapture
    /// the problems, each logged once when it starts and once when resolved (LOG-01)
    @ObservationIgnored public let problems: ProblemTracker
    /// the tokens in the keychain
    @ObservationIgnored public let tokens: TokenStore
    /// the team values of the projects
    @ObservationIgnored public let team: TeamStore
    /// the watched and hidden builds
    @ObservationIgnored public let userStates: UserStateStore
    /// the cached answers
    @ObservationIgnored public let caches: CacheStore
    /// the preferences in UserDefaults
    @ObservationIgnored public let preferencesStore: PreferencesStore
    /// open at login (APP-02)
    @ObservationIgnored public let launchAtLogin: LaunchAtLogin
    /// the background Jenkins loop, one check at a time (JERR-07, OD-05)
    @ObservationIgnored public let scheduler: Scheduler

    /// the primary project's builds, mine and the watched ones (Task 2.6)
    public let pipelines: PipelinesStore
    /// every project's Pipelines store, and the status icon's counts and problem over all of them (plan Phase 13)
    public let projects: ProjectsPipelines
    /// my merge requests, loaded while shown (MR-01, OD-02)
    public let mergeRequests: MergeRequestsStore
    /// the work items, loaded while shown (WI-01, OD-02, OD-03)
    public let workItems: WorkItemsStore
    /// the merge requests and work items opened outside the lists, under "Opened" in the main window (WIN-06)
    public let opened: OpenedItemsStore
    /// the window's "In GitLab" search for merge requests and work items beyond my lists (WIN-07)
    public let gitLabSearch: GitLabSearchStore
    /// every slot label GitLab has, loaded while the Slots section shows (SLOT-02)
    public let slotLabels: SlotLabelsStore
    /// every issue of the slot group in the shown slots, loaded while the Slots section shows (SLOT-06)
    public let slotItems: SlotItemsStore
    /// the descriptions of the selected merge requests and work items, loaded on selection (WIN-02)
    public let descriptions: DescriptionsStore
    /// the discussions of the selected work items, loaded on selection (WIN-02)
    public let itemDiscussions: ItemDiscussionsStore
    /// the approvals, unresolved threads and GitLab pipeline of the selected merge requests, loaded on selection (MR-06)
    public let mergeRequestDetails: MergeRequestDetailsStore
    /// the code changes of the selected merge requests, loaded on selection (MR-11)
    public let mergeRequestChanges: MergeRequestChangesStore
    /// GitLab's links from merge requests to work items, loaded when a merge request or one of its builds shows
    public let itemLinks: LinkedWorkItemsStore
    /// the failed tests of the selected finished builds, loaded on selection (PIPE-03)
    public let failedTests: FailedTestsStore
    /// the "likely flaky" hints of the selected failed builds, loaded on selection (PIPE-10)
    public let flakyHints: FlakyHintStore
    /// the preferences, the team values, the tokens and open at login, as Settings edits them (Task 6.1)
    public let settings: SettingsStore
    /// the Activity log, its requests and check times, as the Activity section shows them (Task 5.5)
    public let activity: ActivityStore
    /// the update and the rebuild (APP-05)
    public let updates: UpdateStore
    /// the global hotkey that opens the main window (APP-08)
    public let hotkey: GlobalHotkey
    /// the easter eggs that play out live: the Konami bow and the mashed Check Now (EGG-02, EGG-09)
    public let eggs: EggStage
    /// the local checkouts of Settings → Repositories, read with git while the Workspaces section shows (WS-01)
    public let workspaces: WorkspacesStore
    /// the Claude features: Why Did It Fail?, Summarize Discussion, the digest and Open in Claude Code (AI-01)
    public let ai: AIStore

    /// whether ``start()`` ran and ``stop()`` didn't since
    public private(set) var isStarted = false

    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    /// the calls to the scheduler, in the order they were made
    @ObservationIgnored private var schedulerCalls: Task<Void, Never>?
    /// the work item filters the last loads used, so that only a change of them reloads (WI-02)
    @ObservationIgnored private var workItemFilters: WorkItemFilters

    /// Builds the model. Reads the preferences, the team values, the watched and hidden builds and the caches, so the
    /// views can draw at once (OD-01); asks nothing yet.
    ///
    /// - Parameter dependencies: the real dependencies, or fakes
    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        let locations = dependencies.fileLocations
        let log = ActivityLog(folder: locations.logs, now: dependencies.now)
        self.log = log
        let report: @Sendable (String) -> Void = { message in
            Task { await log.log(.error, .app, message) }
        }
        checkTimes = CheckTimes(folder: locations.logs, log: log, now: dependencies.now)
        requestCapture = RequestCapture(
            folder: locations.logs.appending(path: "requests", directoryHint: .isDirectory), now: dependencies.now)
        tokens = TokenStore(keychain: dependencies.keychain, log: log)
        team = TeamStore(folder: locations.applicationSupport, report: report)
        userStates = UserStateStore(folder: locations.applicationSupport, report: report)
        caches = CacheStore(folder: locations.caches, report: report)
        preferencesStore = PreferencesStore(defaults: dependencies.preferences)
        launchAtLogin = LaunchAtLogin(item: dependencies.loginItem, log: log)

        let project = team.primaryProject()
        // The problems the last run left aren't new: they were logged when they started.
        var cachedProblems = GitLabServices.cachedProblems(in: caches, for: project.id)
        for other in [project] + team.projects().filter({ $0.id != project.id }) {
            if let problem = caches.load(.jenkins, for: other.id)?.problem {
                cachedProblems[PipelinesCheck.problemKey(of: other.id, primary: project.id)] = (problem, .jenkins)
            }
        }
        problems = ProblemTracker(log: log, current: cachedProblems)

        let preferences = preferencesStore.load()
        let services = PipelinesServices(
            transport: dependencies.transport, clock: dependencies.clock, timeouts: dependencies.timeouts,
            now: dependencies.now, tokens: tokens, team: team, userStates: userStates, caches: caches, log: log,
            capture: requestCapture, checkTimes: checkTimes, problems: problems, effects: dependencies.effects)
        let projects = ProjectsPipelines(services: services, preferences: preferences)
        projects.notifications = preferencesStore.notificationPolicy
        self.projects = projects
        let pipelines = projects.primary
        self.pipelines = pipelines
        failedTests = FailedTestsStore(services: services)
        flakyHints = FlakyHintStore(services: services)

        let gitLabServices = GitLabServices(
            transport: dependencies.transport, clock: dependencies.clock, timeouts: dependencies.timeouts,
            now: dependencies.now, tokens: tokens, team: team, caches: caches, log: log, capture: requestCapture,
            checkTimes: checkTimes, problems: problems,
            gitLabUsername: { @MainActor [weak pipelines] in pipelines?.gitLabUsername })
        let mergeRequests = MergeRequestsStore(services: gitLabServices)
        let workItems = WorkItemsStore(
            services: gitLabServices, preferences: { [weak pipelines] in pipelines?.preferences ?? Preferences() })
        self.mergeRequests = mergeRequests
        self.workItems = workItems
        opened = OpenedItemsStore(
            defaults: dependencies.preferences, services: gitLabServices, pipelines: services, now: dependencies.now)
        gitLabSearch = GitLabSearchStore(services: gitLabServices)
        slotLabels = SlotLabelsStore(services: gitLabServices)
        slotItems = SlotItemsStore(services: gitLabServices)
        descriptions = DescriptionsStore(services: gitLabServices)
        itemDiscussions = ItemDiscussionsStore(services: gitLabServices)
        mergeRequestDetails = MergeRequestDetailsStore(services: gitLabServices)
        mergeRequestChanges = MergeRequestChangesStore(services: gitLabServices)
        itemLinks = LinkedWorkItemsStore(services: gitLabServices)
        workItemFilters = preferences.workItems

        let scheduler = Scheduler(
            checkInterval: .seconds(preferences.checkIntervalSeconds),
            clock: dependencies.clock,
            systemEvents: dependencies.systemEvents,
            reachability: dependencies.reachability,
            powerMode: dependencies.powerMode,
            gitLabMaxAge: .seconds(preferences.gitLabMaxAgeSeconds),
            loads: [.mergeRequests: mergeRequests, .workItems: workItems],
            check: { [weak projects] reason in
                guard let projects else {
                    throw CancellationError()
                }
                return try await projects.check(reason: reason)
            })
        self.scheduler = scheduler

        settings = SettingsStore(
            preferences: preferencesStore, team: team, tokens: tokens, launchAtLogin: launchAtLogin, log: log,
            transport: { services.recorder(for: $0) }, timeouts: dependencies.timeouts, clock: dependencies.clock,
            checkNow: { await scheduler.checkNow() },
            setCheckInterval: { await scheduler.setCheckInterval($0) })
        activity = ActivityStore(
            log: log, requests: requestCapture, checkTimes: checkTimes, defaults: dependencies.preferences,
            clock: dependencies.clock, now: dependencies.now)
        updates = UpdateStore(stamp: dependencies.buildStamp, runner: dependencies.processRunner, log: log)
        hotkey = GlobalHotkey(registrar: dependencies.hotkeys)
        eggs = EggStage(now: dependencies.now, clock: dependencies.clock)
        hotkey.onFailure = { message in
            Task { await log.log(.warning, .app, message) }
        }
        workspaces = WorkspacesStore(
            defaults: dependencies.preferences, runner: dependencies.processRunner, log: log, clock: dependencies.clock,
            now: dependencies.now)
        ai = AIStore(
            defaults: dependencies.preferences, runner: dependencies.processRunner, log: log, clock: dependencies.clock,
            now: dependencies.now, jenkins: services, gitLab: gitLabServices)

        connectAI()
        projects.requestCheck = { [weak self] in
            self?.onScheduler { await $0.checkNow() }
        }
        settings.preferencesChanged = { [weak self] preferences in
            self?.apply(preferences)
        }
        settings.projectsChanged = { [weak self] removed in
            self?.projectsChanged(removed: removed)
        }
        workItems.onLoaded = { [weak self] in
            self?.checkSlotAlerts()
        }
        // Without the GitLab token, the GitLab stores forget their data and show the setup steps (MR-04).
        settings.onTokenRemoved = { [weak mergeRequests, weak workItems] account in
            guard account == .gitlab else {
                return
            }
            mergeRequests?.tokenRemoved()
            workItems?.tokenRemoved()
        }
    }

    /// Starts the background loop: the first check runs at once, then one each check interval (OD-05). Calling it
    /// again changes nothing.
    public func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        let launchAtLogin = launchAtLogin
        let applicationSupport = dependencies.fileLocations.applicationSupport
        Task { @MainActor in
            await launchAtLogin.refreshRegistrationIfMarked(in: applicationSupport)
        }
        let reachable = dependencies.reachability.updates()
        let projects = projects
        watchers = [
            Task { @MainActor in
                for await isReachable in reachable {
                    projects.setOffline(!isReachable)
                }
            }
        ]
        onScheduler { await $0.start() }
    }

    /// Stops the background loop and cancels the check under way. ``start()`` starts it again.
    public func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        watchers.forEach { $0.cancel() }
        watchers = []
        onScheduler { await $0.stop() }
    }

    /// Removes the global hotkey, as the app quits (APP-08).
    public func removeHotkey() {
        hotkey.stop()
    }

    /// Checks now, looking my jobs up again, offline too; during a check, one more runs right after it (PIPE-07).
    public func checkNow() {
        Task { [log] in await log.log(.info, .app, "Check now") }
        eggs.checkNowPressed(enabled: pipelines.preferences.easterEggs)
        onScheduler { await $0.checkNow() }
        // The checkouts too, while the Workspaces section shows them (WS-02).
        workspaces.refreshIfShown()
    }

    /// Checks the Jenkins builds only, looking my jobs up again, offline too; GitLab loads nothing. The main window's
    /// Reload in Pipelines.
    public func checkBuilds() {
        Task { [log] in await log.log(.info, .app, "Reload builds") }
        onScheduler { await $0.checkBuildsNow() }
    }

    /// Loads a GitLab list again at once, whatever the age of its data, while the window or panel shows it. The main
    /// window's Reload in Merge Requests and Work Items.
    ///
    /// - Parameter surface: the list
    public func reloadList(_ surface: Surface) {
        onScheduler { await $0.reload(surface) }
    }

    /// Takes in what the import at launch did (IMP-01): reads everything again, keeps the report for Settings →
    /// Accounts (ACC-02) and reads the tokens. Call it before ``start()``, so the first check has the imported values.
    ///
    /// - Parameter report: the report of the import that just ran, or the one recorded earlier; `nil` keeps the one
    ///   Settings has
    public func importFinished(_ report: LegacyImportReport?) async {
        if let report {
            settings.importReport = report
        }
        reload()
        await settings.loadTokens()
    }

    /// Reads the preferences, the team values, the watched and hidden builds and the caches again, as after the import
    /// at launch, and hands the preferences to the stores and the scheduler.
    public func reload() {
        settings.reload()
        projects.reload()
        let preferences = preferencesStore.load()
        projects.notifications = preferencesStore.notificationPolicy
        apply(preferences)
        onScheduler { await $0.setCheckInterval(.seconds(preferences.checkIntervalSeconds)) }
    }

    /// Switches the alerts of My Builds or Watching on or off (ALERT-09). The builds stay in the list, the counts and
    /// the pane; only the alert window and the banners stay quiet.
    ///
    /// - Parameters:
    ///   - group: the group
    ///   - isOn: whether its builds alert
    public func setNotifications(for group: NotificationPolicy.Group, isOn: Bool) {
        var policy = projects.notifications
        guard policy.isOn(group) != isOn else {
            return
        }
        policy.set(group, isOn: isOn)
        saveNotifications(policy, "Notifications for \(group == .mine ? "My Builds" : "Watching"): \(isOn ? "on" : "off")")
    }

    /// Sets the alerts of one job, for every build it gets from now on (ALERT-09).
    ///
    /// - Parameters:
    ///   - setting: always, never, or `nil` to follow the group again
    ///   - job: the job key, `BuildID.jobKey`
    public func setNotifications(_ setting: NotificationPolicy.JobSetting?, forJob job: String) {
        var policy = projects.notifications
        guard policy.jobs[job] != setting else {
            return
        }
        policy.set(setting, forJob: job)
        let label = Build.label(forJob: BuildID.split(jobKey: job).job)
        saveNotifications(policy, "Notifications for \(label): \(setting?.rawValue ?? "default")")
    }

    private func saveNotifications(_ policy: NotificationPolicy, _ message: String) {
        projects.notifications = policy
        preferencesStore.notificationPolicy = policy
        let log = log
        Task { await log.log(.info, .app, message) }
    }

    /// Hands changed preferences to what doesn't read them itself: the hiding rules and the alerts, the GitLab maximum
    /// age, the global hotkey (APP-08), and a reload of the work items when their filters changed (WI-02, OD-02).
    /// Settings reschedules the checks.
    private func apply(_ preferences: Preferences) {
        projects.preferences = preferences
        hotkey.apply(preferences.globalShortcut)
        let maxAge = Duration.seconds(preferences.gitLabMaxAgeSeconds)
        onScheduler { await $0.setGitLabMaxAge(maxAge) }
        if preferences.workItems != workItemFilters {
            workItemFilters = preferences.workItems
            onScheduler { await $0.reload(.workItems) }
        }
    }

    /// Follows a project added, changed or removed in Settings → Projects: a removed project's watched and hidden builds,
    /// caches and problem go, and an added one gets its store; Settings starts the check (PROJ-02).
    ///
    /// - Parameter removed: the project that was removed, if any
    public func projectsChanged(removed: ProjectID? = nil) {
        if let removed {
            try? userStates.remove(removed)
            try? caches.deleteAll(for: removed)
            let key = PipelinesCheck.problemKey(of: removed, primary: team.primaryProject().id)
            Task { [problems] in await problems.forget(key) }
        }
        projects.syncProjects()
    }

    /// Waits until the calls to the scheduler made so far have reached it.
    public func settled() async {
        await schedulerCalls?.value
    }

    /// Hands a call to the scheduler after the ones before it, so that a stop never overtakes a start.
    private func onScheduler(_ call: @escaping @Sendable (Scheduler) async -> Void) {
        let previous = schedulerCalls
        let scheduler = scheduler
        schedulerCalls = Task {
            await previous?.value
            await call(scheduler)
        }
    }
}

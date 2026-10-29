import Foundation

/// Why a check runs. The check takes it, so that Check now can look the jobs up again (PIPE-07).
public enum CheckReason: String, Hashable, Sendable, CaseIterable {
    /// the first check after ``Scheduler/start()``
    case start
    /// the interval has passed
    case scheduled
    /// the user asked for it (PIPE-07)
    case checkNow
    /// the Mac woke up (OD-05)
    case wake
    /// the network is back (OD-05)
    case networkBack
}

/// How a check went, for the backoff (OD-05).
public enum CheckOutcome: String, Hashable, Sendable, CaseIterable {
    /// Jenkins answered, even if with a problem such as a rejected token
    case success
    /// Jenkins couldn't be reached (JERR-05), so the next check waits longer
    case failure
}

/// Runs the background Jenkins check, one at a time (JERR-07), on the injected clock.
///
/// - The first check runs at ``start()``; then one runs each check interval after the previous one ended.
/// - ``checkNow()`` runs one at once. During a check it starts no second one: one more runs right after.
/// - While the Mac sleeps, no check runs and the one running is cancelled; one runs on wake.
/// - While the Mac is offline, no scheduled check runs; one runs when the network is back. Check now still runs.
/// - In Low Power Mode, the interval doubles.
/// - After a failed check, the next one waits 60 s, then 120 s, then 300 s, and never less than the interval. A
///   successful check resets it (OD-05).
///
/// It also runs the on-demand GitLab loads (OD-02), next to the Jenkins check and independent of it:
/// - A surface that ``setVisible(_:)`` shows loads at once when its data is older than the maximum age, otherwise when
///   it gets that old; then it loads again every maximum age while it stays shown. Nothing loads while nothing is shown.
/// - ``checkNow()`` and ``reload(_:)`` load the shown surfaces at once, and the others as soon as they are shown.
/// - Sleep, offline and ``stop()`` hold the loads as they hold the checks; a surface loads once more, when due, on wake
///   and when the network is back.
public actor Scheduler {
    /// One check. It runs outside the actor; a check that throws counts as a failure, one that is cancelled as nothing.
    public typealias Check = @Sendable (CheckReason) async throws -> CheckOutcome

    /// the waits after 1, 2, and 3 or more failed checks in a row
    public static let backoff: [Duration] = [.seconds(60), .seconds(120), .seconds(300)]

    /// What the scheduler knows about the Mac and the last checks.
    public struct Status: Hashable, Sendable {
        public var isStarted = false
        public var isChecking = false
        public var isAsleep = false
        public var isOffline = false
        public var isLowPowerMode = false
        /// the failed checks in a row
        public var failures = 0

        public init() {}
    }

    private let clock: any Clock<Duration>
    private let check: Check
    private let systemEvents: any SystemEvents
    private let reachability: any Reachability
    private let powerMode: any PowerMode
    private var interval: Duration
    public private(set) var status = Status()
    /// the reason of the check to run next, once nothing stops it; Check now wins over the others
    private var due: CheckReason?
    private var running: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    /// the GitLab load of each surface (OD-02)
    private let loads: [Surface: any OnDemandLoading]
    private var gitLabMaxAge: Duration
    /// the surfaces the panel and the window show now
    public private(set) var visibleSurfaces: Set<Surface> = []
    /// the surfaces to load at once, whatever the age of their data, as soon as they can: Check now and a filter change
    private var reloadDue: Set<Surface> = []
    /// the wait of each shown surface until its next load
    private var surfaceWaits: [Surface: Task<Void, Never>] = [:]
    /// the load under way of each surface
    private var surfaceLoads: [Surface: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - checkInterval: the time from the end of one check to the start of the next
    ///   - clock: the clock of the waits
    ///   - systemEvents: sleep and wake
    ///   - reachability: whether the network can be reached
    ///   - powerMode: whether Low Power Mode is on
    ///   - gitLabMaxAge: how old GitLab data may be when it is shown (OD-02)
    ///   - loads: the GitLab load of each surface, like the ``MergeRequestsStore``; without one, a surface loads nothing
    ///   - check: one Jenkins check
    public init(
        checkInterval: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        systemEvents: any SystemEvents,
        reachability: any Reachability = PathReachability(),
        powerMode: any PowerMode = SystemPowerMode(),
        gitLabMaxAge: Duration = .seconds(30),
        loads: [Surface: any OnDemandLoading] = [:],
        check: @escaping Check
    ) {
        self.interval = checkInterval
        self.clock = clock
        self.systemEvents = systemEvents
        self.reachability = reachability
        self.powerMode = powerMode
        self.gitLabMaxAge = gitLabMaxAge
        self.loads = loads
        self.check = check
    }

    /// Starts following the system conditions and runs the first check at once. Calling it again changes nothing.
    public func start() {
        guard !status.isStarted else {
            return
        }
        status.isStarted = true
        // The streams are made here, not in the tasks, so that nothing sent from now on is missed.
        let events = systemEvents.events()
        let reachable = reachability.updates()
        let lowPowerMode = powerMode.lowPowerModeUpdates()
        watchers = [
            Task {
                for await event in events {
                    handle(event)
                }
            },
            Task {
                for await isReachable in reachable {
                    setReachable(isReachable)
                }
            },
            Task {
                for await isOn in lowPowerMode {
                    setLowPowerMode(isOn)
                }
            },
        ]
        request(.start)
        refreshVisibleSurfaces()
    }

    /// Stops the checks and the GitLab loads, and cancels those running. ``start()`` starts them again.
    public func stop() {
        status.isStarted = false
        watchers.forEach { $0.cancel() }
        watchers = []
        timer?.cancel()
        timer = nil
        running?.cancel()
        due = nil
        holdSurfaces(cancellingLoads: true)
    }

    /// Runs a check at once, or right after the one running (PIPE-07, JERR-07). The shown GitLab surfaces load at once
    /// too, and the others as soon as they are shown (OD-02).
    public func checkNow() {
        request(.checkNow)
        for surface in Surface.allCases where loads[surface] != nil {
            reload(surface)
        }
    }

    /// Changes the check interval. A wait under way starts again with the new interval.
    ///
    /// - Parameter interval: the time from the end of one check to the start of the next
    public func setCheckInterval(_ interval: Duration) {
        self.interval = interval
        rescheduleWait()
    }

    /// the wait after the check that ended last: the interval (doubled in Low Power Mode), or the backoff when that is
    /// longer
    public var nextWait: Duration {
        let interval = status.isLowPowerMode ? self.interval * 2 : self.interval
        guard status.failures > 0 else {
            return interval
        }
        return max(interval, Self.backoff[min(status.failures, Self.backoff.count) - 1])
    }

    func handle(_ event: SystemEvent) {
        switch event {
        case .willSleep:
            status.isAsleep = true
            timer?.cancel()
            timer = nil
            // Its requests would only time out after the wake, and count as a failure.
            running?.cancel()
            holdSurfaces(cancellingLoads: true)
        case .didWake:
            status.isAsleep = false
            request(.wake)
            refreshVisibleSurfaces()
        }
    }

    func setReachable(_ isReachable: Bool) {
        guard isReachable == status.isOffline else {
            return
        }
        status.isOffline = !isReachable
        if isReachable {
            request(.networkBack)
            refreshVisibleSurfaces()
        } else {
            timer?.cancel()
            timer = nil
            holdSurfaces(cancellingLoads: false)
        }
    }

    func setLowPowerMode(_ isOn: Bool) {
        guard isOn != status.isLowPowerMode else {
            return
        }
        status.isLowPowerMode = isOn
        rescheduleWait()
    }

    /// Asks for a check, which starts when nothing stops it.
    private func request(_ reason: CheckReason) {
        if due != .checkNow {
            due = reason
        }
        startDueCheck()
    }

    private func startDueCheck() {
        guard status.isStarted, running == nil, !status.isAsleep, let reason = due,
            !status.isOffline || reason == .checkNow
        else { return }
        due = nil
        timer?.cancel()
        timer = nil
        status.isChecking = true
        let check = check
        running = Task {
            let outcome: CheckOutcome?
            do {
                outcome = try await check(reason)
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = .failure
            }
            ended(with: Task.isCancelled ? nil : outcome)
        }
    }

    /// Counts the outcome, then runs the check that is due, or waits for the next one.
    ///
    /// - Parameter outcome: how the check went; `nil` when it was cancelled
    private func ended(with outcome: CheckOutcome?) {
        running = nil
        status.isChecking = false
        switch outcome {
        case .success: status.failures = 0
        case .failure: status.failures += 1
        case nil: break
        }
        if due != nil {
            startDueCheck()
        }
        if running == nil {
            scheduleWait()
        }
    }

    /// Waits ``nextWait``, then asks for a check. Nothing waits while asleep or offline: wake and the network's return
    /// ask for the check then.
    private func scheduleWait() {
        timer?.cancel()
        timer = nil
        guard status.isStarted, running == nil, !status.isAsleep, !status.isOffline else {
            return
        }
        let wait = nextWait
        let clock = clock
        timer = Task {
            do {
                try await clock.sleep(for: wait)
            } catch {
                return
            }
            // A wait cancelled after its sleep ended still reaches here; the actor cancelled it, so it knows.
            guard !Task.isCancelled else {
                return
            }
            timer = nil
            request(.scheduled)
        }
    }

    private func rescheduleWait() {
        if timer != nil {
            scheduleWait()
        }
    }

    // MARK: - On-demand GitLab loads (OD-02, Task 3.4)

    /// Tells which surfaces the panel and the window show now; a collapsed section of the panel counts as shown
    /// (OD-02).
    ///
    /// A surface that appears loads at once when its data is older than the maximum age, otherwise when it gets that
    /// old; then it loads again every maximum age while it stays shown. A surface that disappears stops loading; a load
    /// under way still ends and keeps its answer.
    ///
    /// - Parameter surfaces: every surface shown now, in the panel or the window
    public func setVisible(_ surfaces: Set<Surface>) {
        let appeared = surfaces.subtracting(visibleSurfaces)
        let disappeared = visibleSurfaces.subtracting(surfaces)
        visibleSurfaces = surfaces
        for surface in Surface.allCases {
            if disappeared.contains(surface) {
                cancelWait(surface)
            } else if appeared.contains(surface) {
                refresh(surface)
            }
        }
    }

    /// Loads a surface at once, whatever the age of its data, when it is shown; otherwise as soon as it is shown. After
    /// a load under way, one more runs. A change of the work item filters asks for it (WI-02).
    ///
    /// - Parameter surface: the surface
    public func reload(_ surface: Surface) {
        guard loads[surface] != nil else {
            return
        }
        reloadDue.insert(surface)
        refresh(surface)
    }

    /// Changes how old GitLab data may be when it is shown (OD-02). The waits under way start again with it.
    ///
    /// - Parameter maxAge: the maximum age, one of `Preferences.gitLabMaxAgeOptions`
    public func setGitLabMaxAge(_ maxAge: Duration) {
        gitLabMaxAge = maxAge
        for surface in Surface.allCases where surfaceWaits[surface] != nil {
            refresh(surface)
        }
    }

    /// whether a surface may load now: started, awake, shown, and online unless a reload was asked for, as Check now
    /// runs offline too
    private func canLoad(_ surface: Surface) -> Bool {
        status.isStarted && !status.isAsleep && visibleSurfaces.contains(surface) && loads[surface] != nil
            && (!status.isOffline || reloadDue.contains(surface))
    }

    private func refreshVisibleSurfaces() {
        for surface in Surface.allCases where visibleSurfaces.contains(surface) {
            refresh(surface)
        }
    }

    /// Starts the load of a surface when it is due, or waits until its data gets older than the maximum age. During a
    /// load it does nothing: the load's end looks again.
    private func refresh(_ surface: Surface) {
        guard surfaceLoads[surface] == nil else {
            return
        }
        if reloadDue.contains(surface) {
            startLoad(surface)
        } else {
            scheduleLoad(surface, after: nil)
        }
    }

    /// Waits, then loads a surface.
    ///
    /// - Parameter wait: the wait; `nil` waits until the data gets older than the maximum age, which may be not at all
    private func scheduleLoad(_ surface: Surface, after wait: Duration?) {
        cancelWait(surface)
        guard canLoad(surface), let load = loads[surface] else {
            return
        }
        let clock = clock
        surfaceWaits[surface] = Task {
            var remaining = wait ?? .zero
            if wait == nil, let age = await load.dataAge() {
                remaining = gitLabMaxAge - age
            }
            if remaining > .zero {
                do {
                    try await clock.sleep(for: remaining)
                } catch {
                    return
                }
            }
            // A wait cancelled during its sleep or the age's answer still reaches here; the actor cancelled it, so it
            // knows.
            guard !Task.isCancelled else {
                return
            }
            surfaceWaits[surface] = nil
            startLoad(surface)
        }
    }

    private func startLoad(_ surface: Surface) {
        guard canLoad(surface), surfaceLoads[surface] == nil, let load = loads[surface] else {
            return
        }
        cancelWait(surface)
        reloadDue.remove(surface)
        surfaceLoads[surface] = Task {
            await load.load()
            loadEnded(surface, cancelled: Task.isCancelled)
        }
    }

    /// Waits a maximum age for the next load; after a cancelled load, or when a reload was asked for meanwhile, looks
    /// again at once.
    private func loadEnded(_ surface: Surface, cancelled: Bool) {
        surfaceLoads[surface] = nil
        if cancelled || reloadDue.contains(surface) {
            refresh(surface)
        } else {
            scheduleLoad(surface, after: gitLabMaxAge)
        }
    }

    private func cancelWait(_ surface: Surface) {
        surfaceWaits[surface]?.cancel()
        surfaceWaits[surface] = nil
    }

    /// Cancels the waits of all surfaces, and the loads under way when asked: sleep and stop cancel them, going
    /// offline lets them end.
    private func holdSurfaces(cancellingLoads: Bool) {
        for surface in Surface.allCases {
            cancelWait(surface)
            if cancellingLoads {
                // The load's end clears it, and looks again once the scheduler can load.
                surfaceLoads[surface]?.cancel()
            }
        }
    }
}

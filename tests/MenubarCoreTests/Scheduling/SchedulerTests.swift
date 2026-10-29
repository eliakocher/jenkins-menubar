import Foundation
import Testing

@testable import MenubarCore

@Suite("Scheduler")
struct SchedulerTests {
    /// Stands in for the Jenkins check: records each one, takes `duration` on the test clock when set, and returns the
    /// scripted outcomes in order, then `success`.
    private actor Checks {
        private let clock: TestClock
        private let duration: Duration?
        private var script: [Result<CheckOutcome, TestError>] = []
        private(set) var reasons: [CheckReason] = []
        private(set) var running = 0
        private(set) var mostAtOnce = 0
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        struct TestError: Error {}

        init(clock: TestClock, duration: Duration?) {
            self.clock = clock
            self.duration = duration
        }

        func then(_ outcomes: CheckOutcome...) {
            script += outcomes.map { .success($0) }
        }

        func thenThrow() {
            script.append(.failure(TestError()))
        }

        func run(_ reason: CheckReason) async throws -> CheckOutcome {
            reasons.append(reason)
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            defer { running -= 1 }
            let ready = waiters.filter { $0.count <= reasons.count }
            waiters.removeAll { $0.count <= reasons.count }
            ready.forEach { $0.continuation.resume() }
            if let duration {
                try await clock.sleep(for: duration)
            }
            return try script.isEmpty ? .success : script.removeFirst().get()
        }

        /// Suspends until at least `count` checks have started.
        func waitForChecks(_ count: Int) async {
            guard reasons.count < count else {
                return
            }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    /// A scheduler with the test clock, fake system conditions and ``Checks``.
    private struct Setup {
        let clock = TestClock()
        let events = FakeSystemEvents()
        let network: FakeReachability
        let power: FakePowerMode
        let checks: Checks
        let scheduler: Scheduler

        init(interval: Duration = .seconds(60), lowPowerMode: Bool = false, checkDuration: Duration? = nil) {
            network = FakeReachability()
            power = FakePowerMode(lowPowerMode: lowPowerMode)
            let checks = Checks(clock: clock, duration: checkDuration)
            self.checks = checks
            scheduler = Scheduler(
                checkInterval: interval, clock: clock, systemEvents: events, reachability: network, powerMode: power,
                check: { try await checks.run($0) })
        }

        var count: Int {
            get async { await checks.reasons.count }
        }

        /// Starts the scheduler and waits for the wait after its first check.
        func start() async {
            await scheduler.start()
            await checks.waitForChecks(1)
            await clock.waitForSleepers()
        }

        /// Expects that no check starts before `wait` has passed, and that one starts then.
        func expectCheck(after wait: Duration, sourceLocation: SourceLocation = #_sourceLocation) async {
            let before = await count
            await clock.waitForSleepers()
            clock.advance(by: wait - .seconds(1))
            #expect(clock.sleeperCount == 1, "the wait ended early", sourceLocation: sourceLocation)
            #expect(await count == before, sourceLocation: sourceLocation)
            clock.advance(by: .seconds(1))
            await checks.waitForChecks(before + 1)
        }

        /// Waits until the scheduler's status shows what the fakes sent it.
        func waitForStatus(_ condition: @Sendable (Scheduler.Status) -> Bool) async throws {
            for _ in 0..<2000 {
                if condition(await scheduler.status) {
                    return
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            Issue.record("the scheduler never got there: \(await scheduler.status)")
        }
    }

    // MARK: OD-05

    @Test("OD-05 pauses during sleep and checks on wake")
    func sleepAndWake() async throws {
        let setup = Setup()
        await setup.start()

        setup.events.send(.willSleep)
        try await setup.waitForStatus(\.isAsleep)
        #expect(setup.clock.sleeperCount == 0)
        setup.clock.advance(by: .seconds(3600))
        #expect(await setup.count == 1)

        setup.events.send(.didWake)
        await setup.checks.waitForChecks(2)
        #expect(await setup.checks.reasons == [.start, .wake])
        await setup.expectCheck(after: .seconds(60))
    }

    @Test("OD-05 waits while offline")
    func offline() async throws {
        let setup = Setup()
        await setup.start()

        setup.network.set(reachable: false)
        try await setup.waitForStatus(\.isOffline)
        #expect(setup.clock.sleeperCount == 0)
        setup.clock.advance(by: .seconds(3600))
        #expect(await setup.count == 1)

        setup.network.set(reachable: true)
        await setup.checks.waitForChecks(2)
        #expect(await setup.checks.reasons == [.start, .networkBack])
        await setup.expectCheck(after: .seconds(60))
    }

    @Test("OD-05 doubles the interval in Low Power Mode")
    func lowPowerMode() async throws {
        let setup = Setup(lowPowerMode: true)
        await setup.start()
        try await setup.waitForStatus(\.isLowPowerMode)
        await setup.expectCheck(after: .seconds(120))

        setup.power.set(lowPowerMode: false)
        try await setup.waitForStatus { !$0.isLowPowerMode }
        await setup.expectCheck(after: .seconds(60))
    }

    @Test("OD-05 backs off after failures and resets on success")
    func backoff() async throws {
        let setup = Setup(interval: .seconds(30))
        await setup.checks.then(.failure, .failure, .failure, .failure, .success)
        await setup.start()
        #expect(await setup.scheduler.status.failures == 1)

        await setup.expectCheck(after: .seconds(60))
        await setup.expectCheck(after: .seconds(120))
        await setup.expectCheck(after: .seconds(300))
        await setup.expectCheck(after: .seconds(300))
        // That fifth check succeeded.
        await setup.expectCheck(after: .seconds(30))
        #expect(await setup.scheduler.status.failures == 0)
    }

    @Test("OD-05 backoff is never shorter than the interval")
    func backoffNotShorterThanInterval() async throws {
        let setup = Setup(interval: .seconds(600))
        await setup.checks.then(.failure)
        await setup.start()
        await setup.expectCheck(after: .seconds(600))

        let longer = Setup(interval: .seconds(90))
        await longer.checks.then(.failure, .failure)
        await longer.start()
        #expect(await longer.scheduler.nextWait == .seconds(90))
        await longer.expectCheck(after: .seconds(90))
        await longer.clock.waitForSleepers()
        #expect(await longer.scheduler.nextWait == .seconds(120))
    }

    // MARK: JERR-07

    @Test("JERR-07 runs one check at a time")
    func oneAtATime() async throws {
        let setup = Setup(checkDuration: .seconds(30))
        await setup.scheduler.start()
        await setup.checks.waitForChecks(1)
        await setup.scheduler.checkNow()
        await setup.scheduler.checkNow()
        await setup.scheduler.setReachable(false)
        await setup.scheduler.setReachable(true)
        await setup.scheduler.handle(.didWake)
        #expect(await setup.count == 1)

        // Every ask during the check comes down to one more check after it.
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .seconds(30))
        await setup.checks.waitForChecks(2)
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .seconds(30))
        await setup.expectCheck(after: .seconds(60))
        #expect(await setup.count == 3)
        #expect(await setup.checks.mostAtOnce == 1)
    }

    @Test("JERR-07 check now during a check runs one more after it")
    func checkNowDuringCheck() async throws {
        let setup = Setup(checkDuration: .seconds(30))
        await setup.scheduler.start()
        await setup.checks.waitForChecks(1)
        await setup.scheduler.checkNow()
        #expect(await setup.count == 1)

        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .seconds(30))
        await setup.checks.waitForChecks(2)
        #expect(await setup.checks.reasons == [.start, .checkNow])
        #expect(await setup.scheduler.status.isChecking)
    }

    @Test("JERR-07 a cancelled check does not block the next")
    func cancelledCheck() async throws {
        let setup = Setup(checkDuration: .seconds(30))
        await setup.scheduler.start()
        await setup.checks.waitForChecks(1)

        // Sleep cancels the check under way; it counts as no failure.
        setup.events.send(.willSleep)
        try await setup.waitForStatus { $0.isAsleep && !$0.isChecking }
        #expect(await setup.scheduler.status.failures == 0)
        setup.events.send(.didWake)
        await setup.checks.waitForChecks(2)
        #expect(await setup.checks.reasons == [.start, .wake])

        // A check that throws counts as a failure, and the next one still runs.
        await setup.checks.thenThrow()
        await setup.clock.waitForSleepers()
        setup.clock.advance(by: .seconds(30))
        try await setup.waitForStatus { !$0.isChecking }
        #expect(await setup.scheduler.status.failures == 1)
        await setup.expectCheck(after: .seconds(60))
    }

    // MARK: PIPE-07

    @Test("PIPE-07 check now starts a check at once, offline too")
    func checkNow() async throws {
        let setup = Setup()
        await setup.start()
        await setup.scheduler.checkNow()
        await setup.checks.waitForChecks(2)
        #expect(await setup.checks.reasons == [.start, .checkNow])

        // The wait starts again from the end of that check.
        await setup.expectCheck(after: .seconds(60))

        setup.network.set(reachable: false)
        try await setup.waitForStatus(\.isOffline)
        await setup.scheduler.checkNow()
        await setup.checks.waitForChecks(4)
        #expect(await setup.checks.reasons.last == .checkNow)
    }

    // MARK: The system conditions

    @Test("PathReachability reports the current path at once")
    func pathReachability() async throws {
        var updates = PathReachability().updates().makeAsyncIterator()
        #expect(await updates.next() != nil)
    }

    @Test("SystemPowerMode reports the current mode at once")
    func systemPowerMode() async throws {
        var updates = SystemPowerMode().lowPowerModeUpdates().makeAsyncIterator()
        #expect(await updates.next() == ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    @Test("A new interval applies to the wait under way")
    func newInterval() async throws {
        let setup = Setup()
        await setup.start()
        await setup.scheduler.setCheckInterval(.seconds(300))
        await setup.expectCheck(after: .seconds(300))
    }
}

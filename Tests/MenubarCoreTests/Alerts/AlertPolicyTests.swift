import Foundation
import Testing

@testable import MenubarCore

@Suite("AlertPolicy")
struct AlertPolicyTests {
    private static let jobURL = URL(string: "https://jenkins.example.com/job/team/job/project")!
    private static let lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = AlertPolicy(jobURL: jobURL)

    /// A build of `MR-1`, started a minute before the last check unless said otherwise.
    private static func build(
        _ number: Int,
        job: String = "MR-1",
        _ phase: BuildPhase = .running,
        startedAt: Date = lastCheck.addingTimeInterval(-60),
        failedStages: [String]? = nil
    ) -> Build {
        Build(
            job: job, number: number, title: "Fix the login", gitLabURL: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/1"),
            kind: .mine, phase: phase, startedAt: startedAt,
            stages: failedStages.map { failed in
                [Stage(name: "checkout", status: .success, duration: 5)] + failed.map { Stage(name: $0, status: .failed, duration: 10) }
            })
    }

    private static func finished(_ result: BuildResult = .success) -> BuildPhase {
        .finished(result: result, duration: 1800)
    }

    /// One check: its alerts, and the states the next check compares against.
    private func check(
        _ current: [Build],
        after previous: [String: AlertState],
        lastCheck: Date? = Self.lastCheck
    ) -> (alerts: [BuildAlert], states: [String: AlertState]) {
        (
            policy.alerts(previous: previous, current: current, lastCheck: lastCheck),
            AlertPolicy.states(after: current, previous: previous)
        )
    }

    // MARK: ALERT-01

    @Test("ALERT-01 alerts when a build it saw running finishes")
    func seenRunningThenFinished() {
        let running = check([Self.build(7)], after: [:], lastCheck: nil)
        #expect(running.alerts.isEmpty)
        #expect(running.states["MR-1"] == AlertState(number: 7, isRunning: true))

        let alerts = check([Self.build(7, Self.finished())], after: running.states).alerts
        #expect(alerts.map(\.kind) == [.finished])
        #expect(alerts.first?.build.id == BuildID(job: "MR-1", number: 7))
    }

    @Test("ALERT-01 alerts for a build that started and finished between checks")
    func startedAndFinishedBetweenChecks() {
        let previous = ["MR-1": AlertState(number: 6, isRunning: false)]
        let quick = Self.build(7, Self.finished(.failure), startedAt: Self.lastCheck.addingTimeInterval(10))
        #expect(check([quick], after: previous).alerts.map(\.build.number) == [7])

        // One that started before the previous check comes from a state Jenkins didn't refresh then: old news.
        let old = Self.build(7, Self.finished(.failure), startedAt: Self.lastCheck.addingTimeInterval(-600))
        #expect(check([old], after: previous).alerts.isEmpty)
    }

    @Test("ALERT-01 does not alert for a build already finished when first seen")
    func alreadyFinishedWhenFirstSeen() {
        let known = ["MR-1": AlertState(number: 7, isRunning: true)]
        let newlyFound = Self.build(3, job: "MR-2", Self.finished(), startedAt: Self.lastCheck.addingTimeInterval(10))
        let first = check([Self.build(7), newlyFound], after: known)
        #expect(first.alerts.isEmpty)
        #expect(first.states["MR-2"] == AlertState(number: 3, isRunning: false))

        #expect(check([Self.build(7), newlyFound], after: first.states).alerts.isEmpty)
    }

    @Test("ALERT-01 does not alert on the first check after start")
    func firstCheckAfterStart() {
        // Even with the states of the last run restored, the first check of this run stays quiet.
        let restored = ["MR-1": AlertState(number: 7, isRunning: true, failedStages: [])]
        let first = check([Self.build(7, Self.finished()), Self.build(4, job: "MR-2", failedStages: ["build"])], after: restored, lastCheck: nil)
        #expect(first.alerts.isEmpty)
        #expect(first.states["MR-1"] == AlertState(number: 7, isRunning: false))
    }

    @Test("ALERT-01 alerts only once per build")
    func onlyOnce() {
        var states = ["MR-1": AlertState(number: 7, isRunning: true)]
        var alerted: [BuildAlert] = []
        for _ in 0..<3 {
            let next = check([Self.build(7, Self.finished())], after: states)
            alerted += next.alerts
            states = next.states
        }
        #expect(alerted.count == 1)
    }

    // MARK: Stages

    @Test("ALERT-05 a running build alerts nothing, whatever its stages do")
    func stagesAlertNothingWhileRunning() {
        let running = ["MR-1": AlertState(number: 7, isRunning: true)]
        let failing = check([Self.build(7, failedStages: ["build"])], after: running)
        #expect(failing.alerts.isEmpty)
        // The stages are still known, for the build's own alert at its end.
        #expect(failing.states["MR-1"]?.failedStages == ["build"])

        let more = check([Self.build(7, failedStages: ["build", "tests"])], after: failing.states)
        #expect(more.alerts.isEmpty)
        #expect(check([Self.build(8, failedStages: ["build"])], after: more.states).alerts.isEmpty)
    }

    @Test("ALERT-05 the alert at the end names the failed stages last known when the stages request fails")
    func finishedAlertKeepsKnownStages() throws {
        let running = check([Self.build(7, failedStages: ["tests"])], after: ["MR-1": AlertState(number: 7, isRunning: true)])
        let unknown = Self.build(7, Self.finished(.failure), failedStages: nil)

        let alert = try #require(check([unknown], after: running.states).alerts.first)

        #expect(alert.kind == .finished)
        #expect(alert.content.facts.contains("Failed stages: tests"))
        // A new build number starts with none known, not the old build's.
        #expect(AlertPolicy.states(after: [Self.build(8)], previous: running.states)["MR-1"]?.failedStages == [])
    }

    // MARK: ALERT-06

    @Test("ALERT-06 follows the newer build when the build was aborted")
    func followsNewerBuild() {
        // The check asked for the job's last build once more and found #8, which replaced the aborted #7.
        let replaced = check([Self.build(8, startedAt: Self.lastCheck.addingTimeInterval(20))], after: ["MR-1": AlertState(number: 7, isRunning: true)])
        #expect(replaced.alerts.isEmpty)
        #expect(replaced.states["MR-1"] == AlertState(number: 8, isRunning: true))

        let alerts = check([Self.build(8, Self.finished())], after: replaced.states).alerts
        #expect(alerts.map(\.build.number) == [8])
    }

    @Test("ALERT-06 alerts an aborted build without a newer one")
    func abortedWithoutNewer() {
        let alerts = check([Self.build(7, Self.finished(.aborted))], after: ["MR-1": AlertState(number: 7, isRunning: true)]).alerts
        #expect(alerts.map(\.build.number) == [7])
    }

    @Test("ALERT-06 no alert for a build replaced between checks")
    func replacedBetweenChecks() {
        let previous = ["MR-1": AlertState(number: 7, isRunning: true)]
        #expect(check([Self.build(8)], after: previous).alerts.isEmpty)

        // The newer build finished between the checks too: it alerts, the replaced one doesn't.
        let quick = Self.build(8, Self.finished(.failure), startedAt: Self.lastCheck.addingTimeInterval(5))
        #expect(check([quick], after: previous).alerts.map(\.build.id) == [BuildID(job: "MR-1", number: 8)])
    }
}

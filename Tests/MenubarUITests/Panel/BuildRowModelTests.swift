import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("BuildRowModel")
struct BuildRowModelTests {
    private static let now = Date(timeIntervalSince1970: 1_792_800_000)
    private static let jobURL = URL(string: "https://jenkins.example.com/job/project")!

    /// A running build of `MR-12`, started some minutes ago, with an estimate in minutes or none.
    private static func running(
        startedMinutesAgo: Double, estimateMinutes: Double?, stages: [Stage] = [], title: String? = "Fix the login"
    ) -> Build {
        Build(
            job: "MR-12", number: 7, title: title, kind: .mine, phase: .running,
            startedAt: now.addingTimeInterval(-startedMinutesAgo * 60), estimatedDuration: estimateMinutes.map { $0 * 60 },
            stages: stages)
    }

    /// A finished build of `MR-16` that took 12 minutes and finished some seconds ago.
    private static func finished(
        _ result: BuildResult, finishedAgo: TimeInterval, failedStages: [String] = [], tests: TestCounts? = nil
    ) -> Build {
        Build(
            job: "MR-16", number: 3, title: "Add a retry", kind: .mine, phase: .finished(result: result, duration: 12 * 60),
            startedAt: now.addingTimeInterval(-finishedAgo - 12 * 60),
            stages: failedStages.isEmpty ? nil : failedStages.map { Stage(name: $0, status: .failed, duration: 60) },
            testCounts: tests)
    }

    // MARK: PIPE-02

    @Test(
        "PIPE-02 ETA and progress of a running build",
        arguments: [
            // within the estimate: 5 of 25 minutes
            (5, 25, "0h05m elapsed · ~0h20m left", BuildRowModel.Progress.fraction(0.2)),
            // past it: the ETA stays at zero and the bar turns indeterminate
            (31, 28, "0h31m elapsed · ~0h00m left", .indeterminate),
            // without one: no ETA, an indeterminate bar
            (9, nil, "0h09m elapsed", .indeterminate),
        ] as [(Double, Double?, String, BuildRowModel.Progress)])
    func runningBuild(startedMinutesAgo: Double, estimate: Double?, timing: String, progress: BuildRowModel.Progress) {
        let row = BuildRowModel(
            build: Self.running(
                startedMinutesAgo: startedMinutesAgo, estimateMinutes: estimate),
            now: Self.now, jobURL: Self.jobURL)

        #expect(row.state == .running)
        #expect(row.timing == timing)
        // Running times never give way.
        #expect(row.timingWithoutAge == timing)
        // The list puts the elapsed time at the right end and keeps the ETA on line 2.
        #expect(row.trailingTime == String(timing.prefix(5)))
        #expect(row.timingBesideTime == (estimate == nil ? nil : String(timing.split(separator: " · ")[1])))
        #expect(row.failures == nil)
        if case .fraction(let expected) = progress, case .fraction(let actual)? = row.progress {
            #expect(abs(actual - expected) < 0.0001)
        } else {
            #expect(row.progress == progress)
        }
    }

    /// No stages running yet, and a job name for a missing title.
    @Test("PIPE-02 ETA and progress of a running build")
    func runningWithoutStagesOrTitle() {
        for title in [nil, "", "  "] as [String?] {
            let row = BuildRowModel(
                build: Self.running(startedMinutesAgo: 1, estimateMinutes: 10, title: title), now: Self.now, jobURL: Self.jobURL)
            #expect(row.title == "MR-12")
            #expect(row.status == nil)
        }
        // A branch job reads as its decoded name, which line 2 then doesn't repeat.
        let branch = Build(job: "feature%252Ffoo", number: 3, kind: .mine, phase: .running, startedAt: Self.now)
        #expect(BuildRowModel(build: branch, now: Self.now, jobURL: nil).title == "feature/foo")
        #expect(BuildRowModel(build: branch, now: Self.now, jobURL: nil).reference == "#3")
        let titled = Build(job: "feature%252Ffoo", number: 3, title: "Fix it", kind: .mine, phase: .running, startedAt: Self.now)
        #expect(BuildRowModel(build: titled, now: Self.now, jobURL: nil).reference == "feature/foo #3")
    }

    // MARK: PIPE-03

    @Test(
        "PIPE-03 finished build shows result, duration, age and failed stages",
        arguments: [
            (59.0, "0m"), (30 * 60, "30m"), (59 * 60 + 59, "59m"), (3600, "1h"), (5 * 3600, "5h"), (23 * 3600 + 3599, "23h"),
            (86400, "1d"), (3 * 86400, "3d"),
        ] as [(TimeInterval, String)])
    func finishedBuild(finishedAgo: TimeInterval, age: String) {
        let row = BuildRowModel(
            build: Self.finished(.failure, finishedAgo: finishedAgo, failedStages: ["tests", "deploy"],
                                 tests: TestCounts(failed: 3, total: 1200)),
            now: Self.now, jobURL: Self.jobURL)

        #expect(row.state == .failed)
        #expect(row.timing == "0h12m · finished \(age) ago")
        // What a row short of room keeps once "finished …" gives way (PIPELINES-01).
        #expect(row.timingWithoutAge == "0h12m")
        // The list puts the age at the right end and keeps the duration on line 2.
        #expect(row.trailingTime == "\(age) ago")
        #expect(row.timingBesideTime == "0h12m")
        #expect(row.failures == "failed: tests, deploy · Failed tests: 3 of 1200")
        #expect(row.progress == nil)
    }
}

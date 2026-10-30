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
                startedMinutesAgo: startedMinutesAgo, estimateMinutes: estimate,
                stages: [Stage(name: "build", status: .inProgress, duration: 0), Stage(name: "lint", status: .success, duration: 5),
                         Stage(name: "tests", status: .inProgress, duration: 0)]),
            now: Self.now, jobURL: Self.jobURL)

        #expect(row.state == .running)
        #expect(row.title == "Fix the login")
        #expect(row.reference == "!12 #7")
        #expect(row.status == "▶ build, tests")
        #expect(row.timing == timing)
        #expect(row.facts == "!12 #7 · ▶ build, tests · \(timing)")
        // Running times never give way.
        #expect(row.timingWithoutAge == timing)
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

    @Test("PIPE-02 formats durations as hours and minutes")
    func durations() {
        #expect(Formatting.duration(0) == "0h00m")
        #expect(Formatting.duration(59) == "0h00m")
        #expect(Formatting.duration(5 * 60) == "0h05m")
        #expect(Formatting.duration(65 * 60 + 59) == "1h05m")
        #expect(Formatting.duration(4 * 3600 + 12 * 60) == "4h12m")
        #expect(Formatting.duration(-30) == "0h00m")
        // No grouping, whatever the locale: hours above 999 stay plain digits.
        #expect(Formatting.duration(1234 * 3600) == "1234h00m")
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
        #expect(row.status == "FAILURE")
        #expect(row.timing == "0h12m · finished \(age) ago")
        // What a row short of room keeps once "finished …" gives way (PIPELINES-01).
        #expect(row.timingWithoutAge == "0h12m")
        #expect(row.facts == "!16 #3 · FAILURE · 0h12m · finished \(age) ago")
        #expect(row.failures == "failed: tests, deploy · Failed tests: 3 of 1200")
        #expect(row.progress == nil)
    }

    /// Each result has its symbol.
    @Test("PIPE-03 finished build shows result, duration, age and failed stages")
    func results() {
        let expected: [(BuildResult, BuildState, String)] = [
            (.success, .successful, "checkmark.circle"), (.unstable, .unstable, "exclamationmark.triangle"),
            (.failure, .failed, "xmark.circle.fill"), (.aborted, .aborted, "stop.circle"),
            (.notBuilt, .other("NOT_BUILT"), "questionmark.circle"),
        ]
        for (result, state, symbol) in expected {
            let row = BuildRowModel(build: Self.finished(result, finishedAgo: 60), now: Self.now, jobURL: Self.jobURL)
            #expect(row.state == state)
            #expect(row.state.symbol == symbol)
            #expect(row.status == result.rawValue)
            // Nothing failed and no test counts: no third line.
            #expect(row.failures == nil)
        }
        // A successful build lists no failed stages even when some are known, and no zero failed tests.
        let success = BuildRowModel(
            build: Self.finished(.success, finishedAgo: 60, tests: TestCounts(failed: 0, total: 1200)), now: Self.now, jobURL: Self.jobURL)
        #expect(success.failures == nil)
    }

    @Test("PIPE-03 the build row's context menu has the links, and a click opens the build")
    func contextMenuLinks() throws {
        let build = Build(
            job: "MR-12", number: 7, gitLabURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12"),
            kind: .watched, phase: .running, startedAt: Self.now)
        let row = BuildRowModel(build: build, now: Self.now, jobURL: Self.jobURL)
        #expect(row.links.map(\.title) == [
            "Show Merge Request !12", "Open Build #7 in Jenkins", "Console Output in Jenkins", "Test Results in Jenkins",
        ])
        let page = try #require(row.buildPage)
        #expect(page.url.absoluteString == "https://jenkins.example.com/job/project/job/MR-12/7/")
        // Without the job URL in Team, there is nothing to open in Jenkins.
        #expect(BuildRowModel(build: build, now: Self.now, jobURL: nil).links.isEmpty)
    }

    @Test("WATCH-04 watched build shows its author")
    func watchedAuthor() {
        let build = Build(
            job: "MR-2", number: 14, title: "Retry the upload", author: "Sam Lee", kind: .watched, phase: .running,
            startedAt: Self.now.addingTimeInterval(-60))
        let row = BuildRowModel(build: build, now: Self.now, jobURL: Self.jobURL)
        #expect(row.reference == "by Sam Lee · !2 #14")
        // My own builds don't name their author.
        var mine = build
        mine.kind = .mine
        #expect(BuildRowModel(build: mine, now: Self.now, jobURL: Self.jobURL).reference == "!2 #14")
    }

    @Test("PIPE-07 shows the time of the last check")
    func lastChecked() {
        let date = Date(timeIntervalSince1970: 1_792_800_000)
        let text = Formatting.lastChecked(
            date, locale: Locale(identifier: "de_CH"), timeZone: TimeZone(identifier: "Europe/Zurich")!)
        #expect(text.hasPrefix("Last checked "))
        #expect(text.wholeMatch(of: /Last checked \d{1,2}:\d{2}/) != nil)
    }
}

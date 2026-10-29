import Foundation
import Testing

@testable import MenubarCore

@Suite("PipelineRules")
struct PipelineRulesTests {
    private static let now = Date(timeIntervalSince1970: 1_792_800_000)

    /// A build that finished `finishedAgo` seconds before now, after 30 minutes, or a running one.
    private static func build(
        _ job: String = "MR-1",
        number: Int = 7,
        result: BuildResult? = .success,
        finishedAgo: TimeInterval = 60,
        kind: JobKind = .mine
    ) -> Build {
        let duration: TimeInterval = 1800
        return Build(
            job: job, number: number, kind: kind,
            phase: result.map { .finished(result: $0, duration: duration) } ?? .running,
            startedAt: now.addingTimeInterval(-finishedAgo - duration))
    }

    private static func visibility(
        _ build: Build,
        hidden: [String: Int] = [:],
        merged: Set<Int> = [],
        preferences: Preferences = Preferences()
    ) -> BuildVisibility {
        PipelineRules.visibility(of: build, hidden: hidden, merged: merged, preferences: preferences, now: now)
    }

    // MARK: HIDE-02

    @Test("HIDE-02 hides successful builds immediately when set")
    func hidesSuccessImmediately() {
        let immediately = Preferences(hideSuccessfulAfter: .immediately)

        #expect(Self.visibility(Self.build(finishedAgo: 1), preferences: immediately) == .hiddenAutomatically)
        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: 1), preferences: immediately) == .shown)
        #expect(Self.visibility(Self.build(finishedAgo: 1)) == .shown)
    }

    @Test("HIDE-02 hides failed builds after N hours")
    func hidesFailedAfterHours() {
        let day = Preferences(hideFailedAfter: .hours(24))

        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: 24 * 3600), preferences: day) == .shown)
        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: 24 * 3600 + 1), preferences: day) == .hiddenAutomatically)
        // The defaults: a successful build after a day, a failed one after a week.
        #expect(Self.visibility(Self.build(finishedAgo: 24 * 3600 + 1)) == .hiddenAutomatically)
        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: 24 * 3600 + 1)) == .shown)
        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: 168 * 3600 + 1)) == .hiddenAutomatically)
    }

    @Test("HIDE-02 never hides with never")
    func neverHidesWithNever() {
        let never = Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .never)
        let year: TimeInterval = 365 * 24 * 3600

        #expect(Self.visibility(Self.build(finishedAgo: year), preferences: never) == .shown)
        #expect(Self.visibility(Self.build(result: .failure, finishedAgo: year), preferences: never) == .shown)
    }

    @Test("HIDE-02 never hides a running build")
    func neverHidesRunning() {
        let immediately = Preferences(hideSuccessfulAfter: .immediately, hideFailedAfter: .immediately)

        #expect(Self.visibility(Self.build(result: nil, finishedAgo: 30 * 24 * 3600), preferences: immediately) == .shown)
    }

    @Test("HIDE-02 unstable and aborted follow the failed setting")
    func unstableAndAbortedFollowFailed() {
        let preferences = Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .immediately)

        for result in [BuildResult.unstable, .aborted, .notBuilt, .failure] {
            #expect(Self.visibility(Self.build(result: result), preferences: preferences) == .hiddenAutomatically)
        }
        #expect(Self.visibility(Self.build(result: .success), preferences: preferences) == .shown)
    }

    // MARK: HIDE-03, HIDE-04, HIDE-01

    @Test("HIDE-03 hides a running build of a merged MR, and never a branch job")
    func mergedRules() {
        #expect(Self.visibility(Self.build(result: nil), merged: [1]) == .hiddenAutomatically)
        #expect(Self.visibility(Self.build(result: nil), merged: [2]) == .shown)
        #expect(Self.visibility(Self.build("feature%252Ffoo"), merged: [1]) == .shown)
        #expect(Self.visibility(Self.build(), merged: [1], preferences: Preferences(hidesMergedBuilds: false)) == .shown)
    }

    @Test("HIDE-04 builds hidden automatically and by hand count as automatic")
    func automaticWinsOverHand() {
        let immediately = Preferences(hideSuccessfulAfter: .immediately)

        #expect(Self.visibility(Self.build(), hidden: ["MR-1": 7]) == .hiddenByHand)
        #expect(Self.visibility(Self.build(), hidden: ["MR-1": 7], preferences: immediately) == .hiddenAutomatically)
        #expect(Self.visibility(Self.build(), hidden: ["MR-1": 7], merged: [1]) == .hiddenAutomatically)
        #expect(Self.visibility(Self.build(), hidden: ["MR-1": 6]) == .shown)
    }

    @Test("HIDE-01 show hidden counts singular and plural")
    func showHiddenTitle() {
        #expect(PipelinesStore.showHiddenTitle(count: 0) == nil)
        #expect(PipelinesStore.showHiddenTitle(count: 1) == "Show 1 Hidden Build")
        #expect(PipelinesStore.showHiddenTitle(count: 3) == "Show 3 Hidden Builds")
    }

    // MARK: PIPE-05

    @Test("PIPE-05 counts running failed unstable and successful builds in that order")
    func countsInOrder() {
        let builds = [
            Self.build("MR-1", result: .success), Self.build("MR-2", result: .failure), Self.build("MR-3", result: nil),
            Self.build("MR-4", result: .unstable), Self.build("MR-5", result: .success), Self.build("MR-6", result: nil),
        ]

        let counts = PipelineRules.counts(of: builds)

        #expect(counts == BuildCounts(running: 2, failed: 1, unstable: 1, successful: 2))
        #expect(counts.shown.map(\.kind) == [.running, .failed, .unstable, .successful])
        #expect(counts.shown.map(\.count) == [2, 1, 1, 2])
        #expect(PipelineRules.counts(of: [Self.build(result: nil), Self.build(result: .success)]).shown.map(\.kind) == [.running, .successful])
    }

    @Test("PIPE-05 does not count aborted builds")
    func doesNotCountAborted() {
        let counts = PipelineRules.counts(of: [Self.build(result: .aborted), Self.build(result: .notBuilt)])

        #expect(counts.isEmpty)
        #expect(counts.shown.isEmpty)
    }

    // MARK: PIPE-06

    @Test("PIPE-06 empty states follow the lookup and the builds shown")
    func emptyStates() {
        let noLookup = JenkinsState()
        let noJobs = JenkinsState(me: "jdoe", myJobs: [])
        let jobs = JenkinsState(me: "jdoe", myJobs: ["MR-1"])
        let build = Self.build()

        #expect(PipelineRules.emptyState(state: noLookup, mine: [], watched: []) == nil)
        #expect(PipelineRules.emptyState(state: noJobs, mine: [], watched: []) == .noJobs(user: "jdoe"))
        #expect(PipelineRules.emptyState(state: noJobs, mine: [], watched: [build]) == .noJobs(user: "jdoe"))
        #expect(PipelineRules.emptyState(state: jobs, mine: [], watched: []) == .noBuilds)
        #expect(PipelineRules.emptyState(state: jobs, mine: [build], watched: []) == nil)
        #expect(PipelinesEmptyState.noJobs(user: "jdoe").message == "No merge request builds by jdoe in Jenkins")
        #expect(PipelinesEmptyState.noBuilds.message == "No builds to show")
    }

    // MARK: PIPE-03

    private static let jobURL = URL(string: "https://jenkins.example.com/job/project")!

    @Test("PIPE-03 MR job links to its merge request")
    func mergeRequestLink() {
        var build = Self.build("MR-12", number: 4)
        build.gitLabURL = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12")

        let first = PipelineRules.links(of: build, jobURL: Self.jobURL).first

        #expect(first == BuildLink(kind: .mergeRequest, title: "Open Merge Request !12", url: build.gitLabURL!))
    }

    @Test("PIPE-03 branch job links to its branch")
    func branchLink() {
        var build = Self.build("feature%252Ffoo", number: 3)
        build.gitLabURL = URL(string: "https://gitlab.example.com/group/project/-/tree/feature/foo")
        var withoutLink = build
        withoutLink.gitLabURL = nil

        let first = PipelineRules.links(of: build, jobURL: Self.jobURL).first

        #expect(first == BuildLink(kind: .branch, title: "Open Branch feature/foo in GitLab", url: build.gitLabURL!))
        #expect(PipelineRules.links(of: withoutLink, jobURL: Self.jobURL).map(\.kind) == [.build, .console, .testResults])
    }

    @Test("PIPE-03 links to the build, console and test results")
    func buildLinks() {
        let links = PipelineRules.links(of: Self.build("MR-12", number: 4), jobURL: Self.jobURL)

        #expect(links.map(\.title) == ["Open Build #4", "Console Output", "Test Results"])
        #expect(links.map(\.url.absoluteString) == [
            "https://jenkins.example.com/job/project/job/MR-12/4/",
            "https://jenkins.example.com/job/project/job/MR-12/4/console",
            "https://jenkins.example.com/job/project/job/MR-12/4/testReport",
        ])
    }

    // MARK: WATCH-06

    @Test("WATCH-06 a watched job's status names its last build or waits")
    func watchedStatus() {
        let watched = WatchedJob(job: "MR-2", label: "!2", added: Self.now)
        let jobURL = URL(string: "https://jenkins.example.com/job/project/")!

        let waiting = WatchedJobStatus(watched: watched, build: nil, url: PipelineRules.jobURL(job: "MR-2", jobURL: jobURL))
        let running = WatchedJobStatus(watched: watched, build: Self.build("MR-2", number: 5, result: nil), url: nil)
        let failed = WatchedJobStatus(watched: watched, build: Self.build("MR-2", number: 5, result: .failure), url: nil)

        #expect(waiting.title == "!2")
        #expect(waiting.state == "WAITING")
        #expect(waiting.isWaiting)
        #expect(waiting.url?.absoluteString == "https://jenkins.example.com/job/project/job/MR-2/")
        #expect(running.title == "!2 #5")
        #expect(running.state == "RUNNING")
        #expect(failed.state == "FAILURE")
    }
}

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

    struct HideCase: Sendable, CustomTestStringConvertible {
        var name: String
        var result: BuildResult?
        var finishedAgo: TimeInterval
        var preferences = Preferences()
        var hidden: Bool
        var testDescription: String { name }
    }

    private static let hour: TimeInterval = 3600

    static let hideCases: [HideCase] = [
        HideCase(
            name: "successful: hidden at once when set", result: .success, finishedAgo: 1,
            preferences: Preferences(hideSuccessfulAfter: .immediately), hidden: true),
        HideCase(
            name: "failed: the successful setting doesn't apply", result: .failure, finishedAgo: 1,
            preferences: Preferences(hideSuccessfulAfter: .immediately), hidden: false),
        HideCase(name: "successful: shown by default at first", result: .success, finishedAgo: 1, hidden: false),
        HideCase(
            name: "failed: shown exactly at N hours", result: .failure, finishedAgo: 24 * hour,
            preferences: Preferences(hideFailedAfter: .hours(24)), hidden: false),
        HideCase(
            name: "failed: hidden past N hours", result: .failure, finishedAgo: 24 * hour + 1,
            preferences: Preferences(hideFailedAfter: .hours(24)), hidden: true),
        HideCase(name: "default: successful hidden after a day", result: .success, finishedAgo: 24 * hour + 1, hidden: true),
        HideCase(name: "default: failed still shown after a day", result: .failure, finishedAgo: 24 * hour + 1, hidden: false),
        HideCase(name: "default: failed hidden after a week", result: .failure, finishedAgo: 168 * hour + 1, hidden: true),
        HideCase(
            name: "never: successful stays", result: .success, finishedAgo: 365 * 24 * hour,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .never), hidden: false),
        HideCase(
            name: "never: failed stays", result: .failure, finishedAgo: 365 * 24 * hour,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .never), hidden: false),
        HideCase(
            name: "a running build is never hidden", result: nil, finishedAgo: 30 * 24 * hour,
            preferences: Preferences(hideSuccessfulAfter: .immediately, hideFailedAfter: .immediately), hidden: false),
        HideCase(
            name: "unstable follows the failed setting", result: .unstable, finishedAgo: 60,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .immediately), hidden: true),
        HideCase(
            name: "aborted follows the failed setting", result: .aborted, finishedAgo: 60,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .immediately), hidden: true),
        HideCase(
            name: "not built follows the failed setting", result: .notBuilt, finishedAgo: 60,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .immediately), hidden: true),
        HideCase(
            name: "successful ignores the failed setting", result: .success, finishedAgo: 60,
            preferences: Preferences(hideSuccessfulAfter: .never, hideFailedAfter: .immediately), hidden: false),
    ]

    @Test("HIDE-02 hides finished builds by the settings of their result, and never a running one", arguments: hideCases)
    func hidesByTheSettings(_ item: HideCase) {
        let build = Self.build(result: item.result, finishedAgo: item.finishedAgo)

        #expect(Self.visibility(build, preferences: item.preferences) == (item.hidden ? .hiddenAutomatically : .shown))
    }

    // MARK: HIDE-03, HIDE-04

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

    // MARK: PIPE-05

    @Test("PIPE-05 counts running failed unstable and successful builds, and not aborted or not built ones")
    func countsBuilds() {
        let builds = [
            Self.build("MR-1", result: .success), Self.build("MR-2", result: .failure), Self.build("MR-3", result: nil),
            Self.build("MR-4", result: .unstable), Self.build("MR-5", result: .success), Self.build("MR-6", result: nil),
            Self.build("MR-7", result: .aborted), Self.build("MR-8", result: .notBuilt),
        ]

        #expect(PipelineRules.counts(of: builds) == BuildCounts(running: 2, failed: 1, unstable: 1, successful: 2))
        #expect(PipelineRules.counts(of: [Self.build(result: .aborted), Self.build(result: .notBuilt)]).isEmpty)
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
    }

    // MARK: PIPE-03

    private static let jobURL = URL(string: "https://jenkins.example.com/job/project")!

    @Test("PIPE-03 a build links to its merge request or branch, then to the build, console and test results")
    func links() {
        var mergeRequest = Self.build("MR-12", number: 4)
        mergeRequest.gitLabURL = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12")
        var branch = Self.build("feature%252Ffoo", number: 3)
        branch.gitLabURL = URL(string: "https://gitlab.example.com/group/project/-/tree/feature/foo")
        var withoutLink = branch
        withoutLink.gitLabURL = nil

        let mergeRequestLinks = PipelineRules.links(of: mergeRequest, jobURL: Self.jobURL)
        let branchLinks = PipelineRules.links(of: branch, jobURL: Self.jobURL)

        #expect(mergeRequestLinks.map(\.kind) == [.mergeRequest, .build, .console, .testResults])
        #expect(mergeRequestLinks.first?.url == mergeRequest.gitLabURL)
        #expect(branchLinks.map(\.kind) == [.branch, .build, .console, .testResults])
        #expect(branchLinks.first?.url == branch.gitLabURL)
        #expect(PipelineRules.links(of: withoutLink, jobURL: Self.jobURL).map(\.kind) == [.build, .console, .testResults])
        #expect(mergeRequestLinks.dropFirst().map(\.url.absoluteString) == [
            "https://jenkins.example.com/job/project/job/MR-12/4/",
            "https://jenkins.example.com/job/project/job/MR-12/4/console",
            "https://jenkins.example.com/job/project/job/MR-12/4/testReport",
        ])
    }
}

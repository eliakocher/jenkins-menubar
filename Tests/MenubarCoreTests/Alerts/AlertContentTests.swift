import Foundation
import Testing

@testable import MenubarCore

@Suite("AlertContent")
struct AlertContentTests {
    private static let jobURL = URL(string: "https://jenkins.example.com/job/team/job/project")!
    private static let mergeRequest = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/1")!

    private static func content(
        _ result: BuildResult,
        job: String = "MR-1",
        title: String? = "Fix the login",
        gitLabURL: URL? = mergeRequest,
        duration: TimeInterval = 1800,
        stages: [Stage]? = nil,
        testCounts: TestCounts? = nil,
        failedStages: [String] = []
    ) throws -> AlertContent {
        let build = Build(
            job: job, number: 7, title: title, gitLabURL: gitLabURL, kind: .mine,
            phase: .finished(result: result, duration: duration), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            stages: stages, testCounts: testCounts)
        return try #require(
            AlertContent.finished(build, failedStages: failedStages, links: AlertContent.links(for: build, jobURL: jobURL)))
    }

    // MARK: ALERT-02

    @Test("ALERT-02 success alert content")
    func success() throws {
        let content = try Self.content(.success, testCounts: TestCounts(failed: 0, total: 1200), failedStages: ["lint"])
        // No failed tests, and failed stages only for a result other than SUCCESS.
        #expect(content.facts == ["Duration: 0h30m"])
        #expect(content.links.build.absoluteString == "https://jenkins.example.com/job/team/job/project/job/MR-1/7/")
        #expect(content.links.mergeRequest == Self.mergeRequest)

        // Durations are whole hours and minutes, rounded down (PIPE-02).
        #expect(AlertContent.durationText(0) == "0h00m")
        #expect(AlertContent.durationText(65 * 60 + 59) == "1h05m")
        #expect(AlertContent.durationText(-5) == "0h00m")
    }

    @Test("ALERT-02 failure alert lists failed tests and stages")
    func failure() throws {
        let content = try Self.content(
            .failure, duration: 2 * 3600 + 31 * 60 + 59, testCounts: TestCounts(failed: 3, total: 1200),
            failedStages: ["build", "integration-tests"])
        #expect(content.facts == ["Duration: 2h31m", "3 failed tests", "Failed stages: build, integration-tests"])
    }

    @Test("ALERT-02 title is left out when it equals the job name")
    func titleLeftOut() throws {
        for title in ["MR-1", "!1", "", nil] as [String?] {
            let content = try Self.content(.success, title: title)
            #expect(content.title == nil)
        }
    }

    @Test("ALERT-02 branch build has no MR link")
    func branchBuild() throws {
        let content = try Self.content(
            .success, job: "feature%252Ffoo", title: "feature/foo",
            gitLabURL: URL(string: "https://gitlab.example.com/group/project/-/tree/feature/foo"))
        #expect(content.links.mergeRequest == nil)
        #expect(content.links.build.absoluteString == "https://jenkins.example.com/job/team/job/project/job/feature%252Ffoo/7/")
        // The headline reads the branch's name, and its title only repeated it.
        #expect(content.headlineParts?.label == "feature/foo")
        #expect(content.title == nil)
        #expect(content.defaultAction == .openBuild)
    }

    // MARK: ALERT-03

    /// What a live alert offers, by result and by kind of build: the window's buttons, its context menu and the banner's
    /// actions. Open Console and Hide are there for every result, Rebuild only for the results that failed.
    @Test(
        "ALERT-03 the actions of an alert depend on the result and the kind of build",
        arguments: [
            (BuildResult.success, true, [AlertContent.Action.openMergeRequest, .openBuild, .dismiss],
             [AlertContent.Action.openMergeRequest, .openBuild, .openConsole, .hide]),
            (.success, false, [.openBuild, .dismiss], [.openBuild, .openConsole, .hide]),
            (.failure, true, [.openBuild, .rebuild, .openMergeRequest, .dismiss],
             [.openMergeRequest, .openBuild, .rebuild, .openConsole, .hide]),
            (.failure, false, [.openBuild, .rebuild, .dismiss], [.openBuild, .rebuild, .openConsole, .hide]),
            (.unstable, false, [.openBuild, .rebuild, .dismiss], [.openBuild, .rebuild, .openConsole, .hide]),
            (.aborted, true, [.openBuild, .rebuild, .openMergeRequest, .dismiss],
             [.openMergeRequest, .openBuild, .rebuild, .openConsole, .hide]),
            (.notBuilt, false, [.openBuild, .dismiss], [.openBuild, .openConsole, .hide]),
        ])
    func liveActions(
        result: BuildResult, mergeRequest: Bool, buttons: [AlertContent.Action], banner: [AlertContent.Action]
    ) throws {
        let content = try Self.content(result, gitLabURL: mergeRequest ? Self.mergeRequest : nil)
        #expect(content.isLive)
        #expect(content.buttons == buttons)
        #expect(content.defaultAction == buttons.first, "the first button is the default")
        #expect(content.url(for: .openMergeRequest) == (mergeRequest ? Self.mergeRequest : nil))
        #expect(content.rebuild == (buttons.contains(.rebuild) ? BuildID(job: "MR-1", number: 7) : nil))
        #expect(content.moreActions == [.openConsole, .hide])
        #expect(content.bannerActions == banner)
        #expect(content.hide == BuildID(job: "MR-1", number: 7))
        #expect(content.url(for: .openConsole) == content.links.build.appending(path: "console"))
        #expect(content.url(for: .hide) == nil)
    }

    // MARK: ALERT-11

    private static func watched(
        _ result: BuildResult, author: String? = "Sam Lee", gitLabURL: URL? = mergeRequest
    ) -> Build {
        Build(
            job: "MR-12", number: 5, title: "Fix the login", gitLabURL: gitLabURL, author: author, kind: .watched,
            phase: .finished(result: result, duration: 1800), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("ALERT-11 a watched build's alert is marked, names its author and offers no Rebuild", arguments: [
        BuildResult.failure, .unstable, .aborted, .success,
    ])
    func watchedAlert(result: BuildResult) throws {
        let build = Self.watched(result)
        let content = try #require(
            AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: Self.jobURL)))
        #expect(content.ownership == .watched && content.isWatched)
        #expect(content.watchedAuthor == "Sam Lee")
        #expect(content.headline.hasPrefix("Watching · "))
        #expect(content.headline.hasSuffix("!12 #5 \(result)"))
        #expect(content.bannerBody.split(separator: "\n").prefix(2) == ["Fix the login", "by Sam Lee"])
        // No write action, in the window, its context menu and the banner; the read-only ones stay.
        #expect(content.rebuild == nil && !content.offersRebuild)
        #expect(!content.buttons.contains(.rebuild) && !content.bannerActions.contains(.rebuild))
        #expect(!content.bannerCategory.actions.contains(.rebuild) && !content.moreActions.contains(.rebuild))
        #expect(content.buttons.contains(.openBuild) && content.buttons.contains(.openMergeRequest))
        #expect(content.bannerActions.contains(.openBuild) && content.bannerActions.contains(.openConsole))
        let payload = BannerPayload(content: content)
        #expect(payload.rebuild == nil)
        #expect(payload.intent(forAction: AlertContent.Action.rebuild.rawValue) == nil)

        // Even a rebuild put on the content by mistake is never offered.
        var forced = content
        forced.rebuild = build.id
        #expect(!forced.buttons.contains(.rebuild) && !forced.bannerActions.contains(.rebuild))
        #expect(BannerPayload(content: forced).rebuild == nil)
    }

    @Test("ALERT-11 a watched build without an author is still marked")
    func watchedWithoutAuthor() throws {
        for author in [nil, "", "  "] as [String?] {
            let build = Self.watched(.failure, author: author)
            let content = try #require(
                AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: Self.jobURL)))
            #expect(content.isWatched && content.watchedAuthor == nil)
            #expect(!content.bannerBody.contains("by "))
        }
    }

    @Test("ALERT-11 my build's alert keeps its title and its Rebuild")
    func mineKeepsRebuild() throws {
        let content = try Self.content(.failure)
        #expect(content.ownership == .mine && !content.isWatched && content.watchedAuthor == nil)
        #expect(content.headline == "❌ !1 #7 FAILURE")
        #expect(content.offersRebuild && content.buttons.contains(.rebuild) && content.bannerActions.contains(.rebuild))
        #expect(!content.bannerBody.contains("by "))
    }

    @Test("ALERT-11 a watched build's stage banner is marked")
    func watchedStageBanner() {
        let url = Self.jobURL
        let watched = AlertContent.stageFailed(Self.watched(.failure), failedStages: ["tests"], buildURL: url)
        #expect(watched.headline == "Watching · 💥 !12 #5: stage failed")
        #expect(watched.isWatched && watched.watchedAuthor == "Sam Lee" && !watched.bannerActions.contains(.rebuild))
        #expect(watched.bannerBody == "tests\nFix the login\nby Sam Lee")
        var mine = Self.watched(.failure)
        mine.kind = .mine
        #expect(AlertContent.stageFailed(mine, failedStages: ["tests"], buildURL: url).headline == "💥 !12 #5: stage failed")
    }
}

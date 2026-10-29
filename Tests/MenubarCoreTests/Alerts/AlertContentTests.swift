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
        #expect(content.result == .success)
        #expect(content.icon == .happy)
        #expect(content.headline == "✅ !1 #7 SUCCESS")
        // The alert window shows the parts after the result's SF Symbol, without the emoji.
        #expect(content.headlineParts == AlertContent.HeadlineParts(label: "!1", number: 7, result: "SUCCESS"))
        #expect(content.headlineParts?.text == "!1 #7 SUCCESS")
        #expect(content.title == "Fix the login")
        // No failed tests, and failed stages only for a result other than SUCCESS.
        #expect(content.facts == ["Duration: 0h30m"])
        #expect(content.bannerBody == "Fix the login\nDuration: 0h30m")
        #expect(content.sound == .glass)
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
        #expect(content.headline == "❌ !1 #7 FAILURE")
        #expect(content.icon == .sad)
        #expect(content.facts == ["Duration: 2h31m", "Failed tests: 3 of 1200", "Failed stages: build, integration-tests"])
        #expect(content.bannerBody == "Fix the login\nDuration: 2h31m\nFailed tests: 3 of 1200\nFailed stages: build, integration-tests")
        #expect(content.sound == .basso)
    }

    @Test("ALERT-02 unstable aborted and other results")
    func otherResults() throws {
        let expected: [(BuildResult, String, AlertContent.Sound, AlertContent.ResultKind)] = [
            (.unstable, "⚠️ !1 #7 UNSTABLE", .funk, .unstable),
            (.aborted, "⏹ !1 #7 ABORTED", .submarine, .aborted),
            (.notBuilt, "❔ !1 #7 NOT_BUILT", .ping, .other),
            (BuildResult(rawValue: "CANCELLED"), "❔ !1 #7 CANCELLED", .ping, .other),
        ]
        for (result, headline, sound, kind) in expected {
            let content = try Self.content(result)
            #expect(content.headline == headline)
            #expect(content.headlineParts?.result == result.rawValue)
            #expect(content.sound == sound)
            #expect(content.result == kind)
            #expect(content.icon == .sad)
        }
    }

    @Test("ALERT-02 title is left out when it equals the job name")
    func titleLeftOut() throws {
        for title in ["MR-1", "!1", "", nil] as [String?] {
            let content = try Self.content(.success, title: title)
            #expect(content.title == nil)
            #expect(content.bannerBody == "Duration: 0h30m")
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
        #expect(content.headline == "✅ feature/foo #7 SUCCESS")
        #expect(content.headlineParts?.text == "feature/foo #7 SUCCESS")
        #expect(content.title == nil)
        #expect(content.defaultAction == .openBuild)
    }

    // MARK: ALERT-03

    @Test("ALERT-03 default button is Open MR for a success with an MR")
    func defaultOpenMergeRequest() throws {
        let content = try Self.content(.success)
        #expect(content.defaultAction == .openMergeRequest)
        #expect(content.buttons == [.openMergeRequest, .openBuild, .dismiss])
        #expect(content.buttons.map(\.title) == ["Open MR", "Open Build", "Dismiss"])
        #expect(content.url(for: content.defaultAction) == Self.mergeRequest)
    }

    @Test("ALERT-03 default button is Open build otherwise")
    func defaultOpenBuild() throws {
        let failure = try Self.content(.failure)
        #expect(failure.defaultAction == .openBuild)
        // Rebuild comes next to Open Build for a failed, unstable or aborted build (PIPE-09).
        #expect(failure.buttons == [.openBuild, .rebuild, .openMergeRequest, .dismiss])
        #expect(failure.buttons.map(\.title) == ["Open Build", "Rebuild", "Open MR", "Dismiss"])
        #expect(failure.rebuild == BuildID(job: "MR-1", number: 7))
        #expect(failure.url(for: .openBuild) == failure.links.build)

        let branch = try Self.content(.success, gitLabURL: nil)
        #expect(branch.defaultAction == .openBuild)
    }

    @Test("ALERT-03 no Open MR button without an MR link")
    func noOpenMergeRequest() throws {
        let content = try Self.content(.failure, gitLabURL: nil)
        #expect(content.buttons == [.openBuild, .rebuild, .dismiss])
        #expect(content.url(for: .openMergeRequest) == nil)
        #expect(content.url(for: .dismiss) == nil)
    }

    @Test("ALERT-03 banner category depends on the MR link")
    func bannerCategory() throws {
        let withMergeRequest = try Self.content(.success)
        #expect(withMergeRequest.bannerCategory == .buildAndMergeRequestLive)
        #expect(withMergeRequest.bannerCategory.rawValue == "build-and-mr-live")
        #expect(withMergeRequest.bannerActions == [.openMergeRequest, .openBuild, .openConsole, .hide])

        let withoutMergeRequest = try Self.content(.success, gitLabURL: nil)
        #expect(withoutMergeRequest.bannerCategory == .buildLive)
        #expect(withoutMergeRequest.bannerActions == [.openBuild, .openConsole, .hide])
    }

    /// What a live alert offers, by result and by kind of build: the window's buttons, its More menu and the banner's
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
        #expect(content.moreActions == [.openConsole, .hide])
        #expect(content.bannerActions == banner)
        #expect(content.hide == BuildID(job: "MR-1", number: 7))
        #expect(content.url(for: .openConsole) == content.links.build.appending(path: "console"))
        #expect(content.url(for: .hide) == nil)
    }

    @Test("ALERT-03 a stage banner offers Open Build, Open Console and Hide")
    func stageBannerActions() {
        let build = Build(
            job: "MR-1", number: 7, title: nil, gitLabURL: Self.mergeRequest, kind: .watched, phase: .running,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let buildURL = AlertContent.buildURL(job: "MR-1", number: 7, jobURL: Self.jobURL)
        let content = AlertContent.stageFailed(build, failedStages: ["build"], buildURL: buildURL)
        #expect(content.bannerCategory == .buildLive)
        #expect(content.bannerActions == [.openBuild, .openConsole, .hide])
        #expect(content.url(for: .openConsole) == buildURL.appending(path: "console"))
        #expect(content.hide == build.id)
    }

    @Test("ALERT-07 a preview offers no Console, no Hide and no Rebuild")
    func previewOffersNoLiveActions() throws {
        let team = TeamValues(
            jenkinsJobURL: Self.jobURL.absoluteString, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project")
        for sample in BuildAlert.PreviewSample.allCases {
            let content = try #require(BuildAlert.preview(sample, team: team)).content
            #expect(!content.isLive)
            #expect(content.moreActions.isEmpty)
            #expect(content.rebuild == nil)
            #expect(content.url(for: .openConsole) == nil)
            #expect(![AlertContent.Action.openConsole, .hide, .rebuild].contains { content.bannerActions.contains($0) })
            #expect(content.bannerCategory.rawValue == "build-and-mr")
        }
    }
}

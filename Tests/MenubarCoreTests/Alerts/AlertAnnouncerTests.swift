import Foundation
import Testing

@testable import MenubarCore

@Suite("AlertAnnouncer")
struct AlertAnnouncerTests {
    private static let jobURL = URL(string: "https://jenkins.example.com/job/team/job/project")!
    private static let team = TeamValues(
        jenkinsJobURL: jobURL.absoluteString, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project")

    /// The announcer with fake effects and a log in a temporary folder.
    private struct Setup {
        let folder: TemporaryFolder
        let effects: FakeEffects
        let log: ActivityLog
        let announcer: AlertAnnouncer

        init(notificationsAllowed: Bool = true) throws {
            folder = try TemporaryFolder()
            effects = FakeEffects(notificationsAllowed: notificationsAllowed)
            log = ActivityLog(folder: folder.url)
            announcer = AlertAnnouncer(effects: effects, log: log)
        }

        /// the log's entries as `source message | detail | outcome`
        func logged() async -> [String] {
            await log.entries().map {
                "\($0.source) \($0.message) | \($0.detail ?? "") | \($0.outcome?.description ?? "")"
            }
        }
    }

    private static func preferences(_ style: Preferences.AlertStyle = .window, stageAlerts: Bool = true) -> Preferences {
        Preferences(alertStyle: style, stageAlerts: stageAlerts)
    }

    /// The alert for `MR-1 #7`, as the policy builds it.
    private static func finished(_ result: BuildResult, mergeRequest: Bool = true) throws -> BuildAlert {
        let build = Build(
            job: "MR-1", number: 7, title: "Fix the login",
            gitLabURL: mergeRequest ? URL(string: "https://gitlab.example.com/group/project/-/merge_requests/1") : nil,
            kind: .mine, phase: .finished(result: result, duration: 1800), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            testCounts: TestCounts(failed: result == .failure ? 2 : 0, total: 40))
        let content = try #require(
            AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: jobURL)))
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    private static func stageBanner() -> BuildAlert {
        let build = Build(
            job: "MR-1", number: 7, title: "Fix the login", kind: .mine, phase: .running, startedAt: Date(),
            stages: [Stage(name: "build", status: .failed, duration: 10)])
        let content = AlertContent.stageFailed(
            build, failedStages: ["build"], buildURL: AlertContent.buildURL(job: "MR-1", number: 7, jobURL: jobURL))
        return BuildAlert(kind: .stageFailed, build: build, content: content)
    }

    // MARK: ALERT-02

    @Test("ALERT-02 plays the sound of the result")
    func playsSound() async throws {
        for style in Preferences.AlertStyle.allCases {
            let setup = try Setup()
            for result in [BuildResult.success, .unstable, .failure, .aborted, .notBuilt] {
                await setup.announcer.announce(try Self.finished(result), preferences: Self.preferences(style))
            }
            #expect(await setup.effects.sounds == [.glass, .funk, .basso, .submarine, .ping])
        }
    }

    // MARK: ALERT-03

    @Test("ALERT-03 shows the alert window and no banner by default")
    func windowByDefault() async throws {
        let setup = try Setup()
        let alert = try Self.finished(.success)
        await setup.announcer.announce([alert], preferences: Preferences())
        #expect(await setup.effects.alertWindows == [alert])
        #expect(await setup.effects.banners.isEmpty)
    }

    @Test("ALERT-03 shows a banner and no window when set")
    func bannerWhenSet() async throws {
        let setup = try Setup()
        let alert = try Self.finished(.failure)
        await setup.announcer.announce([alert], preferences: Self.preferences(.banner))
        #expect(await setup.effects.banners == [alert])
        #expect(await setup.effects.alertWindows.isEmpty)
    }

    @Test("ALERT-03 falls back to the window when notifications are off")
    func fallsBackToWindow() async throws {
        let setup = try Setup(notificationsAllowed: false)
        let alert = try Self.finished(.success)
        await setup.announcer.announce([alert], preferences: Self.preferences(.banner))
        #expect(await setup.effects.alertWindows == [alert])
        #expect(await setup.logged().contains { $0.hasPrefix("alerts ✅ !1 #7 SUCCESS (alert, notifications are off) |") })
    }

    // MARK: ALERT-05

    @Test("ALERT-05 no stage banner when the setting is off")
    func stageBannerOff() async throws {
        let setup = try Setup()
        await setup.announcer.announce(Self.stageBanner(), preferences: Self.preferences(stageAlerts: false))
        #expect(await setup.effects.calls.isEmpty)
        #expect(await setup.logged().isEmpty)
    }

    // MARK: ALERT-07

    @Test("ALERT-07 previews the success alert in the chosen style")
    func previewSuccess() async throws {
        let setup = try Setup()
        #expect(await setup.announcer.preview(.success, team: Self.team, preferences: Self.preferences(.window)))
        let shown = try #require(await setup.effects.alertWindows.first)
        #expect(shown.kind == .preview)
        #expect(shown.content.headline == "✅ !123 #2 SUCCESS")
        #expect(shown.content.title == "This is what a finished build looks like.")
        #expect(shown.content.facts == ["Duration: 4h12m"])
        #expect(shown.content.links.build == Self.jobURL)
        #expect(shown.content.links.mergeRequest?.absoluteString == "https://gitlab.example.com/group/project/-/merge_requests")
        #expect(shown.content.defaultAction == .openMergeRequest)
        #expect(await setup.effects.sounds == [.glass])
        #expect(await setup.effects.banners.isEmpty)

        // Without the team's Jenkins job there is nothing to link to, so nothing shows.
        let empty = try Setup()
        #expect(await !empty.announcer.preview(.success, team: TeamValues(), preferences: Preferences()))
        #expect(await empty.effects.calls.isEmpty)
    }

    @Test("ALERT-07 previews the failure alert as a banner")
    func previewFailure() async throws {
        let setup = try Setup()
        await setup.announcer.preview(.failure, team: Self.team, preferences: Self.preferences(.banner))
        let shown = try #require(await setup.effects.banners.first)
        #expect(shown.content.headline == "❌ !123 #2 FAILURE")
        #expect(shown.content.title == "This is what a failed build looks like.")
        #expect(shown.content.facts == ["Duration: 2h31m", "Failed tests: 3 of 1200", "Failed stages: integration-tests"])
        #expect(shown.content.defaultAction == .openBuild)
        #expect(await setup.effects.calls == [.sound(.basso), .banner(shown)])
    }

    @Test("ALERT-07 preview is not logged as an alert")
    func previewNotLogged() async throws {
        let setup = try Setup()
        await setup.announcer.preview(.success, team: Self.team, preferences: Preferences())
        await setup.announcer.preview(.failure, team: Self.team, preferences: Self.preferences(.banner))
        #expect(await setup.logged() == ["alerts Preview of the success alert |  | ", "alerts Preview of the failure alert |  | "])
    }

    // MARK: ALERT-08

    @Test("ALERT-08 logs the alert with its style and outcome")
    func logsAlerts() async throws {
        let setup = try Setup()
        await setup.announcer.announce(try Self.finished(.success), preferences: Self.preferences(.window))
        await setup.announcer.announce(try Self.finished(.failure), preferences: Self.preferences(.banner))
        await setup.announcer.announce(try Self.finished(.unstable), preferences: Preferences())
        await setup.announcer.announce(try Self.finished(.aborted), preferences: Preferences())
        await setup.announcer.announce(try Self.finished(.notBuilt), preferences: Preferences())
        await setup.announcer.announce(Self.stageBanner(), preferences: Preferences())
        #expect(
            await setup.logged() == [
                "jenkins !1 #7 finished | Fix the login | ok:SUCCESS",
                "alerts ✅ !1 #7 SUCCESS (alert) | Fix the login Duration: 0h30m | ok:SUCCESS",
                "jenkins !1 #7 finished | Fix the login | failed:FAILURE",
                "alerts ❌ !1 #7 FAILURE (banner) | Fix the login Duration: 0h30m Failed tests: 2 of 40 | failed:FAILURE",
                "jenkins !1 #7 finished | Fix the login | warning:UNSTABLE",
                "alerts ⚠️ !1 #7 UNSTABLE (alert) | Fix the login Duration: 0h30m | warning:UNSTABLE",
                "jenkins !1 #7 finished | Fix the login | neutral:ABORTED",
                "alerts ⏹ !1 #7 ABORTED (alert) | Fix the login Duration: 0h30m | neutral:ABORTED",
                "jenkins !1 #7 finished | Fix the login | neutral:NOT_BUILT",
                "alerts ❔ !1 #7 NOT_BUILT (alert) | Fix the login Duration: 0h30m | neutral:NOT_BUILT",
                "alerts Banner: !1 #7 stage failed: build | Fix the login | failed:FAILED",
            ])
    }
}

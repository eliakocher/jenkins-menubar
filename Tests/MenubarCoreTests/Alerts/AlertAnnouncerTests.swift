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

    // MARK: ALERT-03

    @Test(
        "ALERT-03 the style decides window or banner, and a banner falls back to the window when notifications are off",
        arguments: [
            (Preferences.AlertStyle.window, true, false), (.banner, true, true), (.banner, false, false),
        ])
    func style(style: Preferences.AlertStyle, notificationsAllowed: Bool, banner: Bool) async throws {
        let setup = try Setup(notificationsAllowed: notificationsAllowed)
        let alert = try Self.finished(.success)

        await setup.announcer.announce([alert], preferences: Self.preferences(style))

        #expect(await setup.effects.banners == (banner ? [alert] : []))
        #expect(await setup.effects.alertWindows == (banner ? [] : [alert]))
    }

    // MARK: ALERT-09

    @Test("ALERT-09 logging a muted finished build writes its lines and shows nothing; a muted stage banner leaves none")
    func mutedFinishedIsLogged() async throws {
        let setup = try Setup()
        let alert = try Self.finished(.failure)
        let stage = BuildAlert(kind: .stageFailed, build: alert.build, content: alert.content)

        await setup.announcer.logMuted([alert, stage])

        let messages = await setup.log.entries().map(\.message)
        #expect(messages.count == 2)
        #expect(messages[0].hasSuffix("finished") && messages[1].hasSuffix("(muted)"))
        #expect(await setup.effects.alertWindows.isEmpty)
        #expect(await setup.effects.banners.isEmpty)
        #expect(await setup.effects.sounds.isEmpty)
    }

    // MARK: ALERT-07

    @Test("ALERT-07 a preview shows in the chosen style, and nothing shows without the team's Jenkins job")
    func preview() async throws {
        let setup = try Setup()
        #expect(await setup.announcer.preview(.success, team: Self.team, preferences: Self.preferences(.window)))
        let shown = try #require(await setup.effects.alertWindows.first)
        #expect(shown.kind == .preview)
        #expect(await setup.effects.banners.isEmpty)

        let empty = try Setup()
        #expect(await !empty.announcer.preview(.success, team: TeamValues(), preferences: Preferences()))
        #expect(await empty.effects.calls.isEmpty)
    }

    // MARK: ALERT-08

    @Test("ALERT-08 logs each alert with the outcome of its result")
    func logsAlerts() async throws {
        let setup = try Setup()
        for result in [BuildResult.success, .failure, .unstable, .aborted, .notBuilt] {
            await setup.announcer.announce(try Self.finished(result), preferences: Preferences())
        }

        // Each result is logged by the build's own line and by the alert's.
        #expect(
            await setup.log.entries().compactMap { $0.outcome?.description } == [
                "ok:SUCCESS", "ok:SUCCESS", "failed:FAILURE", "failed:FAILURE", "warning:UNSTABLE", "warning:UNSTABLE",
                "neutral:ABORTED", "neutral:ABORTED", "neutral:NOT_BUILT", "neutral:NOT_BUILT",
            ])
    }
}

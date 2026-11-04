import Foundation
import Testing

@testable import MenubarCore

/// GitLab's "pipeline failed" pop-up waits two minutes for the failed Jenkins build of the same merge request.
@Suite("Held pipeline alerts", .timeLimit(.minutes(1)))
@MainActor
struct HeldPipelineAlertsTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)
    private nonisolated static let mergeRequest = gitLab.appending(path: "acme/web/app/-/merge_requests/123")

    @MainActor
    private struct Setup {
        let folder: TemporaryFolder
        let defaults = TemporaryDefaults()
        let clock = TestClock()
        let effects = FakeEffects()
        let model: AppModel

        init() throws {
            folder = try TemporaryFolder()
            try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: TeamValues(
                    jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: HeldPipelineAlertsTests.gitLab.absoluteString,
                    gitLabProject: "acme/web/app")))
            model = AppModel(
                dependencies: .fake(
                    root: folder.url, defaults: defaults.defaults, clock: clock, now: { HeldPipelineAlertsTests.start }, effects: effects,
                    processRunner: ScriptedClaude([.failure])))
            // GitLab's failed pipeline is an Inbox entry by default; here it pops up.
            model.inbox.rules.set(.popUp, for: .pipelineFailed)
        }

        func settle() async {
            for _ in 0..<200 {
                await Task.yield()
            }
        }

        /// GitLab's failed pipeline of !123, which the Inbox announces as a Pop-up
        func gitLabFails() async {
            model.inbox.addLocal(HeldPipelineAlertsTests.pipeline())
            await settle()
        }

        /// the failed Jenkins build of MR-123: its pop-up, and its Inbox entry
        func jenkinsFails() async throws {
            let build = Build(
                job: "MR-123", number: 1, title: "Fix the login", gitLabURL: HeldPipelineAlertsTests.mergeRequest, kind: .mine,
                phase: .finished(result: .unstable, duration: 600), startedAt: HeldPipelineAlertsTests.start)
            let content = try #require(
                AlertContent.finished(
                    build, failedStages: [],
                    links: AlertContent.links(for: build, jobURL: URL(string: "https://jenkins.example.com/job/project")!)))
            let alert = BuildAlert(kind: .finished, build: build, content: content)
            await AlertAnnouncer(effects: effects, log: model.log).announce([alert], rules: model.inbox.rules)
            model.addToInbox(finished: [alert])
            await settle()
        }
    }

    private nonisolated static func pipeline() -> InboxEvent {
        InboxEvent(
            id: "pipelineFailed|acme/web/app!123|1", kind: .pipelineFailed, source: .mergeRequests, title: "Fix the login",
            reference: "acme/web/app!123", targetURL: mergeRequest, projectPath: "acme/web/app", occurredAt: start,
            sourceBranch: "fix-login")
    }

    @Test("INBOX-17 GitLab's failed pipeline waits for the failed build: the build's pop-up is the only one, GitLab's entry becomes the build's")
    func buildArrivesInTheWindow() async throws {
        let setup = try Setup()
        // The model's own background waits start while the Inbox settles; count after them.
        await setup.settle()
        let sleepers = setup.clock.sleeperCount

        await setup.gitLabFails()
        await setup.clock.waitForSleepers(sleepers + 1)
        #expect(setup.model.heldPipelineAlerts.count == 1)
        #expect(await setup.effects.inboxPanels.isEmpty)
        // Its entry is in the Inbox all the same.
        #expect(setup.model.inbox.pending.map(\.kind) == [.pipelineFailed])

        setup.clock.advance(by: .seconds(60))
        try await setup.jenkinsFails()
        #expect(setup.model.heldPipelineAlerts.count == 0)

        setup.clock.advance(by: HeldPipelineAlerts.grace)
        await setup.settle()
        #expect(await setup.effects.inboxPanels.isEmpty)
        #expect(await setup.effects.alertWindows.count == 1)
        #expect(setup.model.inbox.pending.map(\.kind) == [.buildFailed])
    }

    @Test("INBOX-17 GitLab's failed pipeline alone pops up when the two minutes are over, and not before")
    func noBuildComes() async throws {
        let setup = try Setup()
        // The model's own background waits start while the Inbox settles; count after them.
        await setup.settle()
        let sleepers = setup.clock.sleeperCount

        await setup.gitLabFails()
        await setup.clock.waitForSleepers(sleepers + 1)
        setup.clock.advance(by: HeldPipelineAlerts.grace - .seconds(1))
        await setup.settle()
        #expect(await setup.effects.inboxPanels.isEmpty)

        setup.clock.advance(by: .seconds(1))
        await setup.settle()
        #expect(await setup.effects.inboxPanels.map(\.kind) == [.pipelineFailed])
        #expect(setup.model.heldPipelineAlerts.count == 0)
        // A failed build that comes later is its own pop-up.
        try await setup.jenkinsFails()
        #expect(await setup.effects.alertWindows.count == 1)
    }

    @Test("INBOX-17 when the failed build came first, GitLab's failed pipeline never pops up")
    func buildFirst() async throws {
        let setup = try Setup()

        try await setup.jenkinsFails()
        await setup.gitLabFails()

        #expect(setup.model.heldPipelineAlerts.count == 0)
        setup.clock.advance(by: HeldPipelineAlerts.grace)
        await setup.settle()
        #expect(await setup.effects.inboxPanels.isEmpty)
        #expect(await setup.effects.alertWindows.count == 1)
        #expect(setup.model.inbox.pending.map(\.kind) == [.buildFailed])
    }
}

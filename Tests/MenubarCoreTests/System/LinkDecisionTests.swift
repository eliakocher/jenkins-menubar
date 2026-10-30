import Foundation
import Testing

@testable import MenubarCore

/// Where a link goes in an app that stays in itself (WIN-06, APP-09, the user's rule of 2026-10-30).
@Suite("LinkDecision")
@MainActor
struct LinkDecisionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var route: LinkRoute
        var option = false
        var listed = false
        var canOpen = true
        var decision: LinkDecision
        var testDescription: String { "\(route.kind) option \(option) listed \(listed) canOpen \(canOpen)" }
    }

    nonisolated static let build = LinkRoute.jenkinsBuild(project: .main, job: "MR-9", number: 3)
    nonisolated static let job = LinkRoute.jenkinsJob(project: .main, job: "MR-9")
    nonisolated static let mergeRequest = LinkRoute.mergeRequest(gitLabProject: "group/project", iid: 9)
    nonisolated static let workItem = LinkRoute.workItem(gitLabProject: "group/project", iid: 9)

    nonisolated static let cases: [Case] = [
        Case(route: build, listed: true, decision: .list),
        Case(route: build, decision: .opened),
        Case(route: build, canOpen: false, decision: .browser),
        Case(route: mergeRequest, listed: true, decision: .list),
        Case(route: mergeRequest, decision: .opened),
        Case(route: workItem, decision: .opened),
        Case(route: workItem, canOpen: false, decision: .browser),
        // A job has no build to open under "Opened": only the job of a list shows.
        Case(route: job, listed: true, decision: .list),
        Case(route: job, decision: .browser),
        // GitLab pipelines have no page in the app, and ⌥ sends everything to the browser.
        Case(route: .pipeline(gitLabProject: "group/project", id: 7), decision: .browser),
        Case(route: .browser, decision: .browser),
        Case(route: build, option: true, listed: true, decision: .browser),
        Case(route: mergeRequest, option: true, decision: .browser),
        Case(route: workItem, option: true, listed: true, decision: .browser),
    ]

    @Test("WIN-06 a link goes to its list, to Opened, or to the browser", arguments: cases)
    func decides(_ item: Case) {
        #expect(
            LinkDecision.decide(item.route, optionHeld: item.option, isListed: item.listed, canOpen: item.canOpen)
                == item.decision)
    }

    /// An app model on fakes, with the team values of `group/project` and the Jenkins job `project`.
    @MainActor
    private final class Setup {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let model: AppModel

        init() throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [
                TokenAccount.jenkins.rawValue: TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
            ])
            try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: TeamValues(
                    jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                    gitLabProject: "group/project")))
            stub.answer(body: "{}")
            stub.answer(path: "/job/project/api/json", body: #"{"jobs":[{"name":"MR-1","actions":[{"contributor":"jdoe"}]}]}"#)
            model = AppModel(
                dependencies: .fake(
                    root: folder.url, defaults: TemporaryDefaults().defaults, transport: stub, clock: TestClock(),
                    keychain: keychain, effects: FakeEffects(), reachability: FakeReachability()))
        }
    }

    @Test("WIN-06 a Jenkins build outside my lists opens under Opened, a listed one in Pipelines, a job or ⌥ in the browser")
    func buildDestinations() async throws {
        let setup = try Setup()
        let model = setup.model
        // MR-2 is watched, so its last build, number 3, is in Pipelines.
        setup.stub.answer(
            path: "/job/project/job/MR-2/api/json",
            body: #"{"actions":[{"objectDisplayName":"Title of MR-2"}],"lastBuild":{"number":3,"building":true,"timestamp":1792800000000}}"#)
        model.start()
        await model.pipelines.waitForChecks(1)
        _ = await model.pipelines.watch("!2")
        await model.pipelines.waitForChecks(2)
        #expect(model.pipelines.watchedBuilds.map(\.number) == [3])
        model.stop()

        // The listed build: its job in Pipelines. Another number of the same job is a build of its own.
        #expect(model.destination(for: .jenkinsBuild(project: .main, job: "MR-2", number: 3)) == .pipelines("MR-2"))
        #expect(model.destination(for: .jenkinsJob(project: .main, job: "MR-2")) == .pipelines("MR-2"))
        #expect(model.opened.items.isEmpty)
        guard case .opened(let id)? = model.destination(for: .jenkinsBuild(project: .main, job: "MR-2", number: 2)) else {
            Issue.record("expected an opened build")
            return
        }
        let item = try #require(model.opened.item(id))
        #expect(item.kind == .build && item.job == "MR-2" && item.iid == 2 && item.reference == "!2 #2")
        #expect(item.webURL.absoluteString == "https://jenkins.example.com/job/project/job/MR-2/2/")

        // The same build again is the same item; a job outside the lists and ⌥ never open one.
        #expect(model.destination(for: .jenkinsBuild(project: .main, job: "MR-2", number: 2)) == .opened(id))
        #expect(model.opened.items.count == 1)
        #expect(model.destination(for: .jenkinsJob(project: .main, job: "MR-7")) == nil)
        #expect(model.destination(for: .jenkinsBuild(project: .main, job: "MR-7", number: 1), optionHeld: true) == nil)
        #expect(model.destination(for: .jenkinsBuild(project: .main, job: "MR-2", number: 3), optionHeld: true) == nil)
        #expect(model.destination(for: .pipeline(gitLabProject: "group/project", id: 4)) == nil)
        #expect(model.opened.items.count == 1)

        // A merge request outside the lists opens under Opened too, and with ⌥ goes to the browser.
        let mergeRequest = LinkRoute.mergeRequest(gitLabProject: "group/other", iid: 5)
        #expect(model.destination(for: mergeRequest, optionHeld: true) == nil)
        guard case .opened? = model.destination(for: mergeRequest) else {
            Issue.record("expected an opened merge request")
            return
        }
    }
}

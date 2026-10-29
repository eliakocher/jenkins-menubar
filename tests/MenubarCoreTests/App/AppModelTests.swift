import Foundation
import Testing

@testable import MenubarCore

@Suite("AppModel")
@MainActor
struct AppModelTests {
    /// An app model on fakes: the stub transport, the test clock, an in-memory keychain and temporary files.
    @MainActor
    private final class Setup {
        static let rootPath = "/job/project"

        let folder: TemporaryFolder
        let defaults = TemporaryDefaults()
        let stub = StubTransport()
        let clock = TestClock()
        let network = FakeReachability()
        let effects = FakeEffects()
        let keychain: InMemoryKeychain
        let model: AppModel

        init(
            jenkinsToken: String? = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token"),
            gitLabToken: String? = nil
        ) throws {
            folder = try TemporaryFolder()
            var tokens: [String: String] = [:]
            tokens[TokenAccount.jenkins.rawValue] = jenkinsToken
            tokens[TokenAccount.gitlab.rawValue] = gitLabToken
            keychain = InMemoryKeychain(values: tokens)
            let team = TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                gitLabProject: "group/project")
            try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: team))
            stub.answer(body: "{}")
            stub.answer(
                path: Self.rootPath + "/api/json",
                body: #"{"jobs":[{"name":"MR-1","actions":[{"contributor":"jdoe"}]}]}"#)
            model = AppModel(
                dependencies: .fake(
                    root: folder.url, defaults: defaults.defaults, transport: stub, clock: clock, keychain: keychain,
                    effects: effects, reachability: network))
        }

        func jobListRequests() -> Int {
            stub.requests(path: Self.rootPath + "/api/json").count
        }

        func messages() async -> [String] {
            await model.log.entries().map(\.message)
        }
    }

    /// Waits until a condition holds, while the scheduler and the watchers run; `false` when it never did.
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for attempt in 0..<2000 {
            if await condition() {
                return true
            }
            if attempt < 100 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        return await condition()
    }

    @Test("AppModel builds from fakes and asks nothing before start")
    func asksNothingBeforeStart() async throws {
        let setup = try Setup()
        let model = setup.model

        #expect(!model.isStarted)
        #expect(!model.pipelines.hasLoaded)
        #expect(model.pipelines.project.team.jenkinsJobURL == "https://jenkins.example.com/job/project")
        await model.settled()
        #expect(setup.stub.requests.isEmpty)

        model.start()
        await model.pipelines.waitForChecks(1)

        #expect(model.isStarted)
        #expect(model.pipelines.hasLoaded)
        #expect(model.pipelines.state.myJobs == ["MR-1"])
        #expect(setup.jobListRequests() == 1)
        model.stop()
        await model.settled()
        #expect(await !model.scheduler.status.isStarted)
    }

    @Test("PIPE-07 check now starts a check at once, offline too")
    func checkNowOffline() async throws {
        let setup = try Setup()
        let model = setup.model
        model.start()
        await model.pipelines.waitForChecks(1)

        setup.network.set(reachable: false)
        #expect(await eventually { model.pipelines.isOffline })
        #expect(await eventually { await model.scheduler.status.isOffline })
        #expect(model.pipelines.problem == .offline)
        #expect(model.pipelines.showsProblemMarker)

        model.checkNow()
        await model.pipelines.waitForChecks(2)

        // Check now looks the jobs up again (PIPE-07).
        #expect(setup.jobListRequests() == 2)
        #expect(await eventually { await setup.messages().contains("Check now") })
        model.stop()
    }

    @Test("WATCH-01 watching starts a check through the scheduler")
    func watchingStartsACheck() async throws {
        let setup = try Setup()
        let model = setup.model
        model.start()
        await model.pipelines.waitForChecks(1)
        setup.stub.answer(
            path: Setup.rootPath + "/job/MR-2/api/json",
            body: #"{"actions":[{"objectDisplayName":"Title of MR-2"}],"lastBuild":{"number":3,"building":true,"timestamp":1792800000000}}"#)

        let outcome = await model.pipelines.watch("!2")
        await model.pipelines.waitForChecks(2)

        #expect(try outcome.get().message == "Watching all builds of !2")
        #expect(model.pipelines.watchedBuilds.map(\.id) == [BuildID(job: "MR-2", number: 3)])
        model.stop()
    }

    @Test("JERR-01 storing a token starts a check")
    func storingATokenStartsACheck() async throws {
        let setup = try Setup(jenkinsToken: nil)
        let model = setup.model
        model.start()
        await model.pipelines.waitForChecks(1)
        #expect(model.pipelines.problem == .noToken(.jenkins))
        #expect(setup.jobListRequests() == 0)

        #expect(await model.settings.saveJenkinsToken(user: "jdoe", apiToken: "secret-api-token"))
        await model.pipelines.waitForChecks(2)

        #expect(model.pipelines.problem == nil)
        #expect(model.pipelines.state.myJobs == ["MR-1"])
        #expect(setup.jobListRequests() == 1)
        model.stop()
    }

    @Test("PIPE-07 check now reloads the GitLab sections on screen")
    func checkNowReloadsGitLab() async throws {
        let setup = try Setup(gitLabToken: "glpat-example-token")
        let model = setup.model
        model.start()
        await model.pipelines.waitForChecks(1)
        await model.scheduler.setVisible([.mergeRequests])
        #expect(await eventually { setup.stub.requests(operation: "MergeRequests").count == 1 })

        model.checkNow()
        await model.pipelines.waitForChecks(2)

        #expect(await eventually { setup.stub.requests(operation: "MergeRequests").count == 2 })
        #expect(setup.stub.requests(operation: "WorkItems").isEmpty)
        model.stop()
    }

    @Test("WI-02 a change of the work item filters reloads them, other preferences don't")
    func filterChangeReloadsWorkItems() async throws {
        let setup = try Setup(gitLabToken: "glpat-example-token")
        setup.stub.answer(operation: "CurrentUser", body: #"{"data":{"currentUser":{"username":"jdoe"}}}"#)
        let model = setup.model
        model.start()
        await model.pipelines.waitForChecks(1)
        await model.scheduler.setVisible([.workItems])
        #expect(await eventually { setup.stub.requests(operation: "WorkItems").count == 1 })

        model.settings.preferences.hideSuccessfulAfter = .immediately
        await model.settled()
        #expect(model.pipelines.preferences.hideSuccessfulAfter == .immediately)
        #expect(setup.stub.requests(operation: "WorkItems").count == 1)

        model.settings.preferences.workItems.scope = .authored
        await model.settled()

        #expect(await eventually { setup.stub.requests(operation: "WorkItems").count == 2 })
        model.stop()
    }

    @Test("MR-04 removing the GitLab token in Settings discards the GitLab data")
    func removingTheGitLabToken() async throws {
        let setup = try Setup(gitLabToken: "glpat-example-token")
        let model = setup.model
        let list = MergeRequestList(username: "jdoe", mergeRequests: [])
        try model.caches.save(Cached(value: list, fetchedAt: Date()), as: .mergeRequestList, for: .main)
        await model.settings.loadTokens()

        await model.settings.removeToken(.gitlab)

        #expect(await setup.keychain.values[TokenAccount.gitlab.rawValue] == nil)
        #expect(model.caches.load(.mergeRequestList, for: .main) == nil)
        #expect(model.mergeRequests.problem == .noToken(.gitLab))
        #expect(model.workItems.problem == .noToken(.gitLab))
        model.stop()
    }

    @Test("IMP-01 the import's values and report reach the stores")
    func importFinished() async throws {
        let setup = try Setup()
        let model = setup.model
        var preferences = model.preferencesStore.load()
        preferences.hidesMergedBuilds = false
        _ = model.preferencesStore.save(preferences)
        try model.userStates.save(
            UserState(watched: [WatchedJob(job: "MR-2", label: "!2", added: Date())]), for: .main)
        let report = LegacyImportReport(date: Date())

        await model.importFinished(report)

        #expect(!model.pipelines.preferences.hidesMergedBuilds)
        #expect(model.pipelines.userState.watched.map(\.job) == ["MR-2"])
        #expect(model.settings.importReport == report)
        #expect(model.settings.storedTokens.contains(.jenkins))
    }

    @Test("OD-05 the network coming back clears the offline problem")
    func networkBack() async throws {
        let setup = try Setup()
        let model = setup.model
        setup.network.set(reachable: false)
        model.start()
        #expect(await eventually { model.pipelines.isOffline })

        setup.network.set(reachable: true)

        #expect(await eventually { !model.pipelines.isOffline })
        #expect(model.pipelines.problem != .offline)
        model.stop()
    }
}

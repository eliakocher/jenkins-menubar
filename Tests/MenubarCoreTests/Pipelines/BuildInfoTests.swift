import Foundation
import Testing

@testable import MenubarCore

@Suite("Build info")
struct BuildInfoTests {
    private static let jobURL = "https://jenkins.example.com/job/project"
    private static let token = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    private static let project = Project(
        id: .main,
        team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))

    private func client(_ stub: StubTransport) throws -> JenkinsClient {
        try JenkinsClient.make(project: Self.project, token: Self.token, transport: stub).get()
    }

    struct InfoCase: CustomTestStringConvertible, Sendable {
        var fixture: String
        var expected: BuildInfo
        var testDescription: String { fixture }
    }

    static let infoCases = [
        // A build of an agent: the node, the average, the first cause, the commit `marked` for the build (lower case), and the
        // parameters without the password's missing value and the run parameter.
        InfoCase(
            fixture: "build-info.json",
            expected: BuildInfo(
                parameters: [
                    BuildParameter(name: "TARGET_BRANCH", value: "release/8.x"),
                    BuildParameter(name: "SKIP_UI_TESTS", value: "false"),
                    BuildParameter(name: "EXTRA_ARGS", value: "-Dsuite=smoke & more"),
                ],
                commit: String(repeating: "a", count: 40), cause: "Started by user Jane Doe", node: "linux-agent-3",
                estimatedDuration: 540)),
        // A pipeline run: no node, no git action, no estimate (-1), the first of two causes.
        InfoCase(
            fixture: "build-info-pipeline.json",
            expected: BuildInfo(
                parameters: [
                    BuildParameter(name: "TARGET_BRANCH", value: "release/8.x"),
                    BuildParameter(name: "SKIP_UI_TESTS", value: "false"),
                    BuildParameter(name: "EXTRA_ARGS", value: "-Dsuite=smoke & more"),
                ], cause: "Started by GitLab push by Jane Doe")),
    ]

    @Test("PIPE-11 reads a build's parameters, commit, cause, node and expected duration", arguments: infoCases)
    func readsInfo(_ item: InfoCase) async throws {
        let stub = StubTransport()
        let path = "/job/project/job/MR-1/11/api/json"
        let info = try FixtureFiles.data("Jenkins/\(item.fixture)")
        let parameters = try FixtureFiles.data("Jenkins/build-parameters.json")
        stub.add(StubTransport.Route(matches: { $0.url.path(percentEncoded: true) == path }) {
            .success(HTTPResponse(status: 200, body: ($0.url.query(percentEncoded: true) ?? "").contains("parameters") ? parameters : info))
        })

        let result = try await client(stub).info(job: "MR-1", number: 11, repository: "team/product")

        #expect(result == item.expected)
    }

    @Test("PIPE-11 reads a job's last builds, running ones included, without a build number 0")
    func readsHistory() async throws {
        let stub = StubTransport()
        stub.answer(path: "/job/project/job/MR-1/api/json", body: try FixtureFiles.string("Jenkins/job-summaries.json"))

        let builds = try await client(stub).history(job: "MR-1")

        #expect(
            builds == [
                JobHistoryBuild(number: 13, result: nil, startedAt: Date(timeIntervalSince1970: 1_792_800_000)),
                JobHistoryBuild(number: 12, result: .failure, duration: 1900, startedAt: Date(timeIntervalSince1970: 1_792_790_000)),
                JobHistoryBuild(number: 11, result: .success, duration: 540, startedAt: Date(timeIntervalSince1970: 1_792_780_000)),
                JobHistoryBuild(number: 10, result: .aborted, duration: 62),
            ])
    }

    @Test(
        "PIPE-11 keeps the values of secret parameters out of the card",
        arguments: [("DEPLOY_PASSWORD", true), ("api-token", true), ("CLIENT_SECRET", true), ("TARGET_BRANCH", false)])
    func hidesSecrets(name: String, isSecret: Bool) {
        #expect(BuildInfo.isSecret(name) == isSecret)
    }
}

@Suite("BuildInfoStore")
@MainActor
struct BuildInfoStoreTests {
    private static let jobURL = "https://jenkins.example.com/job/project"
    private static let project = Project(
        id: .main,
        team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))
    private static let historyPath = "/job/project/job/MR-1/api/json"

    private static func build(running: Bool) -> Build {
        Build(
            job: "MR-1", number: 11, kind: .mine, phase: running ? .running : .finished(result: .success, duration: 540),
            startedAt: Date(timeIntervalSince1970: 1_792_780_000))
    }

    @MainActor
    private struct Harness {
        let stub = StubTransport()
        let store: BuildInfoStore
        let folder: TemporaryFolder

        init(token: String? = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")) throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            let team = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try team.save(BuildInfoStoreTests.project)
            let keychain = InMemoryKeychain(values: token.map { [TokenAccount.jenkins.rawValue: $0] } ?? [:])
            let services = PipelinesServices(
                transport: stub, clock: TestClock(), tokens: TokenStore(keychain: keychain), team: team,
                userStates: UserStateStore(folder: locations.applicationSupport, report: { _ in }),
                caches: CacheStore(folder: locations.caches, report: { _ in }), log: ActivityLog(folder: locations.logs),
                effects: FakeEffects())
            store = BuildInfoStore(services: services)
            let info = try FixtureFiles.data("Jenkins/build-info.json")
            let parameters = try FixtureFiles.data("Jenkins/build-parameters.json")
            stub.add(StubTransport.Route(matches: { $0.url.path(percentEncoded: true) == "/job/project/job/MR-1/11/api/json" }) {
                .success(HTTPResponse(status: 200, body: ($0.url.query(percentEncoded: true) ?? "").contains("parameters") ? parameters : info))
            })
            stub.answer(path: BuildInfoStoreTests.historyPath, body: try FixtureFiles.string("Jenkins/job-summaries.json"))
        }

        var historyRequests: Int { stub.requests(path: BuildInfoStoreTests.historyPath).count }
    }

    private static func isLoaded(_ store: BuildInfoStore, _ build: Build) -> Bool {
        if case .loaded = store.info(of: build.id), case .loaded = store.history(of: build.id) { return true }
        return false
    }

    @Test("PIPE-11 loads a build's info once, asks again when it has finished or a request failed, and asks nothing without a token")
    func loadingRules() async throws {
        let running = Self.build(running: true)
        let finished = Self.build(running: false)

        // Loaded once: a second selection asks nothing; the build finishing since asks again; then it is loaded again.
        let harness = try Harness()
        #expect(harness.store.info(of: running.id) == .loading)
        await harness.store.load(running)
        #expect(Self.isLoaded(harness.store, running))
        await harness.store.load(running)
        #expect(harness.historyRequests == 1)
        await harness.store.load(finished)
        #expect(Self.isLoaded(harness.store, finished))
        #expect(harness.historyRequests == 2)
        await harness.store.load(finished)
        #expect(harness.historyRequests == 2)

        // A failed request leaves its part failed and asks again at the next selection.
        let failing = try Harness()
        failing.stub.fail(path: Self.historyPath, times: 1, with: .cannotConnect)
        await failing.store.load(finished)
        #expect(failing.store.history(of: finished.id) == .failed)
        #expect(!Self.isLoaded(failing.store, finished))
        await failing.store.load(finished)
        #expect(Self.isLoaded(failing.store, finished))
        #expect(failing.historyRequests == 2)

        // Without a Jenkins token nothing is asked, and both fail quietly.
        let tokenless = try Harness(token: nil)
        await tokenless.store.load(finished)
        #expect(tokenless.store.info(of: finished.id) == .failed)
        #expect(tokenless.store.history(of: finished.id) == .failed)
        #expect(tokenless.stub.requests.isEmpty)
    }
}

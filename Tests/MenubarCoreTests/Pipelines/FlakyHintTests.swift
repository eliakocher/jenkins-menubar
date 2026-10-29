import Foundation
import Testing

@testable import MenubarCore

/// The made-up names of `Tests/Fixtures/Jenkins/`.
private enum Values {
    static let jobURL = "https://jenkins.example.com/job/project"
    static let root = "/job/project"
    static let token = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    static let project = Project(
        id: .main,
        team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))
    static let commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

private func stages(_ list: [(String, Stage.Status)]) -> [Stage] {
    list.map { Stage(name: $0.0, status: $0.1, duration: 60) }
}

private func run(_ number: Int, _ result: BuildResult, commit: String? = nil, _ list: [(String, Stage.Status)]? = nil) -> BuildRun {
    BuildRun(build: RecentBuild(number: number, result: result, commit: commit), stages: list.map(stages))
}

@Suite("FlakyRule")
struct FlakyRuleTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        /// the judged build #5, which failed these stages on commit `c1`
        var failed: [String] = ["tests"]
        var history: [BuildRun]
        var expected: [FlakyHint]
        var testDescription: String { name }
    }

    static let failedTests: [(String, Stage.Status)] = [("build", .success), ("tests", .failed)]

    static let cases: [Case] = [
        Case(
            name: "the stage passed on the same commit",
            history: [run(4, .success, commit: "c1")], expected: [.passedOnSameCommit(stage: "tests", build: 4)]),
        Case(
            name: "the newest build of the same commit that passed is named",
            history: [run(3, .success, commit: "c1"), run(4, .success, commit: "C1")],
            expected: [.passedOnSameCommit(stage: "tests", build: 4)]),
        Case(name: "the stage passed on another commit only: no hint", history: [run(4, .success, commit: "c0")], expected: []),
        Case(
            name: "every run failed: a real failure",
            history: [run(4, .failure, commit: "c0", failedTests), run(3, .failure, commit: "c0", failedTests)], expected: []),
        Case(name: "a first build has no history", history: [], expected: []),
        Case(
            name: "the same commit failed too, others passed: the count",
            history: [run(4, .failure, commit: "c1", failedTests), run(3, .success, commit: "c0")],
            expected: [.failedBefore(stage: "tests", failed: 2, of: 3)]),
        Case(
            name: "failed in three of five runs",
            history: [
                run(4, .failure, commit: "c0", failedTests), run(3, .success, commit: "c0"),
                run(2, .failure, commit: "c9", failedTests), run(1, .success, commit: "c9"),
            ], expected: [.failedBefore(stage: "tests", failed: 3, of: 5)]),
        Case(
            name: "a stage that failed only now is new, not flaky",
            history: [run(4, .success, commit: "c0"), run(3, .success, commit: "c0")], expected: []),
        Case(
            name: "an unstable stage on the same commit isn't a pass",
            history: [run(4, .unstable, commit: "c1", [("build", .success), ("tests", .unstable)]), run(3, .success, commit: "c0")],
            expected: [.failedBefore(stage: "tests", failed: 2, of: 3)]),
        Case(
            name: "a build without a commit can't prove a flake",
            history: [run(4, .success, commit: nil)], expected: []),
        Case(
            name: "an aborted run says nothing and isn't counted",
            history: [run(4, .aborted, commit: "c1", [("tests", .aborted)]), run(3, .failure, commit: "c0", failedTests)],
            expected: []),
        Case(
            name: "a stage not run on the same commit isn't a pass",
            history: [run(4, .failure, commit: "c1", [("build", .failed), ("tests", .notExecuted)])], expected: []),
        Case(
            name: "several failed stages: each is flaky on its own",
            failed: ["tests", "e2e", "deploy"],
            history: [
                run(4, .success, commit: "c1", [("tests", .success), ("e2e", .success), ("deploy", .success)]),
                run(3, .failure, commit: "c0", [("tests", .failed), ("e2e", .failed), ("deploy", .success)]),
            ],
            expected: [
                .passedOnSameCommit(stage: "tests", build: 4), .passedOnSameCommit(stage: "e2e", build: 4),
                .passedOnSameCommit(stage: "deploy", build: 4),
            ]),
        Case(
            name: "several failed stages with different verdicts",
            failed: ["e2e", "tests"],
            history: [
                run(4, .success, commit: "c1", [("tests", .success), ("e2e", .notExecuted)]),
                run(3, .failure, commit: "c0", [("tests", .success), ("e2e", .failed)]),
                run(2, .success, commit: "c0"),
            ],
            expected: [.passedOnSameCommit(stage: "tests", build: 4), .failedBefore(stage: "e2e", failed: 2, of: 4)]),
    ]

    @Test("PIPE-10 judges the failed stages by the recent runs", arguments: cases)
    func judges(_ item: Case) {
        let build = RecentBuild(number: 5, result: .failure, commit: "c1")
        // The failed stages of the judged build, the others passed.
        let stages = stages(item.failed.map { ($0, Stage.Status.failed) } + [("build", .success)])
        let history = [BuildRun(build: build, stages: stages)] + item.history

        #expect(FlakyRule.hints(for: build, stages: stages, history: history) == item.expected)
    }

    @Test("PIPE-10 looks at the last ten builds only")
    func window() {
        let build = RecentBuild(number: 12, result: .failure, commit: "c1")
        let stages = stages([("tests", .failed)])
        // #1 is the 12th build back: out of the window, even on the same commit.
        let history =
            [BuildRun(build: build, stages: stages)]
            + (2...11).map { run($0, .failure, commit: "c0", [("tests", .failed)]) } + [run(1, .success, commit: "c1")]

        #expect(FlakyRule.hints(for: build, stages: stages, history: history).isEmpty)
        #expect(FlakyRule.needingStages(for: build, in: history.map(\.build)) == Array((3...11).reversed()))
    }

    @Test("PIPE-10 a build that isn't in the history gets no hint")
    func unknownBuild() {
        let build = RecentBuild(number: 5, result: .failure, commit: "c1")
        #expect(FlakyRule.hints(for: build, stages: stages([("tests", .failed)]), history: [run(4, .success, commit: "c1")]).isEmpty)
    }

    @Test("PIPE-10 asks the stages of the failed builds and those of the same commit only")
    func needingStages() {
        let build = RecentBuild(number: 5, result: .failure, commit: "c1")
        let recent = [
            build, RecentBuild(number: 4, result: .success, commit: "c1"), RecentBuild(number: 3, result: .success, commit: "c0"),
            RecentBuild(number: 2, result: .unstable, commit: nil), RecentBuild(number: 1, result: .aborted, commit: "c1"),
        ]

        #expect(FlakyRule.needingStages(for: build, in: recent) == [4, 2])
    }
}

@Suite("Recent builds")
struct RecentBuildsTests {
    private func client(_ stub: StubTransport) throws -> JenkinsClient {
        try JenkinsClient.make(project: Values.project, token: Values.token, transport: stub).get()
    }

    private func stub() throws -> StubTransport {
        let stub = StubTransport()
        stub.answer(path: Values.root + "/job/MR-12/api/json", body: try FixtureFiles.string("Jenkins/job-builds-history.json"))
        return stub
    }

    @Test("PIPE-10 reads the recent builds with the commit each started from")
    func readsRecentBuilds() async throws {
        let stub = try stub()

        let builds = try await client(stub).recentBuilds(job: "MR-12", repository: "team/product")

        // The running #12 is left out. #11's library comes first, and the job's own repository wins; its upper-case SHA is
        // lowercased. #10's checked-out revision differs from its `marked`: `marked` counts. #7 has no entry for its
        // number, so the last built revision stands in; #6's actions say nothing.
        #expect(
            builds == [
                RecentBuild(number: 11, result: .failure, commit: Values.commit),
                RecentBuild(number: 10, result: .success, commit: Values.commit),
                RecentBuild(number: 9, result: .aborted, commit: nil),
                RecentBuild(number: 8, result: .unstable, commit: String(repeating: "b", count: 40)),
                RecentBuild(number: 7, result: .success, commit: String(repeating: "4", count: 40)),
                RecentBuild(number: 6, result: .failure, commit: nil),
            ])
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.headers == ["Authorization": "Basic \(Values.token)"])
        #expect(request.url.query(percentEncoded: false)?.hasPrefix("tree=builds[number,result,building,actions[") == true)
        #expect(request.url.query(percentEncoded: false)?.hasSuffix("]]{0,12}") == true)
    }

    @Test("PIPE-10 without the repository the first git action is taken")
    func firstActionWithoutRepository() async throws {
        let builds = try await client(try stub()).recentBuilds(job: "MR-12")

        #expect(builds.first?.commit == String(repeating: "9", count: 40))
    }

    @Test("PIPE-10 a failed request for the history is thrown")
    func failedRequest() async throws {
        let stub = StubTransport()
        stub.answer(path: Values.root + "/job/MR-12/api/json", status: 500, body: "")

        await #expect(throws: JenkinsError.self) { try await client(stub).recentBuilds(job: "MR-12") }
    }
}

@Suite("FlakyHintStore")
@MainActor
struct FlakyHintStoreTests {
    @MainActor
    private struct Harness {
        let stub = StubTransport()
        let store: FlakyHintStore
        let folder: TemporaryFolder

        init(token: String? = Values.token) throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            let team = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try team.save(Values.project)
            let keychain = InMemoryKeychain(values: token.map { [TokenAccount.jenkins.rawValue: $0] } ?? [:])
            let services = PipelinesServices(
                transport: stub, clock: TestClock(), tokens: TokenStore(keychain: keychain), team: team,
                userStates: UserStateStore(folder: locations.applicationSupport, report: { _ in }),
                caches: CacheStore(folder: locations.caches, report: { _ in }), log: ActivityLog(folder: locations.logs),
                effects: FakeEffects())
            store = FlakyHintStore(services: services)
        }

        func answerList() throws {
            stub.answer(path: Values.root + "/job/MR-12/api/json", body: try FixtureFiles.string("Jenkins/job-builds-history.json"))
        }

        func answerStages(_ number: Int, _ status: String) {
            stub.answer(
                path: "\(Values.root)/job/MR-12/\(number)/wfapi/describe",
                body: #"{"stages": [{"name": "tests", "status": "\#(status)", "durationMillis": 1000}]}"#)
        }

        var stageRequests: Int { stub.requests.filter { $0.url.path.hasSuffix("/wfapi/describe") }.count }
    }

    private static let failed = stages([("tests", .failed)])

    @Test("PIPE-10 loads the history once and keeps the stages for the next build")
    func loadsOnce() async throws {
        let harness = try Harness()
        try harness.answerList()
        harness.answerStages(10, "SUCCESS")
        harness.answerStages(8, "UNSTABLE")
        harness.answerStages(6, "FAILED")
        harness.answerStages(11, "FAILED")
        let store = harness.store
        let eleven = BuildID(job: "MR-12", number: 11)

        #expect(store.state(of: eleven) == .loading)
        await store.load(eleven, stages: Self.failed)
        await store.load(eleven, stages: Self.failed)

        // #11 passed on its commit in #10.
        #expect(store.state(of: eleven) == .loaded([.passedOnSameCommit(stage: "tests", build: 10)]))
        // The list, and the stages of #10 (same commit), #8 (unstable) and #6 (failed): no more for a second selection.
        #expect(harness.stub.requests.count == 4)

        // #8 needs #11 and #6, which are known: the list is the only new request.
        await store.load(BuildID(job: "MR-12", number: 8), stages: stages([("tests", .unstable)]))
        #expect(harness.stub.requests.count == 5)
        #expect(harness.stageRequests == 3)
        // #8 failed in #8, #11 and #6, and passed in #10 and #7: three of the five runs.
        #expect(
            store.state(of: BuildID(job: "MR-12", number: 8)) == .loaded([.failedBefore(stage: "tests", failed: 3, of: 5)]))
    }

    @Test("PIPE-10 a failed request leaves the hint out and asks again at the next selection")
    func failedLoadAsksAgain() async throws {
        let harness = try Harness()
        try harness.answerList()
        harness.answerStages(10, "SUCCESS")
        harness.answerStages(8, "UNSTABLE")
        harness.answerStages(6, "FAILED")
        // The newest route answers first: #6's stages fail once, and the hint is left out rather than judged on half the
        // history.
        harness.stub.answer(path: Values.root + "/job/MR-12/6/wfapi/describe", times: 1, status: 500, body: "")
        let store = harness.store
        let eleven = BuildID(job: "MR-12", number: 11)

        await store.load(eleven, stages: Self.failed)
        #expect(store.state(of: eleven) == .failed)

        await store.load(eleven, stages: Self.failed)
        #expect(store.state(of: eleven) == .loaded([.passedOnSameCommit(stage: "tests", build: 10)]))
    }

    @Test("PIPE-10 a build without a failed stage asks nothing, and so does one without a token")
    func asksNothing() async throws {
        let harness = try Harness(token: nil)
        let eleven = BuildID(job: "MR-12", number: 11)

        await harness.store.load(eleven, stages: Self.failed)
        #expect(harness.store.state(of: eleven) == .failed)

        let ten = BuildID(job: "MR-12", number: 10)
        await harness.store.load(ten, stages: stages([("tests", .success)]))
        #expect(harness.store.state(of: ten) == .loaded([]))
        #expect(harness.stub.requests.isEmpty)
    }
}

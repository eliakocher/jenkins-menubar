import Foundation
import Testing

@testable import MenubarCore

@Suite("JenkinsCheck")
struct JenkinsCheckTests {
    /// A check against the stub transport, with a time of its own and a temporary log.
    private final class Harness: @unchecked Sendable {
        static let jobURL = "https://jenkins.example.com/jenkins/job/GitLab%20Team/job/team%252Fproduct"
        static let rootPath = "/jenkins/job/GitLab%20Team/job/team%252Fproduct"
        /// the Jenkins user is `jenkins-jdoe`, the GitLab user `jdoe`
        static let token = TokenStore.jenkinsToken(user: "jenkins-jdoe", apiToken: "secret-api-token")
        static let project = Project(
            id: .main,
            team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))
        static let start = Date(timeIntervalSince1970: 1_792_800_000)

        let stub: StubTransport
        let folder: TemporaryFolder
        let log: ActivityLog
        private let lock = NSLock()
        private var time = Harness.start
        private var counted = 0

        init(clock: TestClock = TestClock()) throws {
            stub = StubTransport(clock: clock)
            folder = try TemporaryFolder()
            log = ActivityLog(folder: folder.url)
            // What a test doesn't route answers `{}`: a job without builds, no stages, no test report. The tests check
            // the requests themselves.
            stub.answer(body: "{}")
        }

        var now: Date {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }

        func wait(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }

        var check: JenkinsCheck {
            JenkinsCheck(transport: stub, log: log, now: { [unowned self] in now })
        }

        func run(
            _ state: JenkinsState,
            watched: [String] = [],
            gitLabUsername: String? = "jdoe",
            token: String? = Harness.token,
            lookUpJobs: Bool = false
        ) async throws -> JenkinsCheckResult {
            let userState = UserState(watched: watched.map { WatchedJob(job: $0, label: Build.label(forJob: $0), added: Self.start) })
            return try await check.run(
                project: Self.project, userState: userState, token: token, gitLabUsername: gitLabUsername, state: state,
                lookUpJobs: lookUpJobs)
        }

        /// the paths asked since the last call, relative to the job URL
        func newRequests() -> [String] {
            let requests = stub.requests
            defer { counted = requests.count }
            return requests.dropFirst(counted).map { String($0.url.path(percentEncoded: true).dropFirst(Self.rootPath.count)) }
        }

        func answerJobs(_ jobs: [(String, String?)]) {
            let list = jobs.map { name, contributor in
                ["name": name, "actions": [[:], contributor.map { ["contributor": $0] } ?? [:]]] as [String: Any]
            }
            stub.answer(path: Self.rootPath + "/api/json", body: Self.json(["jobs": list]))
        }

        func answerJobs(fixture: String) throws {
            stub.answer(path: Self.rootPath + "/api/json", body: try FixtureFiles.string("Jenkins/\(fixture)"))
        }

        /// Answers a job with its last build, started `startedAgo` seconds before now.
        func answer(
            _ job: String,
            number: Int,
            result: String? = "SUCCESS",
            startedAgo: TimeInterval = 3600,
            times: Int? = nil
        ) {
            let lastBuild: [String: Any] = [
                "number": number, "building": result == nil, "result": result ?? NSNull(),
                "timestamp": (now.timeIntervalSince1970 - startedAgo) * 1000, "estimatedDuration": 1_800_000,
                "duration": result == nil ? 0 : 1_800_000,
            ]
            let actions: [[String: Any]] = [
                [:], ["objectDisplayName": "Title of \(job)", "objectUrl": "https://gitlab.example.com/team/product/-/merge_requests/1"],
                ["contributorDisplayName": "Jane Doe"],
            ]
            stub.answer(path: Self.rootPath + "/job/\(job)/api/json", times: times, body: Self.json(["actions": actions, "lastBuild": lastBuild]))
        }

        func answer(_ job: String, fixture: String) throws {
            stub.answer(path: Self.rootPath + "/job/\(job)/api/json", body: try FixtureFiles.string("Jenkins/\(fixture)"))
        }

        func answerStages(_ job: String, _ number: Int, _ stages: [(String, String)]) {
            let list = stages.map { ["name": $0.0, "status": $0.1, "durationMillis": 60000] as [String: Any] }
            stub.answer(path: Self.rootPath + "/job/\(job)/\(number)/wfapi/describe", body: Self.json(["stages": list]))
        }

        func path(_ suffix: String) -> String {
            Self.rootPath + suffix
        }

        /// A state whose job lookup is a minute old.
        func state(myJobs: [String], builds: [Build] = []) -> JenkinsState {
            JenkinsState(
                me: "jdoe", myJobs: myJobs, jobsLookedUpAt: now.addingTimeInterval(-60), builds: builds,
                checkedAt: now.addingTimeInterval(-60))
        }

        func build(_ job: String, number: Int, result: BuildResult? = .success, kind: JobKind = .mine) -> Build {
            Build(
                job: job, number: number, title: "Cached \(job)", kind: kind,
                phase: result.map { .finished(result: $0, duration: 1800) } ?? .running,
                startedAt: now.addingTimeInterval(-7200))
        }

        static func json(_ value: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
    }

    // MARK: PIPE-01

    @Test("PIPE-01 finds my jobs by my GitLab username")
    func findsMyJobs() async throws {
        let harness = try Harness()
        try harness.answerJobs(fixture: "jobs.json")
        try harness.answer("MR-1", fixture: "job-finished.json")
        try harness.answer("MR-3", fixture: "job-finished.json")

        let result = try await harness.run(JenkinsState())

        // MR-4's contributor is JDoe: the match is case-sensitive.
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json", "/job/MR-3/api/json"])
        #expect(result.state.myJobs == ["MR-1", "MR-3"])
        #expect(result.state.me == "jdoe")
        #expect(result.state.jobsLookedUpAt == harness.now)
        #expect(result.problem == nil && result.succeeded)
        let build = try #require(result.builds.first)
        #expect(result.builds.map(\.job) == ["MR-1", "MR-3"])
        #expect(build == Build(
            job: "MR-1", number: 2, title: #"#4711: Resolve "Update the reporting API version""#,
            gitLabURL: URL(string: "https://gitlab.example.com/team/product/-/merge_requests/1"), author: "Jane Doe",
            kind: .mine, phase: .finished(result: .success, duration: 25918.271),
            startedAt: Date(timeIntervalSince1970: 1_792_766_894.204), estimatedDuration: 25918.271))
        let found = try #require(await harness.log.entries().first)
        #expect(found.message == "Found 2 MR jobs of jdoe")
        #expect(found.detail == "MR-1 MR-3")
        #expect(found.level == .debug && found.source == .jenkins)
    }

    @Test("PIPE-01 uses the Jenkins user until GitLab answers")
    func usesTheJenkinsUser() async throws {
        let harness = try Harness()
        harness.answerJobs([("MR-1", "jenkins-jdoe"), ("MR-2", "jdoe")])
        harness.answer("MR-1", number: 4)

        let result = try await harness.run(JenkinsState(), gitLabUsername: nil)

        #expect(result.state.me == "jenkins-jdoe")
        #expect(result.state.myJobs == ["MR-1"])
        #expect(result.builds.map(\.job) == ["MR-1"])
    }

    @Test("PIPE-01 looks the jobs up again after 10 minutes")
    func looksUpAfterTenMinutes() async throws {
        let harness = try Harness()
        harness.answerJobs([("MR-1", "jdoe")])
        harness.answer("MR-1", number: 4)

        var state = try await harness.run(JenkinsState()).state
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
        harness.wait(599)
        state = try await harness.run(state).state
        #expect(harness.newRequests() == ["/job/MR-1/api/json"])
        harness.wait(1)
        state = try await harness.run(state).state
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
        // Check now looks them up at once (PIPE-07).
        harness.wait(30)
        _ = try await harness.run(state, lookUpJobs: true)
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
    }

    @Test("PIPE-01 looks the jobs up again when the user changes")
    func looksUpWhenTheUserChanges() async throws {
        let harness = try Harness()
        harness.answerJobs([("MR-1", "jenkins-jdoe"), ("MR-2", "jdoe")])
        harness.answer("MR-1", number: 4)
        harness.answer("MR-2", number: 9)

        let first = try await harness.run(JenkinsState(), gitLabUsername: nil)
        harness.wait(60)
        let second = try await harness.run(first.state, gitLabUsername: "jdoe")

        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json", "/api/json", "/job/MR-2/api/json"])
        #expect(second.state.me == "jdoe")
        #expect(second.builds.map(\.job) == ["MR-2"])
    }

    @Test("PIPE-01 sends no request for other people's jobs")
    func asksOnlyForMyJobs() async throws {
        let harness = try Harness()
        try harness.answerJobs(fixture: "jobs.json")
        harness.answer("MR-1", number: 1)
        harness.answer("MR-3", number: 1)
        harness.answer("MR-5", number: 1)

        _ = try await harness.run(JenkinsState(), watched: ["MR-5"])

        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json", "/job/MR-3/api/json", "/job/MR-5/api/json"])
    }

    @Test("PIPE-01 skips a job without builds")
    func skipsJobsWithoutBuilds() async throws {
        let harness = try Harness()
        harness.answerJobs([("MR-1", "jdoe"), ("MR-2", "jdoe"), ("MR-3", "jdoe")])
        try harness.answer("MR-1", fixture: "job-without-build.json")
        harness.stub.answer(path: harness.path("/job/MR-2/api/json"), body: #"{"actions": [], "lastBuild": {"number": 0}}"#)
        harness.answer("MR-3", number: 5)

        let result = try await harness.run(JenkinsState())

        #expect(result.builds.map(\.job) == ["MR-3"])
        #expect(result.state.myJobs == ["MR-1", "MR-2", "MR-3"])
        #expect(result.problem == nil)
    }

    // MARK: PIPE-04 and the facts of a finished build

    @Test("PIPE-04 asks for the stages of a finished build only once")
    func stagesOfFinishedBuildsOnce() async throws {
        let harness = try Harness()
        let state = harness.state(myJobs: ["MR-1", "MR-3"])
        harness.answer("MR-1", number: 7, result: "FAILURE")
        harness.stub.answer(path: harness.path("/job/MR-1/7/wfapi/describe"), body: try FixtureFiles.string("Jenkins/describe-failed.json"))
        harness.answer("MR-3", number: 2, result: nil)
        harness.answerStages("MR-3", 2, [("build", "IN_PROGRESS")])

        let first = try await harness.run(state)
        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-1/7/wfapi/describe", "/job/MR-3/api/json", "/job/MR-3/2/wfapi/describe"])
        let failed = try #require(first.builds.first { $0.job == "MR-1" })
        #expect(failed.failedStages == ["unit-tests", "integration-tests"])
        #expect(failed.stages?.map(\.status) == [.success, .failed, .failed, .notExecuted])
        #expect(failed.stages?.first?.duration == 412)

        // MR-3 finishes as FAILURE: one request for its stages when it is seen finished, then none.
        harness.answer("MR-3", number: 2, result: "FAILURE")
        harness.answerStages("MR-3", 2, [("build", "FAILED")])
        let second = try await harness.run(first.state)
        #expect(harness.newRequests().filter { $0.hasSuffix("wfapi/describe") } == ["/job/MR-3/2/wfapi/describe"])
        let third = try await harness.run(second.state)
        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-3/api/json"])
        #expect(third.builds.first { $0.job == "MR-3" }?.failedStages == ["build"])
        #expect(third.builds.first { $0.job == "MR-1" }?.failedStages == ["unit-tests", "integration-tests"])
    }

    @Test("PIPE-04 asks for no stages of a successful build")
    func noStagesOfSuccessfulBuilds() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 7, result: "SUCCESS")
        harness.answer("MR-3", number: 2, result: "ABORTED")
        harness.answer("MR-4", number: 2, result: "NOT_BUILT")
        harness.answer("MR-5", number: 3, result: nil)
        harness.answerStages("MR-5", 3, [("build", "IN_PROGRESS")])

        let first = try await harness.run(harness.state(myJobs: ["MR-1", "MR-3", "MR-4", "MR-5"]))
        #expect(harness.newRequests().filter { $0.hasSuffix("wfapi/describe") } == ["/job/MR-5/3/wfapi/describe"])
        #expect(first.builds.filter { $0.job != "MR-5" }.allSatisfy { $0.stages == nil })

        // A running build that finishes as SUCCESS costs no stages request either.
        harness.answer("MR-5", number: 3, result: "SUCCESS")
        _ = try await harness.run(first.state)
        #expect(harness.newRequests().filter { $0.hasSuffix("wfapi/describe") }.isEmpty)
    }

    @Test("PIPE-04 asks for the stages of a running build every check")
    func stagesOfRunningBuildsEveryCheck() async throws {
        let harness = try Harness()
        try harness.answer("MR-1", fixture: "job-running.json")
        harness.stub.answer(path: harness.path("/job/MR-1/3/wfapi/describe"), body: try FixtureFiles.string("Jenkins/describe-running.json"))

        var state = harness.state(myJobs: ["MR-1"])
        for _ in 1...3 {
            let result = try await harness.run(state)
            state = result.state
            let build = try #require(result.builds.first)
            #expect(build.isRunning && build.number == 3)
            #expect(build.estimatedDuration == 25918.271)
            #expect(build.runningStages == ["unit-tests", "integration-tests"])
            #expect(build.failedStages == [])
        }
        #expect(harness.stub.requests(path: harness.path("/job/MR-1/3/wfapi/describe")).count == 3)
    }

    @Test("PIPE-04 keeps the last failed stages when the request fails")
    func keepsTheLastFailedStages() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerStages("MR-1", 7, [("build", "FAILED"), ("tests", "IN_PROGRESS")])
        let first = try await harness.run(harness.state(myJobs: ["MR-1"]))
        #expect(first.builds.first?.failedStages == ["build"])

        harness.stub.answer(path: harness.path("/job/MR-1/7/wfapi/describe"), status: 500)
        let second = try await harness.run(first.state)
        #expect(second.builds.first?.stages == first.builds.first?.stages)
        #expect(second.problem == nil)

        // A new build starts with no stages known.
        harness.answer("MR-1", number: 8, result: nil)
        harness.stub.answer(path: harness.path("/job/MR-1/8/wfapi/describe"), status: 500)
        let third = try await harness.run(second.state)
        #expect(third.builds.first?.number == 8)
        #expect(third.builds.first?.stages == nil)
    }

    @Test("PIPE-03 shows the failed test counts")
    func fetchesTestCountsOnceWhenFinished() async throws {
        let harness = try Harness()
        let counts = harness.path("/job/MR-1/7/api/json")
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerStages("MR-1", 7, [("build", "IN_PROGRESS")])
        harness.stub.answer(path: counts, body: try FixtureFiles.string("Jenkins/test-counts.json"))

        let running = try await harness.run(harness.state(myJobs: ["MR-1"]))
        #expect(harness.stub.requests(path: counts).isEmpty)

        harness.answer("MR-1", number: 7, result: "UNSTABLE")
        let finished = try await harness.run(running.state)
        #expect(finished.builds.first?.testCounts == TestCounts(failed: 3, total: 1200))
        #expect(harness.stub.requests(path: counts).map { $0.url.query(percentEncoded: true) } == ["tree=actions%5BfailCount,totalCount%5D"])

        let again = try await harness.run(finished.state)
        #expect(again.builds.first?.testCounts == TestCounts(failed: 3, total: 1200))
        #expect(harness.stub.requests(path: counts).count == 1)

        // A build that started and finished between two checks gets its counts too; one first seen finished doesn't,
        // nor one that started before the check before.
        harness.wait(60)
        harness.answer("MR-1", number: 8, result: "SUCCESS", startedAgo: 30)
        harness.stub.answer(path: harness.path("/job/MR-1/8/api/json"), body: try FixtureFiles.string("Jenkins/test-counts-none.json"))
        harness.answer("MR-3", number: 4, result: "FAILURE")
        harness.answerStages("MR-3", 4, [("build", "FAILED")])
        harness.answer("MR-4", number: 3, result: "SUCCESS", startedAgo: 3600)
        var state = again.state
        state.myJobs = ["MR-1", "MR-3", "MR-4"]
        state.builds.append(harness.build("MR-4", number: 2))
        _ = try await harness.run(state)
        #expect(harness.stub.requests(path: harness.path("/job/MR-1/8/api/json")).count == 1)
        #expect(harness.stub.requests(path: harness.path("/job/MR-3/4/api/json")).isEmpty)
        #expect(harness.stub.requests(path: harness.path("/job/MR-4/3/api/json")).isEmpty)
    }

    // MARK: ALERT-06, the newer build after an aborted one

    @Test("ALERT-06 follows the newer build when the build was aborted")
    func followsTheNewerBuild() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerStages("MR-1", 7, [("build", "IN_PROGRESS")])
        let first = try await harness.run(harness.state(myJobs: ["MR-1"]))
        _ = harness.newRequests()

        harness.answer("MR-1", number: 8, result: nil, startedAgo: 10)
        harness.answer("MR-1", number: 7, result: "ABORTED", times: 1)
        harness.answerStages("MR-1", 8, [("build", "IN_PROGRESS")])
        let second = try await harness.run(first.state)

        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-1/api/json", "/job/MR-1/8/wfapi/describe"])
        #expect(second.builds.map(\.id) == [BuildID(job: "MR-1", number: 8)])
        #expect(second.builds.first?.isRunning == true)
        #expect(second.previousBuilds.map(\.id) == [BuildID(job: "MR-1", number: 7)])
    }

    @Test("ALERT-06 alerts an aborted build without a newer one")
    func keepsAnAbortedBuild() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerStages("MR-1", 7, [("build", "IN_PROGRESS")])
        let first = try await harness.run(harness.state(myJobs: ["MR-1"]))
        _ = harness.newRequests()

        harness.answer("MR-1", number: 7, result: "ABORTED")
        harness.stub.answer(path: harness.path("/job/MR-1/7/api/json"), body: try FixtureFiles.string("Jenkins/test-counts-none.json"))
        let second = try await harness.run(first.state)

        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-1/api/json", "/job/MR-1/7/api/json"])
        #expect(second.builds.first?.result == .aborted)
        #expect(second.builds.first?.number == 7)
    }

    // MARK: JERR

    @Test("JERR-01 reports a missing Jenkins token without requests")
    func noToken() async throws {
        let harness = try Harness()
        let state = harness.state(myJobs: ["MR-1"], builds: [harness.build("MR-1", number: 3)])

        for token in [nil, ""] {
            let result = try await harness.run(state, token: token)
            #expect(result.problem == .noToken(.jenkins))
            #expect(result.problem?.message == "No Jenkins token: add it in Settings → Accounts")
            // Nothing to back off from: Jenkins wasn't asked.
            #expect(result.succeeded)
            #expect(result.state == state)
        }
        #expect(harness.stub.requests.isEmpty)
    }

    @Test("JERR-02 reports a rejected token for the job list")
    func rejectedForTheJobList() async throws {
        for status in [401, 403] {
            let harness = try Harness()
            harness.stub.answer(path: harness.path("/api/json"), status: status, body: try FixtureFiles.string("Jenkins/error-401.html"))

            let result = try await harness.run(JenkinsState())

            #expect(result.problem == .rejectedToken(.jenkins))
            #expect(result.problem?.message == "Jenkins rejected the token")
            #expect(harness.newRequests() == ["/api/json"])
        }
    }

    @Test("JERR-02 reports a rejected token for the builds and keeps them")
    func rejectedForTheBuilds() async throws {
        let harness = try Harness()
        let cached = [harness.build("MR-1", number: 3), harness.build("MR-3", number: 5)]
        var state = harness.state(myJobs: ["MR-1", "MR-3"], builds: cached)
        state.jobsLookedUpAt = harness.now.addingTimeInterval(-3600)
        harness.stub.answer(status: 401, body: try FixtureFiles.string("Jenkins/error-401.html"))

        let result = try await harness.run(state)

        // With a cached list, the builds are still asked for.
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json", "/job/MR-3/api/json"])
        #expect(result.problem == .rejectedToken(.jenkins))
        #expect(result.succeeded)
        #expect(result.builds == cached)
        #expect(result.state.checkedAt == state.checkedAt)
    }

    @Test("JERR-03 reports an unknown job URL")
    func unknownJobURL() async throws {
        let harness = try Harness()
        harness.stub.answer(path: harness.path("/api/json"), status: 404, body: try FixtureFiles.string("Jenkins/error-404.html"))

        let result = try await harness.run(JenkinsState())

        #expect(result.problem == .unknownJob)
        #expect(result.problem?.message == "Jenkins does not know the job: check the job URL in Team")
    }

    @Test("JERR-04 drops the build of a removed job without a problem")
    func dropsRemovedJobs() async throws {
        let harness = try Harness()
        let state = harness.state(
            myJobs: ["MR-1", "MR-3"],
            builds: [harness.build("MR-1", number: 3), harness.build("MR-3", number: 5), harness.build("MR-5", number: 2, kind: .watched)])
        harness.stub.answer(path: harness.path("/job/MR-1/api/json"), status: 404, body: try FixtureFiles.string("Jenkins/error-404.html"))
        harness.stub.answer(path: harness.path("/job/MR-5/api/json"), status: 404)
        harness.answer("MR-3", number: 6)

        let result = try await harness.run(state, watched: ["MR-5"])

        #expect(result.builds.map(\.id) == [BuildID(job: "MR-3", number: 6)])
        #expect(result.problem == nil)
        #expect(result.droppedWatchedJobs == ["MR-5"])
        #expect(result.state.myJobs == ["MR-3"])
    }

    @Test("JERR-05 stops asking Jenkins once it is unreachable")
    func stopsOnceUnreachable() async throws {
        for error in [TransportError.noConnection(within: .seconds(5)), .noAnswer(within: .seconds(20)), .unknownHost, .cannotConnect, .other("TLS")] {
            let harness = try Harness()
            let cached = [harness.build("MR-1", number: 3), harness.build("MR-3", number: 5), harness.build("MR-5", number: 2, kind: .watched)]
            let state = harness.state(myJobs: ["MR-1", "MR-3"], builds: cached)
            harness.stub.fail(with: error)

            let result = try await harness.run(state, watched: ["MR-5"])

            #expect(harness.newRequests() == ["/job/MR-1/api/json"], "\(error)")
            #expect(result.problem == .unreachable(.jenkins))
            #expect(result.problem?.message == "Jenkins unreachable (VPN?)")
            #expect(!result.succeeded)
            #expect(result.builds == cached)
        }
    }

    @Test("JERR-05 asks for no builds when the job list is unreachable")
    func noBuildsWhenTheListIsUnreachable() async throws {
        let harness = try Harness()
        let cached = [harness.build("MR-1", number: 3)]
        var state = harness.state(myJobs: ["MR-1"], builds: cached)
        state.jobsLookedUpAt = nil
        harness.stub.fail(path: harness.path("/api/json"), with: .noConnection(within: .seconds(5)))

        let result = try await harness.run(state)
        #expect(harness.newRequests() == ["/api/json"])
        #expect(result.problem == .unreachable(.jenkins))
        #expect(result.builds == cached)

        // Without a cached job list, only the problem shows.
        let first = try await harness.run(JenkinsState(), watched: ["MR-5"])
        #expect(harness.newRequests() == ["/api/json"])
        #expect(first.problem == .unreachable(.jenkins))
        #expect(first.builds.isEmpty)
    }

    @Test("JERR-05 keeps the cached builds while unreachable")
    func keepsCachedBuildsWhileUnreachable() async throws {
        let harness = try Harness()
        let cached = [harness.build("MR-1", number: 3, result: nil), harness.build("MR-3", number: 5)]
        harness.answer("MR-1", number: 3, result: nil)
        harness.stub.fail(path: harness.path("/job/MR-1/3/wfapi/describe"), with: .noAnswer(within: .seconds(20)))
        harness.answer("MR-3", number: 6)

        // The stages request doesn't answer either: nothing more is asked.
        let result = try await harness.run(harness.state(myJobs: ["MR-1", "MR-3"], builds: cached))

        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-1/3/wfapi/describe"])
        #expect(result.problem == .unreachable(.jenkins))
        #expect(result.builds.map(\.id) == cached.map(\.id))
        #expect(result.builds.last == cached.last)
    }

    @Test("JERR-06 asks for the builds when the job list is too slow")
    func slowJobList() async throws {
        let clock = TestClock()
        let harness = try Harness(clock: clock)
        var state = harness.state(myJobs: ["MR-1"], builds: [harness.build("MR-1", number: 3)])
        state.jobsLookedUpAt = harness.now.addingTimeInterval(-700)
        harness.stub.answer(path: harness.path("/api/json"), after: .seconds(61), body: #"{"jobs": []}"#)
        harness.answer("MR-1", number: 4)

        let check = Task { try await harness.run(state) }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(60))
        let result = try await check.value

        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
        #expect(result.problem == nil)
        #expect(result.builds.map(\.number) == [4])
        #expect(result.state.myJobs == ["MR-1"])
        let slow = try #require(await harness.log.entries().first)
        #expect(slow.message == "The list of MR jobs took too long: the builds of the last list are checked")
        #expect(slow.level == .warning && slow.outcome == .warning("SLOW"))
    }

    @Test("JERR-06 waits 10 minutes before the next lookup")
    func slowJobListWaits() async throws {
        let harness = try Harness()
        var state = harness.state(myJobs: ["MR-1"])
        state.jobsLookedUpAt = harness.now.addingTimeInterval(-3600)
        harness.stub.fail(path: harness.path("/api/json"), with: .noAnswer(within: .seconds(60)))
        harness.answer("MR-1", number: 4)

        state = try await harness.run(state).state
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
        harness.wait(60)
        state = try await harness.run(state).state
        #expect(harness.newRequests() == ["/job/MR-1/api/json"])
        harness.wait(540)
        _ = try await harness.run(state)
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
    }

    @Test("JERR-06 reports unreachable without an old list")
    func slowJobListWithoutAnOldList() async throws {
        let harness = try Harness()
        harness.stub.fail(path: harness.path("/api/json"), with: .noAnswer(within: .seconds(60)))

        let result = try await harness.run(JenkinsState(), watched: ["MR-5"])

        #expect(harness.newRequests() == ["/api/json"])
        #expect(result.problem == .unreachable(.jenkins))
    }

    @Test("JERR-08 keeps a build while Jenkins fails for its job")
    func keepsABuildWhileItsJobFails() async throws {
        let harness = try Harness()
        let cached = [harness.build("MR-1", number: 3), harness.build("MR-3", number: 5)]
        harness.stub.answer(path: harness.path("/job/MR-1/api/json"), status: 500, body: try FixtureFiles.string("Jenkins/error-500.html"))
        harness.answer("MR-3", number: 6)

        let result = try await harness.run(harness.state(myJobs: ["MR-1", "MR-3"], builds: cached))

        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-3/api/json"])
        #expect(result.builds.first { $0.job == "MR-1" } == cached[0])
        #expect(result.builds.first { $0.job == "MR-3" }?.number == 6)
        #expect(result.problem == nil)
    }

    @Test("JERR-08 reports the HTTP status when no job answered")
    func reportsTheStatusWhenNoJobAnswered() async throws {
        let harness = try Harness()
        let cached = [harness.build("MR-1", number: 3), harness.build("MR-3", number: 5)]
        harness.stub.answer(path: harness.path("/job/MR-1/api/json"), status: 500)
        harness.stub.answer(path: harness.path("/job/MR-3/api/json"), status: 502)

        let result = try await harness.run(harness.state(myJobs: ["MR-1", "MR-3"], builds: cached))

        #expect(result.problem == .httpStatus(.jenkins, status: 502))
        #expect(result.problem?.message == "Jenkins answered with HTTP 502")
        #expect(result.builds == cached)

        // An answer that isn't the JSON asked for has a problem of its own.
        harness.stub.answer(path: harness.path("/job/MR-9/api/json"), body: "<html>Sign in</html>")
        let client = try JenkinsClient.make(project: Harness.project, token: Harness.token, transport: harness.stub).get()
        await #expect(throws: JenkinsError(.notJSON)) {
            try await client.job("MR-9")
        }
    }

    @Test("JERR-08 asks for the builds when the job list fails with a cached list")
    func asksForBuildsWhenTheListFails() async throws {
        let harness = try Harness()
        var state = harness.state(myJobs: ["MR-1"], builds: [harness.build("MR-1", number: 3)])
        state.jobsLookedUpAt = harness.now.addingTimeInterval(-3600)
        harness.stub.answer(path: harness.path("/api/json"), status: 500)
        harness.answer("MR-1", number: 4)

        let result = try await harness.run(state)
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
        #expect(result.problem == nil)
        #expect(result.builds.map(\.number) == [4])

        // Unlike a slow list, a failed one is asked for again at the next check.
        harness.wait(60)
        _ = try await harness.run(result.state)
        #expect(harness.newRequests() == ["/api/json", "/job/MR-1/api/json"])
    }

    // MARK: Watched jobs and the log

    @Test("WATCH-04 a job that is mine and watched shows once")
    func mineAndWatchedShowsOnce() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 3)
        harness.answer("MR-5", number: 2)
        let cached = [harness.build("MR-1", number: 3, kind: .watched)]

        let result = try await harness.run(harness.state(myJobs: ["MR-1"], builds: cached), watched: ["MR-1", "MR-5"])

        #expect(harness.newRequests() == ["/job/MR-1/api/json", "/job/MR-5/api/json"])
        #expect(result.builds.map(\.job).sorted() == ["MR-1", "MR-5"])
        #expect(result.builds.first { $0.job == "MR-1" }?.kind == .mine)
        #expect(result.builds.first { $0.job == "MR-5" }?.kind == .watched)
        #expect(result.builds.first { $0.job == "MR-5" }?.author == "Jane Doe")
    }

    @Test("PIPE-08 sorts builds newest started first")
    func sortsNewestFirst() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 3, startedAgo: 3000)
        harness.answer("MR-3", number: 5, startedAgo: 100)
        harness.answer("MR-5", number: 2, startedAgo: 2000)

        let result = try await harness.run(harness.state(myJobs: ["MR-1", "MR-3"]), watched: ["MR-5"])

        #expect(result.builds.map(\.job) == ["MR-3", "MR-5", "MR-1"])
    }

    @Test("LOG-01 logs the builds that start and finish")
    func logsStartedBuilds() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerStages("MR-1", 7, [("build", "IN_PROGRESS")])

        let first = try await harness.run(harness.state(myJobs: ["MR-1"]))
        let second = try await harness.run(first.state)
        harness.answer("MR-1", number: 7, result: "SUCCESS")
        _ = try await harness.run(second.state)

        // "finished" is logged with the alert (AlertPolicy).
        let entries = await harness.log.entries()
        #expect(entries.map(\.message) == ["!1 #7 started: Title of MR-1"])
        #expect(entries.first?.outcome == .running("RUNNING"))
        #expect(entries.first?.level == .info && entries.first?.source == .jenkins)
    }

    @Test("LOG-01 names builds by their label, branch jobs decoded")
    func namesBuildsByLabel() async throws {
        let harness = try Harness()
        harness.answer("feature%252Ffoo", number: 3, result: nil)

        _ = try await harness.run(harness.state(myJobs: []), watched: ["feature%252Ffoo"])

        // An MR job reads "!1 #7" (above); a branch job its decoded name.
        #expect(await harness.log.entries().map(\.message) == ["feature/foo #3 started: Title of feature%252Ffoo"])
    }

    @Test("LOG-01 logs a check summary")
    func logsACheckSummary() async throws {
        let harness = try Harness()
        harness.answer("MR-1", number: 3)
        harness.stub.answer(path: harness.path("/job/MR-3/api/json"), status: 500)
        let checkTimes = CheckTimes(folder: harness.folder.url, log: harness.log)
        let problems = ProblemTracker(log: harness.log)
        let recorder = RequestRecorder(wrapping: harness.stub, log: harness.log, capture: nil, clock: TestClock())
        let check = JenkinsCheck(transport: recorder, log: harness.log, checkTimes: checkTimes, problems: problems, now: { Harness.start })
        let run = {
            try await check.run(
                project: Harness.project, userState: UserState(), token: Harness.token, gitLabUsername: "jdoe",
                state: harness.state(myJobs: ["MR-1", "MR-3"]))
        }

        _ = try await run()
        harness.stub.answer(path: harness.path("/job/MR-1/api/json"), status: 503)
        let failing = try await run()

        #expect(failing.problem == .httpStatus(.jenkins, status: 500))
        #expect(await checkTimes.all().map(\.requests) == [2, 2])
        #expect(await checkTimes.all().map(\.failed) == [1, 2])
        let messages = await harness.log.entries().map(\.message)
        #expect(messages.filter { $0.hasPrefix("Checked Jenkins: ") } == [
            "Checked Jenkins: 2 requests, 0.00s together", "Checked Jenkins: 2 requests, 0.00s together",
        ])
        #expect(messages.last == "Jenkins answered with HTTP 500")
        #expect(await problems.problem("jenkins") == .httpStatus(.jenkins, status: 500))
    }
}

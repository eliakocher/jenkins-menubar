import Foundation
import Testing

@testable import MenubarCore

@Suite("Rebuild")
struct RebuildTests {
    /// Made-up values; the API token is the secret that must never leave the `Authorization` header.
    enum Values {
        static let jobURL = "https://jenkins.example.com/job/project"
        static let root = "/job/project"
        static let apiToken = "made-up-api-token-0123456789"
        static let token = TokenStore.jenkinsToken(user: "jenkins-jdoe", apiToken: apiToken)
        static let start = Date(timeIntervalSince1970: 1_792_800_000)
        /// where Jenkins says the new build waits: queue item 42
        static let location = "https://jenkins.example.com/queue/item/42/"
        static let queuePath = "/queue/item/42/api/json"
        static let sessionCookie = "JSESSIONID.1a2b3c4d=node0abcdefg.node0"
        static let crumb = "0f3c5e7a9b1d2e4f6a8c0b2d4e6f8a1c"
    }

    /// A store on the stub transport and the test clock, with a team, a Jenkins token and temporary files; my job MR-1
    /// has its build #7 failed.
    @MainActor
    private final class Harness {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let clock = TestClock()
        let log: ActivityLog
        let capture: RequestCapture
        let services: PipelinesServices
        private(set) var checks = 0

        init() throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            log = ActivityLog(folder: locations.logs)
            capture = RequestCapture(folder: folder.file("requests"))
            let team = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: Values.jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project")))
            let caches = CacheStore(folder: locations.caches, report: { _ in })
            let failed = Build(
                job: "MR-1", number: 7, title: "Title of MR-1", kind: .mine,
                phase: .finished(result: .failure, duration: 1800), startedAt: Values.start.addingTimeInterval(-3600))
            try caches.save(
                Cached(
                    value: JenkinsState(
                        me: "jenkins-jdoe", myJobs: ["MR-1"], jobsLookedUpAt: Values.start, builds: [failed],
                        checkedAt: Values.start),
                    fetchedAt: Values.start),
                as: .jenkins, for: .main)
            let start = Values.start
            services = PipelinesServices(
                transport: stub, clock: clock, now: { start },
                tokens: TokenStore(keychain: InMemoryKeychain(values: [TokenAccount.jenkins.rawValue: Values.token])),
                team: team, userStates: UserStateStore(folder: locations.applicationSupport, report: { _ in }),
                caches: caches, log: log, capture: capture, effects: FakeEffects())
            // What a test doesn't route answers `{}`: a job without builds, a stage list without stages.
            stub.answer(body: "{}")
        }

        private(set) lazy var store: PipelinesStore = {
            let store = PipelinesStore(services: services, preferences: Preferences())
            store.requestCheck = { [unowned self] in checks += 1 }
            return store
        }()

        func answerParameters(_ fixture: String, job: String = "MR-1") throws {
            let body = try FixtureFiles.string("Jenkins/\(fixture)")
            stub.answer(path: "\(Values.root)/job/\(job)/7/api/json", body: body)
        }

        /// Answers the job's parameter definitions; after ``answerJob(_:number:)``, since it shares the path.
        func answerDefinitions(_ fixture: String, job: String = "MR-1") throws {
            let path = "\(Values.root)/job/\(job)/api/json"
            let response = HTTPResponse(status: 200, body: try FixtureFiles.data("Jenkins/\(fixture)"))
            stub.add(StubTransport.Route(matches: {
                $0.url.path(percentEncoded: true) == path
                    && ($0.url.query(percentEncoded: true) ?? "").contains("parameterDefinitions")
            }) { _ in .success(response) })
        }

        func answerBuildRequest(
            _ page: String = "buildWithParameters", job: String = "MR-1", status: Int = 201,
            location: String? = Values.location, body: String = "", times: Int? = nil
        ) {
            stub.answer(
                "POST", path: "\(Values.root)/job/\(job)/\(page)", times: times, status: status,
                headers: location.map { ["Location": $0] } ?? [:], body: body)
        }

        func answerQueue(_ fixture: String, times: Int? = nil) throws {
            let body = try FixtureFiles.string("Jenkins/\(fixture)")
            stub.answer("GET", path: Values.queuePath, times: times, body: body)
        }

        /// Jenkins asks for a crumb once, then takes the request with it.
        func answerCrumb(_ page: String = "buildWithParameters") throws {
            stub.answer(
                "GET", path: "/crumbIssuer/api/json",
                headers: ["Set-Cookie": "\(Values.sessionCookie); Path=/; Secure; HttpOnly"],
                body: try FixtureFiles.string("Jenkins/crumb.json"))
            let refusal = try FixtureFiles.string("Jenkins/error-403-crumb.html")
            answerBuildRequest(page, status: 403, location: nil, body: refusal, times: 1)
        }

        /// Answers a job with its last build, running, started a minute ago.
        func answerJob(_ job: String, number: Int) {
            let lastBuild: [String: Any] = [
                "number": number, "building": true, "result": NSNull(),
                "timestamp": (Values.start.timeIntervalSince1970 - 60) * 1000, "duration": 0,
            ]
            let actions: [[String: Any]] = [
                ["objectDisplayName": "Title of \(job)"], ["contributorDisplayName": "Jane Doe"],
            ]
            let data = try! JSONSerialization.data(withJSONObject: ["actions": actions, "lastBuild": lastBuild])
            stub.answer(path: "\(Values.root)/job/\(job)/api/json", body: String(decoding: data, as: UTF8.self))
        }

        /// Answers a rebuild of MR-1 #7 with its parameters, which Jenkins queues as item 42.
        func answerQueuedRebuild() throws {
            try answerParameters("build-parameters.json")
            try answerDefinitions("job-parameter-definitions.json")
            answerBuildRequest()
        }

        var posts: [HTTPRequest] {
            stub.requests.filter { $0.method == "POST" }
        }

        func entries() async -> [ActivityEntry] {
            await store.waitForLog()
            return await log.entries()
        }
    }

    // MARK: PIPE-09

    /// The build requests: Jenkins's parameters page, or the plain one.
    enum SendCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case jobWithParameters
        case jobWithoutParameters
        /// a multibranch job's first build, before its Jenkinsfile gave the job parameters
        case firstBuildWithoutParameters
        /// Jenkins had the same build queued already, and answers 303
        case queuedAlready
        /// Jenkins asks for a CSRF crumb in spite of the API token
        case asksForCrumb

        var testDescription: String { rawValue }

        var parameters: String {
            self == .jobWithoutParameters || self == .firstBuildWithoutParameters
                ? "build-without-parameters.json" : "build-parameters.json"
        }

        var definitions: String {
            self == .jobWithoutParameters ? "job-without-parameter-definitions.json" : "job-parameter-definitions.json"
        }

        var page: String {
            self == .jobWithoutParameters ? "build" : "buildWithParameters"
        }

        /// The form: the password and the run parameter have no value to send, so Jenkins takes their defaults.
        var form: String? {
            switch self {
            case .jobWithoutParameters: nil
            case .firstBuildWithoutParameters: ""
            default: "TARGET_BRANCH=release%2F8.x&SKIP_UI_TESTS=false&EXTRA_ARGS=-Dsuite%3Dsmoke%20%26%20more"
            }
        }
    }

    @Test("PIPE-09 rebuild sends the build's parameters", arguments: SendCase.allCases)
    @MainActor
    func sendsTheParameters(_ sent: SendCase) async throws {
        let harness = try Harness()
        try harness.answerParameters(sent.parameters)
        try harness.answerDefinitions(sent.definitions)
        harness.answerBuildRequest(sent.page, status: sent == .queuedAlready ? 303 : 201)
        if sent == .asksForCrumb {
            try harness.answerCrumb()
        }
        let store = harness.store

        store.rebuild(BuildID(job: "MR-1", number: 7))
        await harness.clock.waitForSleepers()

        let rebuild = try #require(store.rebuilds["MR-1"])
        #expect(rebuild.phase == .queued(QueueItem(id: 42)))
        #expect(rebuild.text == "Rebuilding…")
        #expect(rebuild.canCancel)
        let posts = harness.posts
        #expect(posts.count == (sent == .asksForCrumb ? 2 : 1))
        let post = try #require(posts.last)
        #expect(post.url.absoluteString == "\(Values.jobURL)/job/MR-1/\(sent.page)")
        #expect(post.body.map { String(decoding: $0, as: UTF8.self) } == sent.form)
        #expect(post.headers["Content-Type"] == (sent.form == nil ? nil : "application/x-www-form-urlencoded"))
        #expect(post.headers["Authorization"] == "Basic \(Values.token)")
        // The 201 or 303 is read, not followed: its Location names the queue item.
        #expect(!post.followsRedirects)
        if sent == .asksForCrumb {
            #expect(posts[0].headers["Jenkins-Crumb"] == nil)
            #expect(post.headers["Jenkins-Crumb"] == Values.crumb)
            #expect(post.headers["Cookie"] == Values.sessionCookie)
        }
        let started = await harness.entries().first { $0.message == "Rebuilding !1 #7" }
        #expect(started?.detail == "Title of MR-1")
    }

    /// What becomes of the queue item.
    enum FollowCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// it starts my job's build #8, which a check at once shows
        case startsMyJob
        /// it starts build #8 of a job the app didn't follow, which is watched from then on
        case startsAnotherJob
        /// someone cancels it in Jenkins
        case cancelledInJenkins

        var testDescription: String { rawValue }
    }

    @Test("PIPE-09 follows the queue item to the new build", arguments: FollowCase.allCases)
    @MainActor
    func followsTheQueueItem(_ follow: FollowCase) async throws {
        let harness = try Harness()
        let job = follow == .startsAnotherJob ? "MR-5" : "MR-1"
        harness.answerJob(job, number: 8)
        try harness.answerParameters("build-parameters.json", job: job)
        try harness.answerDefinitions("job-parameter-definitions.json", job: job)
        harness.answerBuildRequest(job: job)
        try harness.answerQueue(follow == .cancelledInJenkins ? "queue-item-cancelled.json" : "queue-item-started.json")
        try harness.answerQueue("queue-item-waiting.json", times: 1)
        let store = harness.store

        store.rebuild(BuildID(job: job, number: 7))
        await harness.clock.waitForSleepers()
        harness.clock.advance(by: .seconds(2))
        await harness.clock.waitForSleepers()
        #expect(store.rebuilds[job]?.phase == .queued(QueueItem(id: 42)))
        harness.clock.advance(by: .seconds(3))
        await store.waitForRebuild(job: job)

        #expect(harness.stub.requests(path: Values.queuePath).count == 2)
        let messages = await harness.entries().map(\.message)
        switch follow {
        case .startsMyJob:
            #expect(store.rebuilds[job]?.phase == .started(number: 8))
            #expect(store.rebuilds[job]?.text == "Rebuilding…")
            #expect(harness.checks == 1)
            #expect(messages.contains("Rebuild of !1 #7 started as #8"))
            // The rebuild ends with the check that shows the new build.
            _ = try await store.check(reason: .scheduled)
            #expect(store.myBuilds.map(\.number) == [8])
            #expect(store.rebuilds.isEmpty)
        case .startsAnotherJob:
            #expect(store.userState.watched.map(\.job) == ["MR-5"])
            #expect(harness.checks == 1)
            #expect(messages.contains("Watching !5"))
            _ = try await store.check(reason: .scheduled)
            #expect(store.watchedBuilds.map(\.number) == [8])
            #expect(store.rebuilds.isEmpty)
        case .cancelledInJenkins:
            #expect(store.rebuilds.isEmpty)
            #expect(harness.checks == 0)
            #expect(messages.contains("The rebuild of !1 #7 was cancelled in Jenkins"))
        }
    }

    @Test(
        "PIPE-09 cancel removes the queued rebuild",
        arguments: [true, false] as [Bool])
    @MainActor
    func cancelRemovesTheQueuedRebuild(stillQueued: Bool) async throws {
        let harness = try Harness()
        try harness.answerQueuedRebuild()
        try harness.answerQueue("queue-item-started.json")
        // 204 while the item waits; 404 once it left the queue, as when the build started meanwhile.
        harness.stub.answer("POST", path: "/queue/cancelItem", status: stillQueued ? 204 : 404)
        let store = harness.store
        store.rebuild(BuildID(job: "MR-1", number: 7))
        await harness.clock.waitForSleepers()

        await store.cancelRebuild(job: "MR-1")

        let cancel = try #require(harness.posts.last)
        #expect(cancel.url.absoluteString == "https://jenkins.example.com/queue/cancelItem?id=42")
        if stillQueued {
            #expect(store.rebuilds.isEmpty)
            await store.waitForRebuild(job: "MR-1")
            #expect(harness.clock.sleeperCount == 0)
            #expect(harness.stub.requests(path: Values.queuePath).isEmpty)
            #expect(await harness.entries().map(\.message).contains("Cancelled the rebuild of !1 #7"))
        } else {
            #expect(store.rebuilds["MR-1"]?.canCancel == true)
            harness.clock.advance(by: .seconds(2))
            await store.waitForRebuild(job: "MR-1")
            #expect(store.rebuilds["MR-1"]?.phase == .started(number: 8))
        }
    }

    /// Why a rebuild fails, and the plain words it shows.
    enum FailureCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case noBuildPermission
        case buildGone
        case jobGone
        case rejectedToken
        case serverError
        case unreachable
        case notQueued

        var testDescription: String { rawValue }

        var message: String {
            switch self {
            case .noBuildPermission: "Jenkins didn't allow the rebuild: your account lacks the Build permission"
            case .buildGone, .jobGone: "The job is gone"
            case .rejectedToken: "Jenkins rejected the token"
            case .serverError: "Jenkins answered with HTTP 500"
            case .unreachable: "Jenkins unreachable (VPN?)"
            case .notQueued: "Jenkins didn't queue the rebuild"
            }
        }
    }

    @Test("PIPE-09 tells a missing Build permission", arguments: FailureCase.allCases)
    @MainActor
    func tellsAMissingBuildPermission(_ failure: FailureCase) async throws {
        let harness = try Harness()
        try harness.answerQueuedRebuild()
        switch failure {
        case .noBuildPermission:
            harness.answerBuildRequest(
                status: 403, location: nil, body: try FixtureFiles.string("Jenkins/error-403-build-permission.html"))
        case .buildGone:
            harness.stub.answer(path: "\(Values.root)/job/MR-1/7/api/json", status: 404)
        case .jobGone:
            let page = try FixtureFiles.string("Jenkins/error-404.html")
            harness.answerBuildRequest(status: 404, location: nil, body: page)
        case .rejectedToken:
            harness.answerBuildRequest(status: 401, location: nil)
        case .serverError:
            harness.answerBuildRequest(status: 500, location: nil)
        case .unreachable:
            harness.stub.fail("POST", with: .cannotConnect)
        case .notQueued:
            // The redirect to the job that Jenkins sends when its queue gives no item.
            harness.answerBuildRequest(status: 302, location: "\(Values.jobURL)/job/MR-1/")
        }
        let store = harness.store

        store.rebuild(BuildID(job: "MR-1", number: 7))
        await store.waitForRebuild(job: "MR-1")

        let rebuild = try #require(store.rebuilds["MR-1"])
        #expect(rebuild.phase == .failed(failure.message))
        #expect(rebuild.text == failure.message)
        #expect(!rebuild.canCancel)
        #expect(!rebuild.isUnderWay)
        let logged = await harness.entries().first { $0.message == "Rebuild of !1 #7 failed: \(failure.message)" }
        #expect(logged?.level == .warning)
        #expect(logged?.outcome == .failed("REBUILD"))
        // Nothing is tried again without a click.
        #expect(harness.posts.count == (failure == .buildGone ? 0 : 1))
        #expect(harness.clock.sleeperCount == 0)

        // The failure goes with the job's next build.
        harness.answerJob("MR-1", number: 8)
        _ = try await store.check(reason: .scheduled)
        #expect(store.rebuilds.isEmpty)
    }

    @Test("PIPE-09 keeps the token out of URLs and the log")
    @MainActor
    func keepsTheTokenOut() async throws {
        let harness = try Harness()
        try harness.answerQueuedRebuild()
        try harness.answerCrumb()
        harness.stub.answer("POST", path: "/queue/cancelItem", status: 204)
        let store = harness.store
        let build = BuildID(job: "MR-1", number: 7)

        // A rebuild with a crumb, its cancel, then a rebuild Jenkins refuses.
        store.rebuild(build)
        await harness.clock.waitForSleepers()
        await store.cancelRebuild(job: "MR-1")
        harness.answerBuildRequest(
            status: 403, location: nil, body: try FixtureFiles.string("Jenkins/error-403-build-permission.html"))
        store.rebuild(build)
        await store.waitForRebuild(job: "MR-1")
        #expect(store.rebuilds["MR-1"]?.failure != nil)

        let secrets = [Values.token, Values.apiToken, "jenkins-jdoe:", "node0abcdefg"]
        let requests = harness.stub.requests
        #expect(requests.count == 9)
        for request in requests {
            #expect(secrets.allSatisfy { !request.url.absoluteString.contains($0) }, "\(request.url)")
            // The token travels in its header only.
            #expect(request.headers["Authorization"] == "Basic \(Values.token)")
        }
        let entries = await harness.entries()
        #expect(entries.contains { $0.message == "POST /job/MR-1/buildWithParameters: HTTP 403 in 0.00s" })
        // The log and the kept requests, as written to disk.
        let files = harness.folder.contents()
        #expect(files.contains { $0.hasPrefix("requests/") })
        for file in files {
            let text = try harness.folder.read(file)
            #expect(secrets.allSatisfy { !text.contains($0) }, "\(file)")
        }
        // Copy as cURL names the token's variable instead.
        var curls = 0
        for id in entries.compactMap(\.requestID) {
            let record = try #require(await harness.capture.record(id: id))
            #expect(record.curlCommand.contains("$\(TokenAccount.jenkins.rawValue)"))
            #expect(secrets.allSatisfy { !record.curlCommand.contains($0) })
            curls += 1
        }
        #expect(curls == requests.count)
    }
}

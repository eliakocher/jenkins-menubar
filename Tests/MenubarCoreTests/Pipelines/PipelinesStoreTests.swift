import Foundation
import Testing

@testable import MenubarCore

@Suite("PipelinesStore")
@MainActor
struct PipelinesStoreTests {
    /// A store on the stub transport, with a team, tokens, a time of its own and temporary files.
    @MainActor
    private final class Harness {
        static let jobURL = "https://jenkins.example.com/job/project"
        static let rootPath = "/job/project"
        static let team = TeamValues(
            jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project")
        /// the Jenkins user is `jenkins-jdoe`, the GitLab user `jdoe`
        static let jenkinsToken = TokenStore.jenkinsToken(user: "jenkins-jdoe", apiToken: "secret-api-token")
        static let gitLabToken = "glpat-example-token"
        static let start = Date(timeIntervalSince1970: 1_792_800_000)

        let folder: TemporaryFolder
        let stub = StubTransport()
        let keychain: InMemoryKeychain
        let effects = FakeEffects()
        let log: ActivityLog
        let time = Time(start)
        let services: PipelinesServices
        private(set) var checks = 0
        private var counted = 0

        init(
            team: TeamValues = Harness.team,
            jenkinsToken: String? = Harness.jenkinsToken,
            gitLabToken: String? = Harness.gitLabToken,
            gitLabUser: String? = "jdoe",
            userState: UserState = UserState(),
            cached: JenkinsState? = nil
        ) throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            var tokens: [String: String] = [:]
            tokens[TokenAccount.jenkins.rawValue] = jenkinsToken
            tokens[TokenAccount.gitlab.rawValue] = gitLabToken
            keychain = InMemoryKeychain(values: tokens)
            log = ActivityLog(folder: locations.logs)
            let teamStore = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try teamStore.save(Project(id: .main, team: team))
            let userStates = UserStateStore(folder: locations.applicationSupport, report: { _ in })
            try userStates.save(userState, for: .main)
            let caches = CacheStore(folder: locations.caches, report: { _ in })
            if let cached {
                try caches.save(Cached(value: cached, fetchedAt: Self.start), as: .jenkins, for: .main)
            }
            // GitLab answered CurrentUser in an earlier run, unless a test asks it.
            if let gitLabUser, let gitLabToken {
                let user = GitLabUser(username: gitLabUser, tokenFingerprint: GitLabUser.fingerprint(of: gitLabToken))
                try caches.save(Cached(value: user, fetchedAt: Self.start), as: .gitLabUser, for: .main)
            }
            let time = time
            services = PipelinesServices(
                transport: stub, clock: TestClock(), now: { time.now }, tokens: TokenStore(keychain: keychain),
                team: teamStore, userStates: userStates, caches: caches, log: log, effects: effects)
            // What a test doesn't route answers `{}`: a job without builds, a GitLab answer without data.
            stub.answer(body: "{}")
        }

        private(set) lazy var store: PipelinesStore = {
            let store = PipelinesStore(services: services, preferences: Preferences())
            store.requestCheck = { [unowned self] in checks += 1 }
            return store
        }()

        func check(_ reason: CheckReason = .scheduled) async throws {
            _ = try await store.check(reason: reason)
        }

        /// the Jenkins paths relative to the job URL and the GitLab operations asked since the last call
        func newRequests() -> [String] {
            let requests = stub.requests
            defer { counted = requests.count }
            return requests.dropFirst(counted).map { request in
                request.graphQL?.name ?? String(request.url.path(percentEncoded: true).dropFirst(Self.rootPath.count))
            }
        }

        func answerJobs(_ jobs: [String], contributor: String = "jdoe") {
            let list = jobs.map { ["name": $0, "actions": [[:], ["contributor": contributor]]] as [String: Any] }
            stub.answer(path: Self.rootPath + "/api/json", body: Self.json(["jobs": list]))
        }

        /// Answers a job with its last build, started `startedAgo` seconds before now; a finished one took 30 minutes.
        func answer(_ job: String, number: Int, result: String? = "SUCCESS", startedAgo: TimeInterval = 3600) {
            let lastBuild: [String: Any] = [
                "number": number, "building": result == nil, "result": result ?? NSNull(),
                "timestamp": (time.now.timeIntervalSince1970 - startedAgo) * 1000, "duration": result == nil ? 0 : 1_800_000,
            ]
            let actions: [[String: Any]] = [
                ["objectDisplayName": "Title of \(job)"], ["contributorDisplayName": "Jane Doe"],
            ]
            stub.answer(path: Self.rootPath + "/job/\(job)/api/json", body: Self.json(["actions": actions, "lastBuild": lastBuild]))
        }

        func answer(_ job: String, status: Int) {
            stub.answer(path: Self.rootPath + "/job/\(job)/api/json", status: status)
        }

        func answerStages(_ job: String, _ number: Int, failed: [String]) {
            let list = failed.map { ["name": $0, "status": "FAILED", "durationMillis": 60000] as [String: Any] }
            stub.answer(path: Self.rootPath + "/job/\(job)/\(number)/wfapi/describe", body: Self.json(["stages": list]))
        }

        func answerCurrentUser(_ username: String = "jdoe") {
            stub.answer(operation: "CurrentUser", body: Self.json(["data": ["currentUser": ["username": username]]]))
        }

        func answerMerged(_ iids: [Int]) {
            let nodes = iids.map { ["iid": String($0)] }
            stub.answer(
                operation: "MergedMergeRequests",
                body: Self.json(["data": ["project": ["mergeRequests": ["nodes": nodes]]]]))
        }

        func messages() async -> [String] {
            await store.waitForLog()
            return await log.entries().map(\.message)
        }

        static func json(_ value: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }

        static func watched(_ jobs: String...) -> UserState {
            UserState(watched: jobs.map { WatchedJob(job: $0, label: Build.label(forJob: $0), added: start) })
        }
    }

    /// The time the store's checks see, moved by the tests.
    private final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ start: Date) {
            value = start
        }

        var now: Date {
            lock.withLock { value }
        }

        func wait(_ seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    // MARK: HIDE-01

    @Test("HIDE-01 hides a build until the next build starts")
    func hidesUntilTheNextBuild() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        let store = harness.store
        let build = try #require(store.myBuilds.first)

        store.hide(build)

        #expect(store.myBuilds.isEmpty)
        #expect(store.hiddenCount == 1)
        #expect(store.userState.hidden == ["MR-1": 7])
        #expect(UserStateStore(folder: FileLocations(root: harness.folder.url).applicationSupport, report: { _ in }).load(.main).hidden == ["MR-1": 7])
        #expect(await harness.messages().contains("Hid !1 #7"))

        try await harness.check()
        #expect(store.myBuilds.isEmpty)

        harness.answer("MR-1", number: 8, result: nil, startedAgo: 10)
        try await harness.check()
        #expect(store.myBuilds.map(\.number) == [8])
        #expect(store.hiddenCount == 0)
        #expect(store.userState.hidden.isEmpty)
    }

    @Test("HIDE-01 an alert hides the build it names")
    func hidesByID() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        let store = harness.store

        // The alert window's and the banner's Hide know the build by its job and number only.
        store.hide(BuildID(job: "MR-1", number: 7))

        #expect(store.myBuilds.isEmpty)
        #expect(store.userState.hidden == ["MR-1": 7])
        #expect(await harness.messages().contains("Hid !1 #7"))
    }

    @Test("HIDE-01 show hidden counts singular and plural, and shows them all again")
    func showHiddenAgain() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-2"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3)
        try await harness.check()
        let store = harness.store

        store.hide(store.myBuilds[0])
        #expect(store.showHiddenTitle == "Show 1 Hidden Build")
        store.hide(store.myBuilds[0])
        #expect(store.showHiddenTitle == "Show 2 Hidden Builds")

        store.unhideAll()

        #expect(store.showHiddenTitle == nil)
        #expect(store.myBuilds.count == 2)
        #expect(await harness.messages().contains("Showed the hidden builds again"))
    }

    @Test("HIDE-01 keeps a build hidden while Jenkins fails for its job")
    func keepsHiddenWhileJenkinsFails() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-2"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3)
        try await harness.check()
        let store = harness.store
        store.hide(try #require(store.myBuilds.first { $0.job == "MR-1" }))

        harness.answer("MR-1", status: 500)
        try await harness.check()
        #expect(store.userState.hidden == ["MR-1": 7])
        #expect(store.myBuilds.map(\.job) == ["MR-2"])

        harness.stub.fail(with: .cannotConnect)
        try await harness.check()
        #expect(store.checkProblem == .unreachable(.jenkins))
        #expect(store.userState.hidden == ["MR-1": 7])
        #expect(store.myBuilds.map(\.job) == ["MR-2"])
    }

    @Test("HIDE-01 a hidden build still alerts")
    func hiddenBuildStillAlerts() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7, result: nil, startedAgo: 600)
        try await harness.check()
        let store = harness.store
        store.hide(try #require(store.myBuilds.first))

        harness.time.wait(60)
        harness.answer("MR-1", number: 7, result: "SUCCESS", startedAgo: 660)
        try await harness.check()

        #expect(await harness.effects.alertWindows.map(\.build.id) == [BuildID(job: "MR-1", number: 7)])
        #expect(store.myBuilds.isEmpty)
        #expect(store.hiddenCount == 1)
    }

    @Test("HIDE-01 forgets the hidden build of a dropped job")
    func forgetsTheHiddenBuildOfADroppedJob() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3)
        try await harness.check()
        let store = harness.store
        store.hide(try #require(store.myBuilds.first))
        store.hide(try #require(store.watchedBuilds.first))
        #expect(store.userState.hidden == ["MR-1": 7, "MR-2": 3])

        harness.answer("MR-1", status: 404)
        harness.answer("MR-2", status: 404)
        try await harness.check()

        #expect(store.userState.hidden.isEmpty)
        #expect(store.checkProblem == nil)
    }

    // MARK: HIDE-03

    @Test("HIDE-03 hides the builds of merged MRs")
    func hidesMergedBuilds() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2", "feature%252Ffoo"))
        harness.answerJobs(["MR-1", "MR-3"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-3", number: 1)
        harness.answer("MR-2", number: 3)
        harness.answer("feature%252Ffoo", number: 5)
        harness.answerMerged([1, 2])

        try await harness.check()

        let store = harness.store
        #expect(store.merged == [1, 2])
        #expect(store.myBuilds.map(\.job) == ["MR-3"])
        #expect(store.watchedBuilds.map(\.job) == ["feature%252Ffoo"])
        let asked = try #require(harness.stub.requests(operation: "MergedMergeRequests").first)
        #expect(asked.graphQL?.variables.contains(#""iids":["1","2","3"]"#) == true)
        #expect(asked.graphQL?.variables.contains(#""path":"group/project""#) == true)
    }

    @Test("HIDE-03 shows them while the setting is off")
    func showsMergedWhileOff() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        harness.answerMerged([1])
        try await harness.check()
        let store = harness.store
        #expect(store.myBuilds.isEmpty)

        store.preferences.hidesMergedBuilds = false

        #expect(store.myBuilds.map(\.job) == ["MR-1"])
    }

    @Test("HIDE-03 hides a running build of a merged MR")
    func hidesRunningMergedBuild() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7, result: nil)
        harness.answerMerged([1])

        try await harness.check()

        #expect(harness.store.myBuilds.isEmpty)
        #expect(harness.store.counts.isEmpty)
    }

    @Test("HIDE-03 keeps the last merged list when GitLab fails")
    func keepsMergedListWhenGitLabFails() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-2"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3)
        harness.answerMerged([1])
        try await harness.check()

        harness.stub.answer(operation: "MergedMergeRequests", status: 502)
        try await harness.check()
        #expect(harness.store.merged == [1])

        harness.stub.fail(operation: "MergedMergeRequests", with: .cannotConnect)
        try await harness.check()
        #expect(harness.store.merged == [1])
        #expect(harness.store.myBuilds.map(\.job) == ["MR-2"])
        #expect(harness.store.checkProblem == nil)
    }

    @Test("HIDE-03 asks nothing without MR jobs")
    func asksNothingWithoutMRJobs() async throws {
        let harness = try Harness(userState: Harness.watched("feature%252Ffoo"))
        harness.answerJobs([])
        harness.answer("feature%252Ffoo", number: 5)

        try await harness.check()

        #expect(harness.stub.requests(operation: "MergedMergeRequests").isEmpty)
        #expect(harness.store.merged.isEmpty)
        #expect(harness.store.watchedBuilds.map(\.job) == ["feature%252Ffoo"])
    }

    // MARK: HIDE-04

    @Test("HIDE-04 automatically hidden builds are not counted")
    func automaticallyHiddenAreNotCounted() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-2", "MR-3"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3, result: "FAILURE", startedAgo: 30 * 24 * 3600)
        harness.answer("MR-3", number: 1, result: nil)
        harness.answerMerged([3])
        try await harness.check()
        let store = harness.store
        // A build hidden by hand, then hidden by its MR's merge, counts nowhere.
        store.hide(try #require(store.myBuilds.first { $0.job == "MR-1" }))
        store.preferences.hideSuccessfulAfter = .immediately

        #expect(store.counts.isEmpty)
        #expect(store.hiddenCount == 0)
        #expect(store.showHiddenTitle == nil)
        #expect(store.emptyState == .noBuilds)
    }

    @Test("HIDE-04 builds hidden by hand count only as hidden")
    func hiddenByHandCountOnlyAsHidden() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-2"])
        harness.answer("MR-1", number: 7)
        harness.answer("MR-2", number: 3, result: "FAILURE")
        try await harness.check()
        let store = harness.store
        #expect(store.counts == BuildCounts(failed: 1, successful: 1))

        store.hide(try #require(store.myBuilds.first { $0.job == "MR-2" }))

        #expect(store.counts == BuildCounts(successful: 1))
        #expect(store.hiddenCount == 1)
    }

    // MARK: PIPE-05

    @Test("PIPE-05 counts watched builds")
    func countsWatchedBuilds() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7, result: nil)
        harness.answer("MR-2", number: 3, result: nil)

        try await harness.check()

        #expect(harness.store.counts == BuildCounts(running: 2))
    }

    @Test("PIPE-05 problem marker shows with and without counts")
    func problemMarker() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        let store = harness.store
        #expect(!store.showsProblemMarker)

        harness.answer("MR-1", status: 401)
        try await harness.check()
        #expect(store.problem == .rejectedToken(.jenkins))
        #expect(store.showsProblemMarker)
        #expect(store.counts == BuildCounts(successful: 1))

        let empty = try Harness(jenkinsToken: nil)
        try await empty.check()
        #expect(empty.store.problem == .noToken(.jenkins))
        #expect(empty.store.showsProblemMarker)
        #expect(empty.store.counts.isEmpty)
        #expect(empty.newRequests().allSatisfy { !$0.hasPrefix("/") })

        let noTeam = try Harness(team: TeamValues())
        try await noTeam.check()
        #expect(noTeam.store.problem == .teamValuesMissing)
        #expect(noTeam.store.showsProblemMarker)
    }

    @Test("PIPE-05 GitLab problems leave the icon alone")
    func gitLabProblemsLeaveTheIconAlone() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        harness.stub.fail(operation: "MergedMergeRequests", with: .cannotConnect)

        try await harness.check()

        #expect(harness.store.problem == nil)
        #expect(!harness.store.showsProblemMarker)
        #expect(harness.store.counts == BuildCounts(successful: 1))
    }

    @Test("PIPE-05 idle shows the template image")
    func idle() async throws {
        let harness = try Harness()
        harness.answerJobs([])
        try await harness.check()

        #expect(harness.store.counts.isEmpty)
        #expect(!harness.store.showsProblemMarker)
    }

    // MARK: PIPE-06

    @Test("PIPE-06 names the user when no jobs were found")
    func namesTheUser() async throws {
        let harness = try Harness(gitLabToken: nil)
        harness.answerJobs(["MR-1"], contributor: "someone-else")

        try await harness.check()

        #expect(harness.store.emptyState == .noJobs(user: "jenkins-jdoe"))
        #expect(harness.store.emptyState?.message == "No merge request builds by jenkins-jdoe in Jenkins")
    }

    @Test("PIPE-06 says no builds to show when all are hidden")
    func noBuildsWhenAllHidden() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        #expect(harness.store.emptyState == nil)

        harness.store.hide(try #require(harness.store.myBuilds.first))

        #expect(harness.store.emptyState == .noBuilds)
    }

    @Test("PIPE-06 no-jobs text shows above watched builds")
    func noJobsAboveWatched() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3)

        try await harness.check()

        #expect(harness.store.emptyState == .noJobs(user: "jdoe"))
        #expect(harness.store.watchedBuilds.map(\.job) == ["MR-2"])
    }

    // MARK: PIPE-07

    @Test("PIPE-07 check now looks the jobs up again")
    func checkNowLooksUpAgain() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        _ = harness.newRequests()

        try await harness.check()
        #expect(!harness.newRequests().contains("/api/json"))

        try await harness.check(.checkNow)
        #expect(harness.newRequests().contains("/api/json"))
    }

    @Test("PIPE-07 shows the time of the last check")
    func lastCheckTime() async throws {
        let harness = try Harness()
        harness.answerJobs([])
        #expect(harness.store.lastCheckedAt == nil)

        harness.time.wait(90)
        try await harness.check()

        #expect(harness.store.lastCheckedAt == Harness.start.addingTimeInterval(90))
    }

    // MARK: WATCH-01

    @Test("WATCH-01 watching twice adds nothing")
    func watchingTwice() async throws {
        let harness = try Harness()
        harness.answer("MR-2", number: 3)
        let store = harness.store

        let first = await store.watch(" !2 ")
        let second = await store.watch("https://jenkins.example.com/job/project/job/MR-2/3/console")

        let watched = try first.get().watched
        #expect(try first.get() == .watching(watched, title: "Title of MR-2"))
        #expect(try first.get().message == "Watching all builds of !2")
        #expect(try second.get() == .alreadyWatching(watched))
        #expect(try second.get().message == "Already watching all builds of !2")
        #expect(store.userState.watched.map(\.job) == ["MR-2"])
        #expect(watched == WatchedJob(job: "MR-2", label: "!2", added: Harness.start))
        #expect(harness.stub.requests(path: Harness.rootPath + "/job/MR-2/api/json").count == 1)
        let messages = await harness.messages()
        #expect(messages.filter { $0.hasPrefix("Watching") } == ["Watching !2"])
        #expect(harness.checks == 1)
    }

    @Test("WATCH-01 starts a check at once")
    func watchingStartsACheck() async throws {
        let harness = try Harness()
        harness.answer("MR-2", number: 3)

        _ = await harness.store.watch("MR-2")
        #expect(harness.checks == 1)

        // A refusal stores nothing and starts no check.
        _ = await harness.store.watch("not a link")
        harness.answer("MR-9", status: 404)
        #expect(await harness.store.watch("!9") == .failure(.noJob(job: "MR-9")))
        #expect(harness.checks == 1)
        #expect(harness.store.userState.watched.map(\.job) == ["MR-2"])
    }

    @Test("WATCH-02 refuses without a Jenkins token, and WATCH-03 refuses my own job")
    func refusals() async throws {
        let noToken = try Harness(jenkinsToken: nil)
        #expect(await noToken.store.watch("!2") == .failure(.problem(.noToken(.jenkins))))

        let harness = try Harness()
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)
        try await harness.check()
        #expect(await harness.store.watch("!1") == .failure(.mine(job: "MR-1")))
        #expect(harness.store.userState.watched.isEmpty)
    }

    // MARK: WATCH-04

    @Test("WATCH-04 watched build shows its author")
    func watchedBuildShowsItsAuthor() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3)

        try await harness.check()

        let build = try #require(harness.store.watchedBuilds.first)
        #expect(build.author == "Jane Doe")
        #expect(build.kind == .watched)
        #expect(harness.store.myBuilds.isEmpty)
    }

    @Test("WATCH-04 watched build alerts like mine")
    func watchedBuildAlerts() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3, result: nil, startedAgo: 600)
        try await harness.check()

        harness.time.wait(60)
        harness.answer("MR-2", number: 3, result: "FAILURE", startedAgo: 660)
        harness.answerStages("MR-2", 3, failed: ["tests"])
        try await harness.check()

        let alert = try #require(await harness.effects.alertWindows.first)
        #expect(alert.build.id == BuildID(job: "MR-2", number: 3))
        #expect(alert.build.result == .failure)
        #expect(alert.build.failedStages == ["tests"])
    }

    @Test("EGG-11 a finished build's alert carries the egg line, the log doesn't, and the memory is kept")
    func eggLineInTheAlert() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 42, result: nil, startedAgo: 600)
        try await harness.check()

        harness.time.wait(60)
        harness.answer("MR-2", number: 42, result: "SUCCESS", startedAgo: 660)
        try await harness.check()

        let alert = try #require(await harness.effects.alertWindows.first)
        let line = "Build #42. The answer to everything. The question is still in review."
        #expect(alert.content.eggLine == line)
        #expect(alert.content.bannerBody.hasSuffix(line))
        let logged = await harness.log.entries().first { $0.source == .alerts }
        #expect(logged?.detail?.contains(line) == false)
        #expect(harness.store.eggMemory.greensToday == 1)
        #expect(harness.store.butlerHat == nil)

        // Off, the next alert has no line; the count goes on.
        harness.store.preferences.easterEggs = false
        harness.time.wait(60)
        harness.answer("MR-2", number: 43, result: nil, startedAgo: 30)
        try await harness.check()
        harness.time.wait(60)
        harness.answer("MR-2", number: 43, result: "SUCCESS", startedAgo: 90)
        try await harness.check()
        #expect(await harness.effects.alertWindows.last?.content.eggLine == nil)
        #expect(harness.store.eggMemory.greensToday == 2)
    }

    @Test("WATCH-04 follows the next build of a watched job")
    func followsTheNextBuild() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3)
        try await harness.check()

        harness.time.wait(60)
        harness.answer("MR-2", number: 4, result: nil, startedAgo: 30)
        try await harness.check()
        #expect(harness.store.watchedBuilds.map(\.number) == [4])

        harness.time.wait(60)
        harness.answer("MR-2", number: 4, result: "SUCCESS", startedAgo: 90)
        try await harness.check()
        #expect(await harness.effects.alertWindows.map(\.build.id) == [BuildID(job: "MR-2", number: 4)])
    }

    @Test("WATCH-04 watched build is hidden once its MR is merged")
    func watchedHiddenOnceMerged() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3)
        harness.answerMerged([])
        try await harness.check()
        #expect(harness.store.watchedBuilds.map(\.job) == ["MR-2"])

        harness.answerMerged([2])
        try await harness.check()

        #expect(harness.store.watchedBuilds.isEmpty)
        #expect(harness.store.counts.isEmpty)
    }

    @Test("WATCH-04 a job that is mine and watched shows once")
    func mineAndWatchedShowsOnce() async throws {
        let harness = try Harness(userState: Harness.watched("MR-1"))
        harness.answerJobs(["MR-1"])
        harness.answer("MR-1", number: 7)

        try await harness.check()

        #expect(harness.store.myBuilds.map(\.job) == ["MR-1"])
        #expect(harness.store.watchedBuilds.isEmpty)
        #expect(harness.store.counts == BuildCounts(successful: 1))
    }

    // MARK: WATCH-05

    @Test("WATCH-05 stops watching by hand")
    func stopsWatchingByHand() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 3)
        try await harness.check()

        harness.store.unwatch("MR-2")

        #expect(harness.store.userState.watched.isEmpty)
        #expect(harness.store.watchedBuilds.isEmpty)
        #expect(UserStateStore(folder: FileLocations(root: harness.folder.url).applicationSupport, report: { _ in }).load(.main).watched.isEmpty)
        #expect(await harness.messages().contains("Stopped watching !2: stopped by hand"))
    }

    @Test("WATCH-05 stops watching when Jenkins drops the job")
    func stopsWatchingWhenDropped() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2", "MR-4"))
        harness.answerJobs([])
        harness.answer("MR-2", status: 404)
        harness.answer("MR-4", number: 1)

        try await harness.check()

        #expect(harness.store.userState.watched.map(\.job) == ["MR-4"])
        #expect(harness.store.checkProblem == nil)
        #expect(await harness.messages().contains("Stopped watching !2: Jenkins no longer has it"))
    }

    @Test("WATCH-05 stopping an unwatched job does nothing")
    func stoppingUnwatched() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))

        harness.store.unwatch("MR-9")

        #expect(harness.store.userState.watched.map(\.job) == ["MR-2"])
        #expect(await harness.messages().isEmpty)
    }

    // MARK: WATCH-06

    @Test("WATCH-06 lists the watched jobs with their last build")
    func listsWatchedJobs() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2", "feature%252Ffoo"))
        harness.answerJobs([])
        harness.answer("MR-2", number: 5, result: nil)
        harness.answer("feature%252Ffoo", number: 9, result: "UNSTABLE")

        try await harness.check()

        let list = harness.store.watchedJobs
        #expect(list.map(\.title) == ["!2 #5", "feature/foo #9"])
        #expect(list.map(\.state) == ["RUNNING", "UNSTABLE"])
        #expect(list.map(\.build?.author) == ["Jane Doe", "Jane Doe"])
        #expect(list[0].url?.absoluteString == "https://jenkins.example.com/job/project/job/MR-2/5/")
    }

    @Test("WATCH-06 a job not checked yet is waiting")
    func notCheckedYetIsWaiting() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2"))

        let status = try #require(harness.store.watchedJobs.first)

        #expect(status.isWaiting)
        #expect(status.state == "WAITING")
        #expect(status.url?.absoluteString == "https://jenkins.example.com/job/project/job/MR-2/")
    }

    // MARK: OD-04, PIPE-01

    @Test("OD-04 background check asks only Jenkins MergedMergeRequests and CurrentUser")
    func backgroundRequests() async throws {
        let harness = try Harness(gitLabUser: nil)
        harness.answerJobs(["MR-1"], contributor: "jenkins-jdoe")
        harness.answer("MR-1", number: 7)
        harness.answerCurrentUser()
        harness.answerMerged([])

        try await harness.check()

        let operations = Set(harness.stub.requests.compactMap(\.graphQL?.name))
        #expect(operations == ["CurrentUser", "MergedMergeRequests"])
        #expect(harness.stub.requests.filter { $0.graphQL == nil }.allSatisfy { $0.url.host() == "jenkins.example.com" })
    }

    @Test("OD-04 asks for the GitLab username again only when the token changes")
    func asksUsernameOnlyWhenTheTokenChanges() async throws {
        let harness = try Harness(gitLabUser: nil)
        harness.answerJobs(["MR-1"])
        harness.answerCurrentUser()
        try await harness.check()
        try await harness.check()
        #expect(harness.stub.requests(operation: "CurrentUser").count == 1)

        // A new store, as after a restart, keeps the username of the same token.
        let restarted = PipelinesStore(services: harness.services, preferences: Preferences())
        _ = try await restarted.check(reason: .scheduled)
        #expect(harness.stub.requests(operation: "CurrentUser").count == 1)

        try await harness.keychain.store("glpat-another-token", account: TokenAccount.gitlab.rawValue)
        try await harness.check()
        try await harness.check()
        #expect(harness.stub.requests(operation: "CurrentUser").count == 2)
        let cache = try harness.folder.read("Caches/main/gitlab-user.json")
        #expect(!cache.contains("glpat"))
    }

    @Test("PIPE-01 uses the Jenkins user until GitLab answers, then the GitLab username")
    func jenkinsUserUntilGitLabAnswers() async throws {
        let harness = try Harness(gitLabUser: nil)
        harness.answerJobs(["MR-1"])
        harness.answerCurrentUser()

        try await harness.check()
        #expect(harness.store.state.me == "jenkins-jdoe")

        try await harness.check()
        #expect(harness.store.state.me == "jdoe")
        #expect(harness.store.state.myJobs == ["MR-1"])
    }

    // MARK: ALERT-01, OD-05, JERR-08

    @Test("ALERT-01 stays quiet until Jenkins answered a check since the start")
    func quietUntilJenkinsAnswered() async throws {
        let running = Build(
            job: "MR-1", number: 7, kind: .mine, phase: .running, startedAt: Harness.start.addingTimeInterval(-600))
        let harness = try Harness(
            cached: JenkinsState(
                me: "jdoe", myJobs: ["MR-1"], jobsLookedUpAt: Harness.start, builds: [running],
                checkedAt: Harness.start.addingTimeInterval(-3600)))
        try harness.services.caches.save(
            Cached(value: ["MR-1": AlertState(number: 7, isRunning: true)], fetchedAt: Harness.start), as: .alertStates,
            for: .main)
        harness.answer("MR-1", status: 500)
        try await harness.check()

        harness.answer("MR-1", number: 7, result: "SUCCESS", startedAgo: 600)
        try await harness.check()
        #expect(await harness.effects.calls.isEmpty)

        harness.answer("MR-1", number: 8, result: nil, startedAgo: 10)
        try await harness.check()
        harness.answer("MR-1", number: 8, result: "SUCCESS", startedAgo: 20)
        try await harness.check()
        #expect(await harness.effects.alertWindows.map(\.build.number) == [8])
    }

    @Test("ALERT-09 the alert path asks the policy: a muted job stays quiet, the list and the hide don't change")
    func mutedJobsStayQuiet() async throws {
        let harness = try Harness(userState: Harness.watched("MR-2", "MR-3"))
        harness.answerJobs(["MR-1", "MR-4"])
        for job in ["MR-1", "MR-2", "MR-3", "MR-4"] {
            harness.answer(job, number: 7, result: nil, startedAgo: 600)
        }
        let store = harness.store
        // Watching is off; MR-1 is mine but never, MR-3 is watched but always.
        store.notifications = NotificationPolicy(watching: false, jobs: ["MR-1": .never, "MR-3": .always])
        try await harness.check()
        store.hide(try #require(store.myBuilds.first { $0.job == "MR-4" }))

        harness.time.wait(60)
        for job in ["MR-1", "MR-2", "MR-3", "MR-4"] {
            harness.answer(job, number: 7, result: "FAILURE", startedAgo: 660)
        }
        try await harness.check()

        #expect(Set(await harness.effects.alertWindows.map(\.build.job)) == ["MR-3", "MR-4"])
        #expect(store.myBuilds.map(\.job) == ["MR-1"])
        #expect(store.watchedBuilds.map(\.job).sorted() == ["MR-2", "MR-3"])
    }

    @Test("ALERT-09 a muted job gets no stage banner either, and a job that isn't muted does")
    func mutedJobsGetNoStageBanner() async throws {
        let harness = try Harness()
        harness.answerJobs(["MR-1", "MR-4"])
        for job in ["MR-1", "MR-4"] {
            harness.answer(job, number: 7, result: nil, startedAgo: 600)
        }
        harness.store.notifications = NotificationPolicy(jobs: ["MR-1": .never])
        try await harness.check()

        harness.time.wait(60)
        for job in ["MR-1", "MR-4"] {
            harness.answerStages(job, 7, failed: ["tests"])
        }
        try await harness.check()

        #expect(await harness.effects.banners.map(\.build.job) == ["MR-4"])
    }

    @Test("OD-05 offline shows as the problem, over the check's own")
    func offlineIsTheProblem() async throws {
        let harness = try Harness(jenkinsToken: nil)
        try await harness.check()
        let store = harness.store

        store.setOffline(true)
        #expect(store.problem == .offline)
        #expect(store.problem?.message == "Offline: checks resume when the network is back")
        #expect(store.showsProblemMarker)

        store.setOffline(false)
        #expect(store.problem == .noToken(.jenkins))
    }

    @Test("JERR-08 a 2xx answer that isn't JSON has its own problem")
    func notJSON() async throws {
        let harness = try Harness()
        harness.stub.answer(path: Harness.rootPath + "/api/json", body: "<html>Sign in</html>")

        try await harness.check()

        #expect(harness.store.problem == .notJSON)
        #expect(harness.store.problem?.message == "Jenkins sent an answer that isn't JSON (a login page?)")
        #expect(harness.store.showsProblemMarker)
    }

    @Test("OD-01 shows the cached builds before any check")
    func cachedBuildsAtOnce() async throws {
        let build = Build(
            job: "MR-1", number: 7, kind: .mine, phase: .finished(result: .success, duration: 60),
            startedAt: Harness.start.addingTimeInterval(-600))
        let harness = try Harness(cached: JenkinsState(me: "jdoe", myJobs: ["MR-1"], builds: [build]))

        #expect(harness.store.hasLoaded)
        #expect(harness.store.myBuilds == [build])
        #expect(harness.store.lastCheckedAt == Harness.start)
        #expect(harness.stub.requests.isEmpty)

        let empty = try Harness()
        #expect(!empty.store.hasLoaded)
        #expect(empty.store.emptyState == nil)
    }
}

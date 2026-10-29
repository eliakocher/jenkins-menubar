import Foundation
import Testing

@testable import MenubarCore

/// The on-demand GitLab loads: the merge request and work item stores, their related MRs and labels, and the
/// scheduler's visibility (OD-01 to OD-03, MR-04, MR-05, WI-02, WI-06, WI-07).
@Suite("On demand")
@MainActor
struct OnDemandTests {
    private nonisolated static let path = "acme/main/server/server"
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    /// the time when the test clock starts
    private nonisolated static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let noLabels = #"{"data": {"project": {"labels": {"nodes": []}}}}"#

    /// A stub GitLab on the test clock, a token in a fake keychain, the team values, the caches and the logs in a
    /// temporary folder, and the stores and the scheduler built on them.
    @MainActor
    private final class World {
        let folder: TemporaryFolder
        let clock = TestClock()
        let stub: StubTransport
        let keychain: InMemoryKeychain
        let caches: CacheStore
        let log: ActivityLog
        let checkTimes: CheckTimes
        let events = FakeSystemEvents()
        let network = FakeReachability()
        var preferences = Preferences()
        let services: GitLabServices

        /// - Parameters:
        ///   - token: the GitLab token in the keychain; `nil` for none
        ///   - username: my username as the background check knows it
        init(token: String? = "glpat-test", username: String? = "alex.doe") throws {
            folder = try TemporaryFolder()
            stub = StubTransport(clock: clock)
            keychain = InMemoryKeychain(values: token.map { [TokenAccount.gitlab.rawValue: $0] } ?? [:])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: OnDemandTests.gitLab.absoluteString,
                gitLabProject: OnDemandTests.path, committedLabel: "cLevelOfCommitment::Committed",
                ignoredMergeRequestPrefix: "[cascade]")))
            caches = CacheStore(folder: folder.file("caches"), report: { _ in })
            let clock = clock
            let now: @Sendable () -> Date = { OnDemandTests.start.addingTimeInterval(clock.now.offset.seconds) }
            log = ActivityLog(folder: folder.file("logs"), now: now)
            checkTimes = CheckTimes(folder: folder.file("logs"), log: log, now: now)
            services = GitLabServices(
                transport: stub, clock: clock, now: now, tokens: TokenStore(keychain: keychain), team: team, caches: caches,
                log: log, checkTimes: checkTimes, problems: ProblemTracker(log: log), gitLabUsername: { username })
            stub.answer(operation: "CurrentUser", body: try FixtureFiles.string("GitLab/current-user.json"))
            stub.answer(operation: "MergeRequests", body: try FixtureFiles.string("GitLab/merge-requests.json"))
            stub.answer(operation: "WorkItems", body: OnDemandTests.workItems([1, 2]))
            stub.answer(operation: "RelatedMergeRequests", body: try FixtureFiles.string("GitLab/related-merge-requests-none.json"))
            stub.answer(operation: "Labels", body: OnDemandTests.noLabels)
        }

        var now: Date { services.now() }

        func mergeRequestsStore() -> MergeRequestsStore {
            MergeRequestsStore(services: services)
        }

        func workItemsStore() -> WorkItemsStore {
            WorkItemsStore(services: services, preferences: { [unowned self] in preferences })
        }

        func count(_ operation: String) -> Int {
            stub.requests(operation: operation).count
        }

        /// the iids the RelatedMergeRequests requests asked for, sorted: they run in parallel, in no fixed order
        var relatedIIDs: [String] {
            stub.requests(operation: "RelatedMergeRequests").compactMap {
                $0.graphQL?.variables.firstMatch(of: /"iid":"(\d+)"/).map { String($0.1) }
            }.sorted()
        }

        /// A scheduler on this world's clock, with the stores as its loads and a Jenkins check that does nothing.
        func scheduler(_ mergeRequests: MergeRequestsStore, _ workItems: WorkItemsStore) -> Scheduler {
            Scheduler(
                checkInterval: .seconds(3600), clock: clock, systemEvents: events, reachability: network,
                powerMode: FakePowerMode(), gitLabMaxAge: .seconds(30),
                loads: [.mergeRequests: mergeRequests, .workItems: workItems], check: { _ in .success })
        }

        /// Starts the scheduler and waits for the wait after its first Jenkins check.
        func start(_ scheduler: Scheduler) async {
            await scheduler.start()
            await clock.waitForSleepers()
        }

        /// The cached MRs of an earlier run.
        func cacheMergeRequests(fetchedAt: Date, problem: Problem? = nil) async throws -> MergeRequestList {
            let stub = StubTransport()
            stub.answer(operation: "MergeRequests", body: try FixtureFiles.string("GitLab/merge-requests.json"))
            let list = try await GitLabClient(transport: stub, gitLab: OnDemandTests.gitLab, token: "t").send(.mergeRequests)
            try caches.save(Cached(value: list, fetchedAt: fetchedAt, problem: problem), as: .mergeRequestList, for: .main)
            return list
        }

        /// The cached work items of an earlier run.
        func cacheWorkItems(_ iids: [Int], fetchedAt: Date) throws {
            let items = iids.map { OnDemandTests.item($0) }
            try caches.save(Cached(value: WorkItemLists(others: WorkItemList(count: items.count, items: items)), fetchedAt: fetchedAt),
                            as: .workItems, for: .main)
        }

        func logEntries(_ message: String) async -> [ActivityEntry] {
            await log.entries().filter { $0.message == message }
        }
    }

    private static func item(_ iid: Int, updatedAt: String = "2026-10-26T08:39:25Z") -> WorkItem {
        WorkItem(reference: "\(path)#\(iid)", title: "Item \(iid)", webURL: gitLab.appending(path: "\(path)/-/work_items/\(iid)"),
                 labels: [Label(title: "bug", color: "#ff0000")], updatedAt: try! Date.ISO8601FormatStyle().parse(updatedAt))
    }

    /// A WorkItems answer with these not-committed work items, each with the label `bug`.
    ///
    /// - Parameter changed: the work items updated later than the others, with their `updatedAt`
    private static func workItems(_ iids: [Int], changed: [Int: String] = [:]) -> String {
        let nodes = iids.map { iid in
            #"{"title": "Item \#(iid)", "webUrl": "\#(gitLab)/\#(path)/-/work_items/\#(iid)", "reference": "\#(path)#\#(iid)", "#
                + ##""updatedAt": "\##(changed[iid] ?? "2026-10-26T08:39:25Z")", "labels": {"nodes": [{"title": "bug", "color": "#ff0000"}]}}"##
        }
        return #"{"data": {"committed": {"count": 0, "nodes": []}, "others": {"count": \#(iids.count), "nodes": [\#(nodes.joined(separator: ","))]}}}"#
    }

    // MARK: - OD-01

    @Test("OD-01 panel shows cached data before any load")
    func cachedDataAtOnce() async throws {
        let world = try World()
        let cached = try await world.cacheMergeRequests(fetchedAt: Self.start.addingTimeInterval(-60))
        try world.cacheWorkItems([1, 2], fetchedAt: Self.start.addingTimeInterval(-60))

        let mergeRequests = world.mergeRequestsStore()
        let workItems = world.workItemsStore()
        #expect(mergeRequests.list == cached)
        #expect(mergeRequests.sections?.reviewRequested.count == 1)
        #expect(mergeRequests.lastLoadAt == Self.start.addingTimeInterval(-60))
        #expect(workItems.lists?.all.map(\.reference) == ["\(Self.path)#1", "\(Self.path)#2"])
        #expect(!mergeRequests.isLoading && !workItems.isLoading)
        #expect(world.stub.requests.isEmpty)
    }

    @Test("OD-01 loading section shows a spinner")
    func spinner() async throws {
        let world = try World()
        world.stub.answer(operation: "MergeRequests", after: .seconds(2), body: try FixtureFiles.string("GitLab/merge-requests.json"))
        let store = world.mergeRequestsStore()
        #expect(store.list == nil)

        let load = Task { await store.load() }
        await world.clock.waitForSleepers()
        #expect(store.isLoading)
        world.clock.advance(by: .seconds(2))
        await load.value
        #expect(!store.isLoading)
        #expect(store.list?.username == "alex.doe")
        #expect(store.problem == nil)
    }

    // MARK: - MR-04

    @Test("MR-04 makes no GitLab request without a token")
    func noToken() async throws {
        let world = try World(token: nil)
        let mergeRequests = world.mergeRequestsStore()
        let workItems = world.workItemsStore()
        await mergeRequests.load()
        await workItems.load()

        #expect(world.stub.requests.isEmpty)
        #expect(mergeRequests.problem == .noToken(.gitLab))
        #expect(workItems.problem == .noToken(.gitLab))
        // A setup step, not a failure: the section shows the steps, and nothing is logged.
        #expect(await world.logEntries(Problem.noToken(.gitLab).message).isEmpty)
    }

    @Test("MR-04 removing the token discards the GitLab data")
    func removedToken() async throws {
        let world = try World()
        let mergeRequests = world.mergeRequestsStore()
        let workItems = world.workItemsStore()
        await mergeRequests.load()
        await workItems.load()
        #expect(mergeRequests.list != nil && workItems.lists != nil)
        #expect(world.folder.contents().contains("caches/main/merge-request-list.json"))
        #expect(world.folder.contents().contains("caches/main/related-merge-requests.json"))

        await world.keychain.delete(account: TokenAccount.gitlab.rawValue)
        let requests = world.stub.requests.count
        await mergeRequests.load()
        await workItems.load()
        #expect(world.stub.requests.count == requests)
        #expect(mergeRequests.list == nil && workItems.lists == nil)
        #expect(workItems.relatedMergeRequests.entries.isEmpty)
        let files = world.folder.contents()
        #expect(!files.contains("caches/main/merge-request-list.json"))
        #expect(!files.contains("caches/main/work-items.json"))
        #expect(!files.contains("caches/main/related-merge-requests.json"))
        // The labels are the filters' vocabulary, and stay.
        #expect(files.contains("caches/main/labels.json"))

        // Settings calls it when it removes the token, before any load.
        try world.cacheWorkItems([1], fetchedAt: Self.start)
        _ = try await world.cacheMergeRequests(fetchedAt: Self.start)
        let relaunched = (world.mergeRequestsStore(), world.workItemsStore())
        relaunched.0.tokenRemoved()
        relaunched.1.tokenRemoved()
        #expect(relaunched.0.list == nil && relaunched.1.lists == nil)
        #expect(relaunched.0.problem == .noToken(.gitLab) && relaunched.1.problem == .noToken(.gitLab))
        #expect(!world.folder.contents().contains("caches/main/work-items.json"))
        #expect(!world.folder.contents().contains("caches/main/merge-request-list.json"))
    }

    // MARK: - MR-05

    @Test("MR-05 reports GitLab unreachable and keeps the cached MRs")
    func unreachableKeepsCachedMergeRequests() async throws {
        let world = try World()
        let cached = try await world.cacheMergeRequests(fetchedAt: Self.start.addingTimeInterval(-600))
        world.stub.fail(operation: "MergeRequests", with: .unknownHost)
        let store = world.mergeRequestsStore()

        await store.load()
        #expect(store.problem == .unreachable(.gitLab))
        #expect(store.list == cached)
        #expect(store.fetchedAt == Self.start.addingTimeInterval(-600))
        // The problem is kept with the MRs, so the next launch shows it and doesn't log it again.
        #expect(world.caches.load(.mergeRequestList, for: .main)?.problem == .unreachable(.gitLab))
        #expect(GitLabServices.cachedProblems(in: world.caches, for: .main)[MergeRequestsStore.problemKey]?.0 == .unreachable(.gitLab))

        // Logged once when it starts and once when resolved (LOG-01).
        await store.load()
        #expect(await world.logEntries("GitLab unreachable").count == 1)
        world.stub.answer(operation: "MergeRequests", body: try FixtureFiles.string("GitLab/merge-requests.json"))
        await store.load()
        #expect(store.problem == nil)
        #expect(await world.logEntries("Resolved: GitLab unreachable").count == 1)
    }

    @Test("MR-05 keeps the cached work items when their load fails")
    func failedWorkItemsKeepCached() async throws {
        let world = try World()
        try world.cacheWorkItems([1, 2], fetchedAt: Self.start.addingTimeInterval(-600))
        world.stub.answer(operation: "WorkItems", status: 500, body: "")
        let store = world.workItemsStore()

        await store.load()
        #expect(store.problem == .workItemsFailed(status: 500))
        #expect(store.lists?.all.count == 2)
        #expect(world.caches.load(.workItems, for: .main)?.problem == .workItemsFailed(status: 500))
        #expect(await world.logEntries("Work items request failed (HTTP 500)").count == 1)
        // Without work items, nothing else is asked.
        #expect(world.count("RelatedMergeRequests") == 0 && world.count("Labels") == 0)
    }

    // MARK: - WI-07

    @Test("WI-07 shows the time of the last GitLab load")
    func lastLoadTime() async throws {
        let world = try World()
        let store = world.workItemsStore()
        world.clock.advance(by: .seconds(100))
        await store.load()
        #expect(store.lastLoadAt == Self.start.addingTimeInterval(100))
        #expect(store.fetchedAt == Self.start.addingTimeInterval(100))

        // A failed load is a load too: "Last checked" moves, the data's time stays.
        world.stub.fail(operation: "WorkItems", with: .unknownHost)
        world.clock.advance(by: .seconds(100))
        await store.load()
        #expect(store.lastLoadAt == Self.start.addingTimeInterval(200))
        #expect(store.fetchedAt == Self.start.addingTimeInterval(100))

        let afternoon = Date(timeIntervalSince1970: 14 * 3600 + 5 * 60)
        #expect(GitLabText.lastChecked(afternoon, locale: Locale(identifier: "de_CH"), timeZone: .gmt) == "Last checked 14:05")
    }

    // MARK: - OD-03, the stores

    @Test("OD-03 reuses an answer for 10 minutes while unchanged")
    func relatedReused() async throws {
        let world = try World()
        let store = world.workItemsStore()
        await store.load()
        #expect(world.relatedIIDs == ["1", "2"])
        #expect(store.relatedMergeRequests.entries["\(Self.path)#1"]?.fetchedAt == Self.start)

        world.clock.advance(by: .seconds(599))
        await store.load()
        #expect(world.relatedIIDs == ["1", "2"])

        world.clock.advance(by: .seconds(1))
        await store.load()
        #expect(world.relatedIIDs == ["1", "1", "2", "2"])
    }

    @Test("OD-03 asks again when the work item changed")
    func relatedAskedAgainWhenChanged() async throws {
        let world = try World()
        let store = world.workItemsStore()
        await store.load()
        world.stub.answer(operation: "WorkItems", body: Self.workItems([1, 2], changed: [1: "2026-10-26T09:00:00Z"]))
        world.clock.advance(by: .seconds(60))
        await store.load()
        #expect(world.relatedIIDs == ["1", "1", "2"])
        #expect(store.relatedMergeRequests.entries["\(Self.path)#1"]?.workItemUpdatedAt == (try Date.ISO8601FormatStyle().parse("2026-10-26T09:00:00Z")))
    }

    @Test("OD-03 keeps the old answer when a request fails")
    func relatedKeptOnFailure() async throws {
        let world = try World()
        world.stub.answer(operation: "RelatedMergeRequests", body: try FixtureFiles.string("GitLab/related-merge-requests.json"))
        let store = world.workItemsStore()
        await store.load()
        let old = try #require(store.relatedMergeRequests.entries["\(Self.path)#1"])
        #expect(store.marker(of: Self.item(1), ignoredPrefix: "[cascade]") == .merged)

        world.stub.fail(operation: "RelatedMergeRequests", with: .unknownHost)
        world.clock.advance(by: .seconds(600))
        await store.load()
        #expect(world.relatedIIDs.count == 4)
        #expect(store.relatedMergeRequests.entries["\(Self.path)#1"] == old)
        #expect(store.marker(of: Self.item(1), ignoredPrefix: "[cascade]") == .merged)
        #expect(store.problem == nil)
        // A relaunch reads the kept answer.
        #expect(world.workItemsStore().relatedMergeRequests.entries["\(Self.path)#1"] == old)
    }

    @Test("OD-03 asks 6 at a time")
    func relatedSixAtATime() async throws {
        let world = try World()
        world.stub.answer(operation: "WorkItems", body: Self.workItems(Array(1...8)))
        world.stub.answer(operation: "RelatedMergeRequests", after: .seconds(1),
                          body: try FixtureFiles.string("GitLab/related-merge-requests-none.json"))
        let store = world.workItemsStore()

        let load = Task { await store.load() }
        await world.clock.waitForSleepers(6)
        #expect(world.count("RelatedMergeRequests") == 6)
        #expect(store.lists?.all.count == 8)
        #expect(store.isLoading)
        world.clock.advance(by: .seconds(1))
        await world.clock.waitForSleepers(2)
        #expect(world.count("RelatedMergeRequests") == 8)
        world.clock.advance(by: .seconds(1))
        await load.value
        #expect(store.relatedMergeRequests.entries.count == 8)
        #expect(!store.isLoading)
    }

    @Test("OD-03 drops answers older than a day and asks nothing for epics")
    func relatedPrunedAndNoEpics() async throws {
        let world = try World()
        let gone = RelatedMergeRequestsCache.Entry(workItemUpdatedAt: Self.start, fetchedAt: Self.start.addingTimeInterval(-86400), mergeRequests: [])
        let recent = RelatedMergeRequestsCache.Entry(workItemUpdatedAt: Self.start, fetchedAt: Self.start.addingTimeInterval(-3600), mergeRequests: [])
        try world.caches.save(Cached(value: RelatedMergeRequestsCache(entries: ["\(Self.path)#8": gone, "\(Self.path)#9": recent]),
                                     fetchedAt: Self.start), as: .relatedMergeRequests, for: .main)
        world.stub.answer(operation: "WorkItems", body: Self.workItems([1]).replacingOccurrences(of: "\(Self.path)#1", with: "group&1"))
        let store = world.workItemsStore()
        await store.load()
        #expect(world.count("RelatedMergeRequests") == 0)
        #expect(Set(store.relatedMergeRequests.entries.keys) == ["\(Self.path)#9"])
    }

    // MARK: - The loads' side work

    @Test("OD-02 one load is one GitLab check time")
    func loadIsOneCheckTime() async throws {
        let world = try World()
        world.preferences.workItems.withoutLabels = ["wontfix"]
        let store = world.workItemsStore()
        await store.load()
        let times = await world.checkTimes.all()
        // WorkItems, Labels for the must-not-have label, and the two work items' related MRs.
        #expect(times.map(\.source) == [.gitlab])
        #expect(times.first?.requests == 4)
        #expect(await world.log.entries().contains { $0.message.hasPrefix("Checked GitLab: 4 requests") })
    }

    @Test("WI-06 logs a gone filter label once")
    func goneFilterLabelLoggedOnce() async throws {
        let world = try World()
        world.preferences.workItems.withoutLabels = ["uStatus::Gone"]
        let store = world.workItemsStore()
        await store.load()
        await store.load()
        #expect(store.labels.missing == ["uStatus::Gone"])
        #expect(store.labels.missingFilterLabels(of: world.preferences.workItems) == ["uStatus::Gone"])
        let entries = await world.logEntries(LabelMemory.missingMessage(label: "uStatus::Gone"))
        #expect(entries.count == 1)
        #expect(entries.first?.level == .warning)
        #expect(entries.first?.outcome == .warning("MISSING"))
        // The labels of the work items are remembered, with their colors.
        #expect(store.labels.known == ["bug"])
        #expect(world.workItemsStore().labels.colors["bug"] == "#ff0000")
    }

    @Test("WI-06 the label search remembers GitLab's colors")
    func labelSearchRemembersColors() async throws {
        let world = try World()
        world.stub.answer(operation: "Labels", body: try FixtureFiles.string("GitLab/labels.json"))
        let store = world.workItemsStore()
        let search = Task { try await store.searchLabels("verif") }
        await world.clock.waitForSleepers()
        world.clock.advance(by: LabelSearch.pause)
        let result = try await search.value
        #expect(result.labels == ["uStatus::InVerification"])
        #expect(result.problem == nil)
        #expect(store.labels.colors["uStatus::InVerification"] == "#808080")
    }

    @Test("WI-02 asks GitLab for my username when the check has none")
    func usernameFromGitLab() async throws {
        let world = try World(username: nil)
        let store = world.workItemsStore()
        await store.load()
        #expect(world.count("CurrentUser") == 1)
        #expect(world.stub.requests(operation: "WorkItems").first?.graphQL?.variables.contains(#""assignee":["alex.doe"]"#) == true)
    }

    // MARK: - OD-02, OD-03 and WI-02: the scheduler

    @Test("OD-02 no load while nothing is on screen")
    func noLoadWhileHidden() async throws {
        let world = try World()
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        for _ in 0..<5 {
            world.clock.advance(by: .seconds(600))
            await world.clock.waitForSleepers()
        }
        #expect(world.stub.requests.isEmpty)

        // A surface that disappears stops loading.
        await scheduler.setVisible([.mergeRequests])
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 1)
        await scheduler.setVisible([])
        #expect(world.clock.sleeperCount == 1)
        world.clock.advance(by: .seconds(600))
        await world.clock.waitForSleepers()
        #expect(world.stub.requests.count == 1)
    }

    @Test("OD-02 loads when shown and stale")
    func loadsWhenShownAndStale() async throws {
        let world = try World()
        _ = try await world.cacheMergeRequests(fetchedAt: Self.start.addingTimeInterval(-60))
        try world.cacheWorkItems([1, 2], fetchedAt: Self.start.addingTimeInterval(-10))
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)

        // 60 s old: at once. 10 s old: once it is 30 s old.
        await scheduler.setVisible([.mergeRequests, .workItems])
        await world.clock.waitForSleepers(3)
        #expect(world.count("MergeRequests") == 1)
        #expect(world.count("WorkItems") == 0)
        world.clock.advance(by: .seconds(19))
        #expect(world.count("WorkItems") == 0)
        world.clock.advance(by: .seconds(1))
        await world.clock.waitForSleepers(3)
        #expect(world.count("WorkItems") == 1)
        #expect(world.count("MergeRequests") == 1)
    }

    @Test("OD-02 one load per maximum age while on screen")
    func oneLoadPerMaxAge() async throws {
        let world = try World()
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        await scheduler.setVisible([.mergeRequests])
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 1)

        for loads in 2...4 {
            world.clock.advance(by: .seconds(29))
            #expect(world.count("MergeRequests") == loads - 1)
            world.clock.advance(by: .seconds(1))
            await world.clock.waitForSleepers(2)
            #expect(world.count("MergeRequests") == loads)
        }

        // A new maximum age applies to the wait under way, counted from the last load.
        await scheduler.setGitLabMaxAge(.seconds(60))
        await world.clock.waitForSleepers(2)
        world.clock.advance(by: .seconds(59))
        #expect(world.count("MergeRequests") == 4)
        world.clock.advance(by: .seconds(1))
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 5)
    }

    @Test("OD-02 check now reloads")
    func checkNowReloads() async throws {
        let world = try World()
        try world.cacheWorkItems([1, 2], fetchedAt: Self.start)
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        await scheduler.setVisible([.mergeRequests])
        await world.clock.waitForSleepers(2)

        await scheduler.checkNow()
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 2)
        // Hidden work items load as soon as they are shown, though their data is fresh.
        #expect(world.count("WorkItems") == 0)
        await scheduler.setVisible([.mergeRequests, .workItems])
        await world.clock.waitForSleepers(3)
        #expect(world.count("WorkItems") == 1)
        #expect(world.count("MergeRequests") == 2)
    }

    @Test("OD-03 related MRs load only with work items on screen")
    func relatedOnlyWithWorkItems() async throws {
        let world = try World()
        try world.cacheWorkItems([1, 2], fetchedAt: Self.start.addingTimeInterval(-3600))
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        await scheduler.setVisible([.mergeRequests])
        await world.clock.waitForSleepers(2)
        for _ in 0..<3 {
            world.clock.advance(by: .seconds(30))
            await world.clock.waitForSleepers(2)
        }
        #expect(world.count("MergeRequests") == 4)
        #expect(world.count("WorkItems") == 0 && world.count("RelatedMergeRequests") == 0)

        await scheduler.setVisible([.mergeRequests, .workItems])
        await world.clock.waitForSleepers(3)
        #expect(world.count("WorkItems") == 1)
        #expect(world.relatedIIDs == ["1", "2"])

        await scheduler.setVisible([.mergeRequests])
        world.clock.advance(by: .seconds(3600))
        await world.clock.waitForSleepers(2)
        #expect(world.count("WorkItems") == 1 && world.count("RelatedMergeRequests") == 2)
    }

    @Test("WI-02 changing a filter reloads the work items")
    func filterChangeReloads() async throws {
        let world = try World()
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        await scheduler.setVisible([.workItems])
        await world.clock.waitForSleepers(2)
        #expect(world.stub.requests(operation: "WorkItems").last?.graphQL?.variables.contains(#""assignee":["alex.doe"],"author":null"#) == true)

        world.preferences.workItems.scope = .authored
        await scheduler.reload(.workItems)
        await world.clock.waitForSleepers(2)
        #expect(world.count("WorkItems") == 2)
        #expect(world.stub.requests(operation: "WorkItems").last?.graphQL?.variables.contains(#""assignee":null,"author":"alex.doe""#) == true)
    }

    @Test("OD-02 no load while asleep or offline, one on wake and when back")
    func sleepAndOffline() async throws {
        let world = try World()
        let scheduler = world.scheduler(world.mergeRequestsStore(), world.workItemsStore())
        await world.start(scheduler)
        await scheduler.setVisible([.mergeRequests])
        await world.clock.waitForSleepers(2)

        world.events.send(.willSleep)
        try await Self.waitFor(scheduler) { $0.isAsleep }
        #expect(world.clock.sleeperCount == 0)
        world.clock.advance(by: .seconds(3600))
        #expect(world.count("MergeRequests") == 1)
        world.events.send(.didWake)
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 2)

        world.network.set(reachable: false)
        try await Self.waitFor(scheduler) { $0.isOffline }
        world.clock.advance(by: .seconds(3600))
        #expect(world.count("MergeRequests") == 2)
        world.network.set(reachable: true)
        await world.clock.waitForSleepers(2)
        #expect(world.count("MergeRequests") == 3)
    }

    /// Waits until the scheduler's status shows what the fakes sent it.
    private static func waitFor(_ scheduler: Scheduler, _ condition: @Sendable (Scheduler.Status) -> Bool) async throws {
        for _ in 0..<2000 {
            if condition(await scheduler.status) {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the scheduler never got there: \(await scheduler.status)")
    }
}

private extension Duration {
    /// the duration in seconds, as `Date` counts them
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

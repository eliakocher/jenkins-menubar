import Foundation
import Testing

@testable import MenubarCore

@Suite("ProjectsPipelines")
@MainActor
struct ProjectsPipelinesTests {
    static let server = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/server", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/server")
    static let client = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/client", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/client")
    static let clientID = ProjectID(rawValue: "p-client")!
    static let gitLabToken = "glpat-example-token"

    /// Two projects on the stub transport, the primary `server` and `client`, with tokens and temporary files.
    @MainActor
    final class Harness {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let services: PipelinesServices
        let effects = FakeEffects()
        let projects: ProjectsPipelines
        let now = Date(timeIntervalSince1970: 1_792_800_000)

        init() throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            let keychain = InMemoryKeychain(values: [
                TokenAccount.jenkins.rawValue: TokenStore.jenkinsToken(user: "jenkins-jdoe", apiToken: "secret"),
                TokenAccount.gitlab.rawValue: ProjectsPipelinesTests.gitLabToken,
            ])
            let team = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try team.save(Project(id: .main, team: ProjectsPipelinesTests.server))
            try team.save(Project(id: ProjectsPipelinesTests.clientID, team: ProjectsPipelinesTests.client))
            let now = now
            services = PipelinesServices(
                transport: stub, clock: TestClock(), now: { now }, tokens: TokenStore(keychain: keychain), team: team,
                userStates: UserStateStore(folder: locations.applicationSupport, report: { _ in }),
                caches: CacheStore(folder: locations.caches, report: { _ in }),
                log: ActivityLog(folder: locations.logs), effects: effects)
            stub.answer(body: "{}")
            stub.answer(operation: "CurrentUser", body: #"{"data": {"currentUser": {"username": "jdoe"}}}"#)
            projects = ProjectsPipelines(services: services, preferences: Preferences())
        }

        /// Answers a project's job list with one MR job of mine, whose last build is finished with the result, or runs.
        func answer(_ root: String, job: String, number: Int, result: String?) {
            stub.answer(path: "/job/\(root)/api/json", body: #"{"jobs": [{"name": "\#(job)", "actions": [{}, {"contributor": "jdoe"}]}]}"#)
            let started = (now.timeIntervalSince1970 - 3600) * 1000
            stub.answer(
                path: "/job/\(root)/job/\(job)/api/json",
                body: #"{"actions": [], "lastBuild": {"number": \#(number), "building": \#(result == nil), "result": \#(result.map { "\"\($0)\"" } ?? "null"), "timestamp": \#(started), "duration": 1800000}}"#)
        }
    }

    @Test("PROJ-03 checks every project in one round, asks GitLab's user once, and sums their builds")
    func checksAll() async throws {
        let harness = try Harness()
        harness.answer("server", job: "MR-1", number: 7, result: "SUCCESS")
        harness.answer("client", job: "MR-1", number: 3, result: "FAILURE")
        let projects = harness.projects

        #expect(projects.stores.map(\.projectID) == [.main, Self.clientID])
        #expect(projects.names == [.main: "server", Self.clientID: "client"])
        #expect(try await projects.check(reason: .scheduled) == .success)
        // The first round found the GitLab user and handed it on; until GitLab answered, the Jenkins user counted.
        #expect(harness.stub.requests(operation: "CurrentUser").count == 1)
        #expect(try await projects.check(reason: .scheduled) == .success)

        #expect(projects.primary.myBuilds.map(\.id) == [BuildID(job: "MR-1", number: 7, project: .main)])
        #expect(projects.store(for: Self.clientID)?.myBuilds.map(\.id) == [BuildID(job: "MR-1", number: 3, project: Self.clientID)])
        #expect(projects.counts.successful == 1)
        #expect(projects.counts.failed == 1)
        #expect(harness.stub.requests(operation: "CurrentUser").count == 1)
        // Each project's builds are in its own caches folder.
        #expect(harness.services.caches.load(.jenkins, for: Self.clientID)?.value.builds.map(\.number) == [3])
        #expect(harness.services.caches.load(.jenkins, for: .main)?.value.builds.map(\.number) == [7])
    }

    @Test("PROJ-03 a project Jenkins doesn't answer marks the icon, but fails the check only when all do")
    func oneBrokenProject() async throws {
        let harness = try Harness()
        harness.answer("server", job: "MR-1", number: 7, result: "SUCCESS")
        harness.stub.fail(path: "/job/client/api/json", with: .cannotConnect)
        let projects = harness.projects
        _ = try await projects.check(reason: .scheduled)

        #expect(try await projects.check(reason: .scheduled) == .success)
        #expect(projects.primary.problem == nil)
        #expect(projects.problemProject == Self.clientID)
        #expect(projects.showsProblemMarker)
        #expect(projects.counts.successful == 1)

        harness.stub.fail(path: "/job/server/api/json", with: .cannotConnect)
        #expect(try await projects.check(reason: .checkNow) == .failure)
    }

    @Test("PROJ-03 hide reaches the build's own project")
    func hidesInItsProject() async throws {
        let harness = try Harness()
        harness.answer("server", job: "MR-1", number: 7, result: "SUCCESS")
        harness.answer("client", job: "MR-1", number: 3, result: "FAILURE")
        let projects = harness.projects
        _ = try await projects.check(reason: .scheduled)
        _ = try await projects.check(reason: .scheduled)

        projects.hide(BuildID(job: "MR-1", number: 3, project: Self.clientID))

        #expect(projects.primary.myBuilds.count == 1)
        #expect(projects.store(for: Self.clientID)?.myBuilds.isEmpty == true)
        #expect(harness.services.userStates.load(Self.clientID).hidden == ["MR-1": 3])
        #expect(harness.services.userStates.load(.main).hidden.isEmpty)
    }

    @Test("PROJ-02 a removed project's store goes, an added one's comes")
    func followsSettings() throws {
        let harness = try Harness()
        let projects = harness.projects
        let team = harness.services.team

        try team.remove(Self.clientID)
        projects.syncProjects()
        #expect(projects.stores.map(\.projectID) == [.main])
        #expect(!projects.hasSeveral)

        let added = try team.add(Self.client)
        projects.syncProjects()
        #expect(projects.stores.map(\.projectID) == [.main, added.id])
        #expect(projects.names[added.id] == "client")
    }

    @Test("PROJ-04 with several projects, an alert and the log entries name their project")
    func namesTheProject() async throws {
        let harness = try Harness()
        harness.answer("server", job: "MR-1", number: 7, result: "SUCCESS")
        harness.answer("client", job: "MR-1", number: 3, result: nil)
        let projects = harness.projects
        _ = try await projects.check(reason: .scheduled)
        _ = try await projects.check(reason: .scheduled)
        harness.answer("client", job: "MR-1", number: 3, result: "FAILURE")
        _ = try await projects.check(reason: .scheduled)

        let banners = await harness.effects.calls.compactMap { call -> BuildAlert? in
            if case .alertWindow(let alert) = call { alert } else if case .banner(let alert) = call { alert } else { nil }
        }
        #expect(banners.map(\.content.project) == ["client"])
        #expect(banners.first?.content.hide?.project == Self.clientID)
        await projects.primary.waitForLog()
        let entries = await harness.services.log.entries()
        #expect(entries.contains { $0.project == "client" })
        #expect(entries.contains { $0.project == "server" })
        #expect(entries.allSatisfy { $0.project != nil || $0.source != .jenkins })
    }

    @Test("PROJ-04 with one project, nothing names it")
    func oneProjectNamesNothing() async throws {
        let harness = try Harness()
        try harness.services.team.remove(Self.clientID)
        harness.projects.syncProjects()
        harness.answer("server", job: "MR-1", number: 7, result: nil)
        _ = try await harness.projects.check(reason: .scheduled)
        _ = try await harness.projects.check(reason: .scheduled)
        harness.answer("server", job: "MR-1", number: 7, result: "SUCCESS")
        _ = try await harness.projects.check(reason: .scheduled)

        let alerts = await harness.effects.calls.compactMap { call -> BuildAlert? in
            if case .alertWindow(let alert) = call { alert } else if case .banner(let alert) = call { alert } else { nil }
        }
        #expect(alerts.count == 1)
        #expect(alerts.allSatisfy { $0.content.project == nil })
        #expect(await harness.services.log.entries().allSatisfy { $0.project == nil })
    }

    @Test("PROJ-06 a link is watched in the project it points into, a number in the chosen one, an MR in its own")
    func watchesInTheRightProject() throws {
        let harness = try Harness()
        let projects = harness.projects
        let all = projects.stores.map(\.project)

        #expect(WatchTarget.project(
            of: "https://jenkins.example.com/job/client/job/MR-4/2/", among: all, chosen: .main) == Self.clientID)
        #expect(WatchTarget.project(
            of: "https://gitlab.example.com/group/client/-/merge_requests/4", among: all, chosen: .main) == Self.clientID)
        #expect(WatchTarget.project(of: "!4", among: all, chosen: Self.clientID) == Self.clientID)
        #expect(WatchTarget.project(of: "https://ci.example.org/job/x", among: all, chosen: .main) == .main)

        let mergeRequest = { (reference: String) in
            MergeRequest(
                iid: 4, title: "t", webURL: URL(string: "https://gitlab.example.com/x")!, reference: reference,
                author: MergeRequest.Person(username: "sam", name: "Sam"), updatedAt: Date(), roles: [.reviewRequested])
        }
        #expect(projects.store(forMergeRequest: mergeRequest("group/client!4"))?.projectID == Self.clientID)
        #expect(projects.store(forMergeRequest: mergeRequest("group/server!4"))?.projectID == .main)
        #expect(projects.store(forMergeRequest: mergeRequest("other/thing!4")) == nil)
        #expect(MergeRequestWatch.of(mergeRequest("group/client!4"), me: "jdoe", myJobs: [], watchedJobs: ["p-client/MR-4"],
                                     project: Self.clientID) == .watching(job: "p-client/MR-4"))
    }
}

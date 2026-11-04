import Foundation
import Testing

@testable import MenubarCore

/// One failure, one entry: GitLab's "My MR's Pipeline Failed" and the failed Jenkins build of the same merge request.
@Suite("Inbox failure matching", .timeLimit(.minutes(1)))
@MainActor
struct InboxFailureMatchingTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)
    private nonisolated static func mergeRequestURL(_ path: String = "acme/web/app", _ iid: Int = 123) -> URL {
        gitLab.appending(path: "\(path)/-/merge_requests/\(iid)")
    }

    /// the failed build of a job, with the GitLab page its Jenkins job builds
    private nonisolated static func build(
        job: String = "MR-123", number: Int = 5, kind: InboxEventKind = .buildFailed, page: URL? = mergeRequestURL(),
        at date: Date = start
    ) -> InboxEvent {
        InboxEvent.finishedBuild(
            kind: kind, jobKey: job, number: number, label: "!123 #\(number)", isUnstable: false, title: "Fix the login",
            url: URL(string: "https://jenkins.example.com/job/project/job/\(job)/\(number)/")!, at: date, isWatched: false,
            author: nil, gitLabURL: page)
    }

    /// GitLab's failed pipeline of a merge request, as the detection builds it
    private nonisolated static func pipeline(
        reference: String = "acme/web/app!123", branch: String? = "feature/login", source: InboxEvent.Source = .mergeRequests,
        at date: Date = start
    ) -> InboxEvent {
        let path = String(reference[..<reference.lastIndex(of: "!")!])
        let iid = Int(reference[reference.index(after: reference.lastIndex(of: "!")!)...])!
        return InboxEvent(
            id: "pipelineFailed|\(reference)|\(Int(date.timeIntervalSince1970))", kind: .pipelineFailed, source: source,
            title: "Fix the login", reference: reference, targetURL: mergeRequestURL(path, iid), projectPath: path, occurredAt: date,
            sourceBranch: branch)
    }

    /// GitLab's failed pipeline is Off by default; these tests are about what happens when it is on
    private nonisolated static var rules: InboxNotificationRules {
        var rules = InboxNotificationRules()
        rules.set(.inbox, for: .pipelineFailed)
        return rules
    }

    // MARK: INBOX-17

    @Test(
        "INBOX-17 a failed build and a failed pipeline are one failure when they are about the same merge request",
        arguments: [
            // the build's GitLab page is the merge request's page, with or without a trailing slash
            (InboxFailureMatchingTests.build(), InboxFailureMatchingTests.pipeline(), true),
            (InboxFailureMatchingTests.build(page: URL(string: "https://gitlab.example.com/acme/web/app/-/merge_requests/123/")), InboxFailureMatchingTests.pipeline(), true),
            // an MR job named by the iid of the reference, when the page isn't known
            (InboxFailureMatchingTests.build(page: nil), InboxFailureMatchingTests.pipeline(), true),
            (InboxFailureMatchingTests.build(page: nil), InboxFailureMatchingTests.pipeline(reference: "acme/web/app!124"), false),
            // the same number in another project is another merge request
            (InboxFailureMatchingTests.build(page: InboxFailureMatchingTests.mergeRequestURL("acme/web/app")), InboxFailureMatchingTests.pipeline(reference: "acme/other/thing!123"), false),
            // a watched build counts like mine
            (InboxFailureMatchingTests.build(kind: .watchedBuildFailed), InboxFailureMatchingTests.pipeline(), true),
            // a branch job is matched by the source branch, as the job name has it decoded
            (InboxFailureMatchingTests.build(job: "feature%252Flogin", page: nil), InboxFailureMatchingTests.pipeline(branch: "feature/login"), true),
            (InboxFailureMatchingTests.build(job: "feature%252Flogin", page: nil), InboxFailureMatchingTests.pipeline(branch: "feature/other"), false),
            (InboxFailureMatchingTests.build(job: "feature%252Flogin", page: nil), InboxFailureMatchingTests.pipeline(branch: nil), false),
            // a green build is no failure
            (InboxFailureMatchingTests.build(kind: .buildSucceeded), InboxFailureMatchingTests.pipeline(), false),
        ])
    func sameFailure(build: InboxEvent, pipeline: InboxEvent, same: Bool) {
        #expect(InboxFailureMatching.isSameFailure(build: build, pipeline: pipeline) == same)
    }

    @Test("INBOX-17 a failed pipeline isn't added when the failed build is in the Inbox, or arrives with it")
    func pipelineAfterTheBuild() {
        let pending = InboxLocalEntry(event: Self.build())
        let recentlyDone = InboxLocalEntry(event: Self.build(), doneAt: Self.start)
        let longAgo = InboxLocalEntry(event: Self.build(at: Self.start.addingTimeInterval(-3 * 3600)), doneAt: Self.start)
        let other = InboxLocalEntry(event: Self.build(job: "MR-9", page: Self.mergeRequestURL("acme/web/app", 9)))
        let pipeline = Self.pipeline()

        // Pending: dropped. Done a moment ago: dropped too, the user dealt with that failure already.
        #expect(InboxFailureMatching.apply(to: [pipeline], entries: [pending]).events.isEmpty)
        #expect(InboxFailureMatching.apply(to: [pipeline], entries: [recentlyDone]).events.isEmpty)
        // Done hours ago: a new failure. Another merge request's build: no match. No build at all: kept.
        #expect(InboxFailureMatching.apply(to: [pipeline], entries: [longAgo]).events == [pipeline])
        #expect(InboxFailureMatching.apply(to: [pipeline], entries: [other]).events == [pipeline])
        #expect(InboxFailureMatching.apply(to: [pipeline], entries: []).events == [pipeline])
        // In the same batch as the build.
        #expect(InboxFailureMatching.apply(to: [Self.build(), pipeline], entries: []).events == [Self.build()])
    }

    @Test("INBOX-17 a failed build that comes after GitLab's failed pipeline resolves that entry, but never a to-do")
    func buildAfterThePipeline() {
        let fromList = InboxLocalEntry(event: Self.pipeline())
        let done = InboxLocalEntry(event: Self.pipeline(), doneAt: Self.start)
        let fromTodo = InboxLocalEntry(event: Self.pipeline(source: .todo))
        let elsewhere = InboxLocalEntry(event: Self.pipeline(reference: "acme/web/app!124"))
        let build = Self.build()

        #expect(InboxFailureMatching.apply(to: [build], entries: [fromList]).resolve == [fromList.event.id])
        #expect(InboxFailureMatching.apply(to: [build], entries: [done]).resolve.isEmpty)
        #expect(InboxFailureMatching.apply(to: [build], entries: [fromTodo]).resolve.isEmpty)
        #expect(InboxFailureMatching.apply(to: [build], entries: [elsewhere]).resolve.isEmpty)
        // The build itself is kept.
        #expect(InboxFailureMatching.apply(to: [build], entries: [fromList]).events == [build])
    }

    // MARK: the store

    private final class World {
        let folder: TemporaryFolder
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: InboxFailureMatchingTests.gitLab.absoluteString,
                gitLabProject: "acme/web/app")))
            let now: @Sendable () -> Date = { InboxFailureMatchingTests.start }
            services = GitLabServices(
                transport: StubTransport(), clock: TestClock(), now: now, tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }),
                log: ActivityLog(folder: folder.file("logs"), now: now))
        }

        @MainActor
        func store() -> InboxStore {
            InboxStore(services: services, folder: folder.file("support"), rules: InboxFailureMatchingTests.rules)
        }
    }

    @Test("INBOX-17 the Inbox keeps one entry of a failure, whichever came first")
    func oneEntry() throws {
        let world = try World()

        // The build first: GitLab's pipeline isn't added.
        let buildFirst = world.store()
        buildFirst.addLocal(Self.build())
        buildFirst.addLocal(Self.pipeline())
        #expect(buildFirst.pending.map(\.kind) == [.buildFailed])

        // GitLab's pipeline first: the build's entry replaces it, which goes to Done.
        let pipelineFirst = try World().store()
        pipelineFirst.addLocal(Self.pipeline())
        #expect(pipelineFirst.pending.map(\.kind) == [.pipelineFailed])
        pipelineFirst.addLocal(Self.build())
        #expect(pipelineFirst.pending.map(\.kind) == [.buildFailed])
        #expect(pipelineFirst.done.map(\.kind) == [.pipelineFailed])

        // Another merge request's pipeline is its own failure.
        buildFirst.addLocal(Self.pipeline(reference: "acme/web/app!200"))
        #expect(Set(buildFirst.pending.map(\.kind)) == [.buildFailed, .pipelineFailed])
    }
}

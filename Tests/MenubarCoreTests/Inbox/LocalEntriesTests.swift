import Foundation
import Testing

@testable import MenubarCore

/// The Inbox's local entries: things of this app that never go to GitLab, like Claude's answers, the digest and failed
/// builds (Task 7.03, INBOX-10, INBOX-11).
@Suite("Inbox local entries", .timeLimit(.minutes(1)))
@MainActor
struct LocalEntriesTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    /// Monday 2026-11-02 09:00 UTC
    private nonisolated static let start = Date(timeIntervalSince1970: 1_793_610_000)
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// An inbox store like one launch of the app, on a folder that outlives it.
    @MainActor
    private final class World {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: LocalEntriesTests.gitLab.absoluteString,
                gitLabProject: "acme/web/app")))
            let now: @Sendable () -> Date = { LocalEntriesTests.start }
            services = GitLabServices(
                transport: stub, clock: TestClock(), now: now, tokens: TokenStore(keychain: keychain), team: team,
                caches: CacheStore(folder: folder.file("caches"), report: { _ in }),
                log: ActivityLog(folder: folder.file("logs"), now: now))
        }

        func store(rules: InboxNotificationRules = InboxNotificationRules()) -> InboxStore {
            InboxStore(services: services, folder: folder.file("support"), rules: rules, calendar: LocalEntriesTests.utc)
        }
    }

    private static func answer(_ id: String, at date: Date = start) -> InboxEvent {
        .claudeAnswered(
            subjectKey: id, useCase: "Why Did It Fail?", failed: false, title: "Fix the cache", reference: "acme/web/app!12",
            excerpt: "# Real failure: the cache key ignores the locale", url: gitLab.appending(path: "acme/web/app/-/merge_requests/12"),
            at: date)
    }

    // MARK: - INBOX-10

    @Test("INBOX-10 a local item is added once, kept across a relaunch, done on this Mac only, and never asks GitLab")
    func localItemsStayHere() async throws {
        let world = try World()
        let store = world.store()
        store.addLocal(Self.answer("a"))
        store.addLocal(Self.answer("a"))
        store.addLocal(.digestReady(
            summary: "Merge !42 first", url: AppRoute.open(.digest).url, at: Self.start.addingTimeInterval(60), calendar: Self.utc))

        #expect(store.pending.map(\.kind) == [.digestReady, .claudeAnswered])
        let entry = try #require(store.pending.last)
        #expect(entry.isLocalItem)
        #expect(entry.headline == "Claude answered: Why Did It Fail?")
        #expect(entry.title == "Fix the cache")
        #expect(entry.reference == "acme/web/app!12")
        #expect(entry.body == "Real failure: the cache key ignores the locale")
        #expect(entry.group == .claude)
        #expect(entry.todo == nil)
        // The digest opens the app's own Digest section; an item opens its page.
        #expect(store.pending.first?.appRoute == .open(.digest))
        #expect(entry.appRoute == nil)
        #expect(entry.targetURL?.absoluteString == "https://gitlab.example.com/acme/web/app/-/merge_requests/12")
        #expect(store.badgeCount == 2)

        // A relaunch has them, and the same id isn't added again.
        let next = world.store()
        #expect(next.pending.map(\.kind) == [.digestReady, .claudeAnswered])
        next.addLocal(Self.answer("a"))
        #expect(next.pending.count == 2)

        await next.markDone(try #require(next.pending.last))
        #expect(next.pending.map(\.kind) == [.digestReady])
        #expect(next.done.map(\.kind) == [.claudeAnswered])
        #expect(next.badgeCount == 1)
        #expect(world.stub.requests.isEmpty)
    }

    @Test("INBOX-10 the Inbox and Badge toggles of a kind decide what a local item does; off in the Inbox, it isn't added")
    func togglesApplyToLocalItems() throws {
        var rules = InboxNotificationRules()
        rules.set(.badge, false, for: .claudeAnswered)
        rules.set(.inbox, false, for: .digestReady)
        let store = try World().store(rules: rules)
        store.addLocal(Self.answer("a"))
        store.addLocal(.digestReady(summary: nil, url: AppRoute.open(.digest).url, at: Self.start, calendar: Self.utc))

        #expect(store.pending.map(\.kind) == [.claudeAnswered])
        #expect(store.badgeCount == 0)
    }

    @Test("INBOX-10 an answer that lands with its card off screen is told to the app, one with the card on screen is not")
    func answersLandOnlyOffScreen() async throws {
        let fake = ScriptedClaude([.text("The label is missing."), .text("The label is missing."), .failure])
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.askAboutItem]))
        let item = WorkItem(
            reference: "acme/web/app#31", title: "Search is slow", webURL: Self.gitLab.appending(path: "acme/web/app/-/issues/31"),
            updatedAt: Self.start)
        var landings: [AILanding] = []
        store.onAnswerLanded = { landings.append($0) }
        let subject = AISubject.workItem(item.reference)

        // The card shows: the answer is right there, nothing is added.
        store.cardAppeared(subject)
        await store.ask("What is missing?", about: item, description: nil)
        #expect(landings.isEmpty)
        store.cardDisappeared(subject)
        #expect(!store.isCardVisible(subject))

        // The user went away meanwhile: the answer, then a failure, each land once.
        await store.ask("What is missing?", about: item, description: nil)
        let answered = try #require(landings.first)
        #expect(answered.subject == subject && answered.useCase == .askAboutItem)
        #expect(answered.inboxExcerpt == "The label is missing.")
        #expect(answered.failure == nil)

        await store.ask("And now?", about: item, description: nil)
        #expect(landings.count == 2)
        #expect(landings.last?.failure != nil)
        // Two cards of one subject: it stays visible until both are gone.
        store.cardAppeared(subject)
        store.cardAppeared(subject)
        store.cardDisappeared(subject)
        #expect(store.isCardVisible(subject))
    }

    @Test("INBOX-10 the app puts an answer in the Inbox with a link back to its place, the digest once a day")
    func appPutsAnswersInTheInbox() async throws {
        let setup = try ModelSetup()
        let model = setup.model
        let at = Self.start

        model.addToInbox(AILanding(
            subject: .workItem("acme/web/app#31"), useCase: .askAboutItem, answer: nil, text: "Check the index.", failure: nil, at: at))
        model.addToInbox(AILanding(
            subject: .mergeRequest("acme/web/app!12"), useCase: .summarizeThreads, answer: nil, text: nil,
            failure: "Claude didn't answer in time.", at: at.addingTimeInterval(1)))
        model.addToInbox(AILanding(subject: .digest, useCase: .digest, answer: nil, text: "Merge !42 first.", failure: nil, at: at))
        model.addToInbox(AILanding(subject: .digest, useCase: .digest, answer: nil, text: "Again.", failure: nil, at: at.addingTimeInterval(60)))

        let rows = model.inbox.pending
        #expect(rows.count == 3)
        let item = try #require(rows.first { $0.reference == "acme/web/app#31" })
        #expect(item.headline == "Claude answered: Question About a Work Item")
        #expect(item.targetURL?.absoluteString == "https://gitlab.example.com/acme/web/app/-/work_items/31")
        let failed = try #require(rows.first { $0.reference == "acme/web/app!12" })
        #expect(failed.headline == "Claude couldn't answer: Summarize Discussion")
        #expect(failed.body == "Claude didn't answer in time.")
        #expect(failed.targetURL?.absoluteString == "https://gitlab.example.com/acme/web/app/-/merge_requests/12")
        let digest = try #require(rows.first { $0.kind == .digestReady })
        #expect(digest.appRoute == .open(.digest))
        #expect(digest.title == "Your digest is ready")
        #expect(digest.body == "Merge !42 first.")
    }

    // MARK: - INBOX-11

    private static func alert(
        _ result: BuildResult, job: String = "MR-12501", number: Int = 5, kind: JobKind = .mine, author: String? = nil
    ) throws -> BuildAlert {
        let build = Build(
            job: job, number: number, title: "Fix the login", author: author, kind: kind, phase: .finished(result: result, duration: 600),
            startedAt: start.addingTimeInterval(-600))
        let jobURL = try #require(URL(string: "https://jenkins.example.com/job/project"))
        let content = try #require(AlertContent.finished(build, failedStages: [], links: AlertContent.links(for: build, jobURL: jobURL)))
        return BuildAlert(kind: .finished, build: build, content: content)
    }

    @Test("INBOX-11 a failed or unstable build goes into the Inbox once, with a link to the build, and a green build of its job clears it")
    func failedBuilds() async throws {
        let setup = try ModelSetup()
        let model = setup.model

        model.addToInbox(finished: [try Self.alert(.failure), try Self.alert(.unstable, number: 6), try Self.alert(.aborted, number: 7)])
        model.addToInbox(finished: [try Self.alert(.failure)])
        model.addToInbox(finished: [try Self.alert(.failure, job: "MR-12502", number: 1)])

        let rows = model.inbox.pending.sorted { $0.headline < $1.headline }
        #expect(rows.map(\.headline) == ["Build !12501 #5 failed", "Build !12501 #6 went unstable", "Build !12502 #1 failed"])
        let first = try #require(rows.first)
        #expect(first.kind == .buildFailed && first.isLocalItem)
        #expect(first.targetURL?.absoluteString == "https://jenkins.example.com/job/project/job/MR-12501/5/")
        #expect(first.title == "Fix the login")

        // Green again: the entries of that job are done, the other job's stay.
        model.addToInbox(finished: [try Self.alert(.success, number: 8)])
        #expect(model.inbox.pending.map(\.headline) == ["Build !12502 #1 failed"])
        #expect(model.inbox.done.count == 2)
    }

    @Test("ALERT-11 the Inbox entry of a watched build's failure is marked")
    func watchedFailedBuild() async throws {
        let model = try ModelSetup().model
        model.addToInbox(finished: [
            try Self.alert(.failure, kind: .watched, author: "Sam Lee"),
            try Self.alert(.unstable, job: "MR-12502", number: 1, kind: .watched),
            try Self.alert(.failure, job: "MR-12503", number: 2),
        ])
        let rows = model.inbox.pending.sorted { $0.headline < $1.headline }
        #expect(
            rows.map(\.headline) == [
                "Build !12503 #2 failed", "Watching · Build !12501 #5 failed", "Watching · Build !12502 #1 went unstable",
            ])
        #expect(rows.map(\.body) == ["", "by Sam Lee", ""])
    }

    /// An app model on fakes, with a claude that is never asked.
    @MainActor
    private struct ModelSetup {
        let folder: TemporaryFolder
        let defaults = TemporaryDefaults()
        let model: AppModel

        init() throws {
            folder = try TemporaryFolder()
            let team = TeamValues(
                jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
                gitLabProject: "acme/web/app")
            try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
                .save(Project(id: .main, team: team))
            model = AppModel(
                dependencies: .fake(
                    root: folder.url, defaults: defaults.defaults, now: { LocalEntriesTests.start },
                    processRunner: ScriptedClaude([.failure])))
        }
    }
}

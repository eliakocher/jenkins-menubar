import Foundation
import Testing

@testable import MenubarCore

/// Loading every slot label GitLab has (SLOT-02).
@Suite("Slot labels")
@MainActor
struct SlotLabelsStoreTests {
    private nonisolated static let start = Date(timeIntervalSinceReferenceDate: 813_000_000)  // late 2026

    private struct World {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let services: GitLabServices

        init(prefix: String = "slot::") throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: TeamValues(
                gitLabURL: "https://gitlab.example.com", gitLabProject: "acme/shop", slotLabelPrefix: prefix)))
            let log = ActivityLog(folder: folder.file("logs"), now: { SlotLabelsStoreTests.start })
            services = GitLabServices(
                transport: stub, clock: ContinuousClock(), now: { SlotLabelsStoreTests.start }, tokens: TokenStore(keychain: keychain),
                team: team, caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: log)
        }

        func answer(_ titles: [String]) {
            let nodes = titles.map { ##"{"title": "\##($0)", "color": "#9400d3"}"## }.joined(separator: ",")
            stub.answer(operation: "Labels", body: #"{"data": {"project": {"labels": {"nodes": [\#(nodes)]}}}}"#)
        }
    }

    @Test("SLOT-02 the slot labels come from GitLab for this and the next year, and a failed load keeps the cached ones")
    func loadsAndKeeps() async throws {
        let world = try World()
        world.answer(["slot::2026.45", "slot::2026.48", "slot::2026.45 extra", "bug"])
        let store = SlotLabelsStore(services: world.services)
        await store.load()
        #expect(store.labels.map(\.title) == ["slot::2026.45", "slot::2026.48"])
        #expect(store.labels.first?.color == "#9400d3")
        #expect(store.problem == nil)
        // one request per year, searched by prefix and year
        #expect(world.stub.requests(operation: "Labels").count == 2)
        let variables = world.stub.requests(operation: "Labels").compactMap { $0.graphQL?.variables }.joined()
        #expect(variables.contains("slot::2027."))

        // the cache is there at the next start, and a recent answer isn't asked again
        let again = SlotLabelsStore(services: world.services)
        #expect(again.labels.count == 2)
        await again.load()
        #expect(world.stub.requests(operation: "Labels").count == 2)

        // GitLab doesn't answer: the labels stay, with a note
        let down = StubTransport()
        down.fail(operation: "Labels", with: .cannotConnect)
        var services = world.services
        services.transport = down
        let failing = SlotLabelsStore(services: services)
        await failing.load(force: true)
        #expect(failing.labels.count == 2)
        #expect(failing.problem == SlotLabelsStore.noAnswerProblem)
    }

    @Test("SLOT-02 without a slot prefix nothing is asked")
    func noPrefix() async throws {
        let world = try World(prefix: "")
        world.answer(["slot::2026.45"])
        let store = SlotLabelsStore(services: world.services)
        await store.load()
        #expect(store.labels.isEmpty)
        #expect(world.stub.requests.isEmpty)
    }
}

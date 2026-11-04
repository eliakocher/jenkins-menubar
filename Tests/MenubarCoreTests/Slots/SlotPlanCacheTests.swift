import Foundation
import Observation
import Testing

@testable import MenubarCore

@Observable @MainActor
private final class CacheSource {
    var value = 1
    var unrelated = 0
}

/// The Slots page makes its plan once, not in every draw: scrolling and hovering never rebuild it (SLOT-02).
@Suite("Slot plan cache")
@MainActor
struct SlotPlanCacheTests {
    private nonisolated static let start = Date(timeIntervalSinceReferenceDate: 813_000_000)  // late 2026, 17:20 UTC
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("SLOT-02 a value is made once per key, and again only after something it read changed")
    func makesOnceUntilItsInputChanges() {
        let cache = ObservedCache()
        let source = CacheSource()
        let read = { cache.value(for: "double") { source.value * 2 } }

        #expect(read() == 2)
        #expect(read() == 2)
        #expect(read() == 2)
        #expect(cache.makes == 1)
        // a hover or a scroll changes nothing the value read
        source.unrelated += 1
        #expect(read() == 2)
        #expect(cache.makes == 1)

        let generation = cache.generation
        source.value = 5
        #expect(cache.generation > generation)
        #expect(read() == 10)
        #expect(read() == 10)
        #expect(cache.makes == 2)

        // another key is its own value
        #expect(cache.value(for: "triple") { source.value * 3 } == 15)
        #expect(cache.makes == 3)
    }

    @Test("SLOT-02 a value made from another key of the same cache is forgotten after a change, without a crash")
    func nestedReadForgetsSafely() {
        let cache = ObservedCache()
        let source = CacheSource()
        let inner = { cache.value(for: "inner") { source.value } }
        let outer = { cache.value(for: "outer") { inner() + 1 } }

        #expect(outer() == 2)
        source.value = 5
        #expect(outer() == 6)
        source.value = 7
        #expect(outer() == 8)
        #expect(cache.makes == 6)
    }

    @Test("SLOT-02 the plan is made once for the same chips and day, again for another day or chips, and after the data changed")
    func planIsMadeOncePerInput() async throws {
        let folder = try TemporaryFolder()
        let defaults = TemporaryDefaults()
        let stub = StubTransport()
        try TeamStore(folder: FileLocations(root: folder.url).applicationSupport, report: { _ in })
            .save(Project(id: .main, team: TeamValues(
                gitLabURL: Self.gitLab.absoluteString, gitLabProject: "acme/shop", slotLabelPrefix: "slot::")))
        let model = AppModel(
            dependencies: .fake(
                root: folder.url, defaults: defaults.defaults, transport: stub, clock: ContinuousClock(),
                now: { Self.start },
                keychain: InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])))
        let calendar = Self.calendar
        let plan = { (chips: SlotChipSelection, now: Date) in model.slotPlan(chips: chips, now: now, calendar: calendar) }

        _ = plan(.everyone, Self.start)
        let made = model.slotCache.makes
        #expect(made > 0)
        // the minute's tick and every redraw of the same day
        for minutes in 1...5 {
            _ = plan(.everyone, Self.start.addingTimeInterval(Double(minutes) * 60))
        }
        _ = model.slotChips
        let afterChips = model.slotCache.makes
        _ = model.slotChips
        #expect(model.slotCache.makes == afterChips)
        #expect(afterChips == made + 1)

        // another day is another plan
        _ = plan(.everyone, Self.start.addingTimeInterval(86400))
        #expect(model.slotCache.makes > afterChips)
        // so are other chips
        let beforeChips = model.slotCache.makes
        _ = plan(SlotChipSelection([.me]), Self.start)
        #expect(model.slotCache.makes > beforeChips)

        // new data: the labels GitLab has arrive
        let beforeLoad = model.slotCache.makes
        let titles = ["slot::2026.45", "slot::2026.48"].map { ##"{"title": "\##($0)", "color": "#9400d3"}"## }.joined(separator: ",")
        stub.answer(operation: "Labels", body: #"{"data": {"project": {"labels": {"nodes": [\#(titles)]}}}}"#)
        await model.slotLabels.load(force: true)
        let rebuilt = plan(.everyone, Self.start)
        #expect(model.slotCache.makes > beforeLoad)
        #expect(rebuilt.slots.contains { $0.name.description == "2026.45" })
        let afterLoad = model.slotCache.makes
        _ = plan(.everyone, Self.start)
        #expect(model.slotCache.makes == afterLoad)
    }

    // MARK: - Teams read once

    private static func item(_ number: Int, assignees: [String], labels: [String] = []) -> WorkItem {
        WorkItem(
            reference: "acme/shop#\(number)", title: "Item \(number)", webURL: gitLab.appending(path: "acme/shop/-/issues/\(number)"),
            state: .opened, labels: labels.map { Label(title: $0) }, updatedAt: start,
            assignees: assignees.map { MergeRequest.Person(username: $0, name: $0.capitalized) })
    }

    @Test("SLOT-13 filtering many items by the chips gives what asking per item gives")
    func filterMatchesPerItem() {
        var team = TeamValues(
            gitLabURL: Self.gitLab.absoluteString, gitLabProject: "acme/shop", slotLabelPrefix: "slot::",
            squadLabelPrefix: "squad::")
        team.slotTeams = "Alpha: user1, user2; Bravo: user3"
        let items = [
            Self.item(1, assignees: ["user1"], labels: ["squad::Alpha"]), Self.item(2, assignees: ["user3"], labels: ["squad::Alpha"]),
            Self.item(3, assignees: ["USER2"]), Self.item(4, assignees: []), Self.item(5, assignees: ["me1"], labels: ["squad::Bravo"]),
        ]
        let chips: [[SlotChip]] = [
            [], [.me], [.team("Alpha")], [.team("Alpha"), .team("Bravo")], [.team("Alpha"), .squad("Alpha")],
            [.me, .squad("Bravo")], [.openBugs],
        ]
        let selections = chips.map { SlotChipSelection($0) }
        for selection in selections {
            let expected = items.filter { selection.matches($0, team: team, me: "me1") }
            #expect(selection.filter(items, team: team, me: "me1") == expected)
        }
        #expect(SlotChipSelection([.team("Alpha")]).filter(items, team: team, me: nil).map(\.reference) == ["acme/shop#1", "acme/shop#3"])
    }

    // MARK: - Header numbers

    @Test("SLOT-15 the header's numbers come with the plan, and follow the items when they change")
    func headerFactsFollowTheItems() throws {
        let team = TeamValues(
            gitLabURL: Self.gitLab.absoluteString, gitLabProject: "acme/shop", slotLabelPrefix: "slot::",
            statusLabelPrefix: "status::")
        let items = [
            Self.item(1, assignees: ["user1"], labels: ["slot::2026.45", "status::Verified"]),
            Self.item(2, assignees: ["user2"], labels: ["slot::2026.45"]),
        ]
        let plan = SlotPlan.make(
            workItems: items, mergeRequests: { _ in nil }, build: { _ in nil }, team: team, today: Self.start,
            calendar: Self.calendar)
        var slot = try #require(plan.slots.first { $0.name.description == "2026.45" })
        #expect(slot.headerCache.facts != nil)
        let header = slot.header
        #expect(header == SlotHeaderFacts(slot))
        #expect(header.membersText == "2 members")
        #expect(header.counters.first?.text == "1/2")
        #expect(header.hasItems)

        // a slot with fewer items has its own numbers: the cache doesn't outlive its items
        slot.items = Array(slot.items.prefix(1))
        #expect(slot.headerCache.facts == nil)
        #expect(slot.header.membersText == "1 member")
        #expect(slot.header.counters.first?.text.hasSuffix("/1") == true)
    }
}

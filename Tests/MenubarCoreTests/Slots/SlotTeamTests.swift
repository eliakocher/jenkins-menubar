import Foundation
import Testing

@testable import MenubarCore

/// The slot group's issues, the chips, the load and the epics of the Slots section (SLOT-06 to SLOT-08), with made-up
/// squads and slots.
@Suite("Slot team")
@MainActor
struct SlotTeamTests {
    private nonisolated static let start = Date(timeIntervalSinceReferenceDate: 813_000_000)  // late 2026
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private nonisolated static var team: TeamValues {
        TeamValues(
            gitLabURL: gitLab.absoluteString, gitLabProject: "acme/shop", committedLabel: "commitment::Committed",
            slotLabelPrefix: "slot::", typeLabelPrefix: "type::", slotGroup: "acme", slotScheduledLabelPrefix: "slot-scheduled::",
            squadLabelPrefix: "squad::", statusLabelPrefix: "status::", squadCapacity: "Alpha: 20, 10")
    }

    private static func item(
        _ number: Int, labels: [String], closed: Bool = false, weight: Int? = nil, epic: Int? = nil, assignees: [String] = []
    ) -> WorkItem {
        WorkItem(
            reference: "acme/shop#\(number)", title: "Item \(number)", webURL: gitLab.appending(path: "acme/shop/-/issues/\(number)"),
            state: closed ? .closed : .opened, labels: labels.map { Label(title: $0) }, updatedAt: start,
            assignees: assignees.map { MergeRequest.Person(username: $0, name: $0.capitalized) }, weight: weight,
            epic: epic.map {
                WorkItemEpic(reference: "acme&\($0)", title: "Epic \($0)", webURL: gitLab.appending(path: "groups/acme/-/epics/\($0)"))
            })
    }

    private static func plan(_ items: [WorkItem], capacity: Int? = nil) -> SlotPlan {
        SlotPlan.make(
            workItems: items, mergeRequests: { _ in nil }, build: { _ in nil }, team: team, capacity: capacity,
            today: start, calendar: calendar)
    }

    // MARK: - SLOT-06

    private struct World {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let services: GitLabServices

        init() throws {
            folder = try TemporaryFolder()
            let keychain = InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])
            let team = TeamStore(folder: folder.file("support"), report: { _ in })
            try team.save(Project(id: .main, team: SlotTeamTests.team))
            let log = ActivityLog(folder: folder.file("logs"), now: { SlotTeamTests.start })
            services = GitLabServices(
                transport: stub, clock: ContinuousClock(), now: { SlotTeamTests.start }, tokens: TokenStore(keychain: keychain),
                team: team, caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: log)
        }

        static func page(_ nodes: [String], next: String?) -> String {
            let info = next.map { #"{"hasNextPage": true, "endCursor": "\#($0)"}"# } ?? #"{"hasNextPage": false, "endCursor": null}"#
            return #"{"data": {"group": {"issues": {"count": 3, "pageInfo": \#(info), "nodes": [\#(nodes.joined(separator: ","))]}}}}"#
        }
    }

    private static let firstNode = """
        {"title": "Faster search", "webUrl": "https://gitlab.example.com/acme/shop/-/issues/7", "reference": "acme/shop#7",
         "updatedAt": "2026-10-28T09:00:00Z", "type": "ISSUE", "state": "opened", "weight": 5, "dueDate": "2026-11-02",
         "blocked": true, "labels": {"nodes": [{"title": "slot::2026.45", "color": "#9400d3"}, {"title": "squad::Alpha"}]},
         "assignees": {"nodes": [{"username": "alex", "name": "Alex Doe"}]},
         "epic": {"reference": "acme/plan&3", "title": "Search", "webUrl": "https://gitlab.example.com/groups/acme/plan/-/epics/3",
                  "state": "opened", "labels": {"nodes": [{"title": "squad::Alpha"}]}}}
        """
    private static let secondNode = """
        {"title": "Old bug", "webUrl": "https://gitlab.example.com/acme/shop/-/issues/8", "reference": "acme/shop#8",
         "updatedAt": "2026-10-28T09:00:00Z", "state": "closed", "weight": null, "blocked": false, "epic": null,
         "labels": {"nodes": []}, "assignees": {"nodes": []}}
        """

    @Test("SLOT-06 reads the slot group's issues page by page, with weight, epic, blocked, assignees and due date, and keeps them when GitLab fails")
    func readsPages() async throws {
        let world = try World()
        world.stub.answer(operation: "SlotItems", body: World.page([Self.secondNode, "{\"broken\": 1}"], next: nil))
        world.stub.answer(operation: "SlotItems", times: 1, body: World.page([Self.firstNode], next: "c1"))
        let store = SlotItemsStore(services: world.services)
        await store.load(slots: [SlotName("2026.45")!])

        #expect(store.problem == nil)
        #expect(store.items.map(\.reference) == ["acme/shop#7", "acme/shop#8"])
        let first = try #require(store.items.first)
        #expect(first.weight == 5 && first.isBlocked == true && first.dueDate == "2026-11-02")
        #expect(first.assignees?.map(\.username) == ["alex"])
        #expect(first.epic?.reference == "acme/plan&3" && first.epic?.labels.map(\.title) == ["squad::Alpha"])
        #expect(store.items.last?.weight == nil && store.items.last?.epic == nil && store.items.last?.state == .closed)
        let variables = world.stub.requests(operation: "SlotItems").compactMap { $0.graphQL?.variables }
        #expect(variables.count == 2)
        #expect(variables[0].contains(#""slot::2026.45","slot-scheduled::2026.45""#) && variables[0].contains(#""after":null"#))
        #expect(variables[1].contains(#""after":"c1""#))

        // the cache is there at the next start; GitLab failing keeps the items, with a note
        let down = StubTransport()
        down.fail(operation: "SlotItems", with: .cannotConnect)
        var services = world.services
        services.transport = down
        let failing = SlotItemsStore(services: services)
        #expect(failing.items.count == 2)
        await failing.load(slots: [SlotName("2026.45")!], force: true)
        #expect(failing.items.count == 2)
        #expect(failing.problem != nil)
    }

    @Test("SLOT-06 an item's slot is its slot label's, else its scheduled one's, which makes it planned")
    func plannedItems() throws {
        let items = [
            Self.item(1, labels: ["slot::2026.45", "commitment::Committed"], weight: 3),
            Self.item(2, labels: ["slot-scheduled::2026.45"], weight: 8),
            Self.item(3, labels: ["slot::2026.45", "slot-scheduled::2026.42", "commitment::Committed"]),
            Self.item(4, labels: ["slot-scheduled::2026.48"]),
        ]
        let plan = Self.plan(items)
        let slot = try #require(plan.slots.first { $0.name.description == "2026.45" })
        #expect(slot.items.map(\.workItem.reference) == ["acme/shop#1", "acme/shop#3"])
        #expect(slot.planned.map(\.workItem.reference) == ["acme/shop#2"])
        #expect(slot.planned.first?.isCommitted == false)
        #expect(slot.committedPoints == 3 && slot.unweightedCount == 1)
        // a slot only a scheduled label names still shows
        #expect(plan.slots.contains { $0.name.description == "2026.48" && $0.planned.count == 1 })
    }

    // MARK: - SLOT-07

    @Test("SLOT-07 the chips: Me, Everyone, the squads from the labels, Triage, Remaining Work and Open Bugs")
    func chips() {
        let team = Self.team
        let mine = Self.item(1, labels: ["squad::Alpha", "status::Triage"], assignees: ["alex"])
        let remaining = Self.item(2, labels: ["commitment::Committed", "status::InProgress", "squad::Bravo"])
        let verified = Self.item(3, labels: ["commitment::Committed", "status::Verified"])
        let bug = Self.item(4, labels: ["type::Bug", "status::MaintainerTriage"])
        let closedBug = Self.item(5, labels: ["type::Bug", "commitment::Committed"], closed: true)
        let all = [mine, remaining, verified, bug, closedBug]

        #expect(SlotChip.squads(of: all, prefix: "squad::") == ["Alpha", "Bravo"])
        #expect(SlotChip.chips(squads: ["Alpha"]).map(\.title) == ["Me", "Everyone", "Alpha", "Triage", "Remaining Work", "Open Bugs"])
        func matching(_ chip: SlotChip, me: String? = "alex") -> [Int] {
            all.filter { chip.matches($0, team: team, me: me) }.compactMap { Int($0.reference.split(separator: "#").last!) }
        }
        #expect(matching(.me) == [1])
        #expect(matching(.me, me: nil).isEmpty)
        #expect(matching(.all) == [1, 2, 3, 4, 5])
        #expect(matching(.squad("Alpha")) == [1])
        #expect(matching(.triage) == [1, 4])
        #expect(matching(.remainingWork) == [2])
        #expect(matching(.openBugs) == [4])
    }

    // MARK: - SLOT-08

    @Test(
        "SLOT-08 the squad capacity reads names with points, or one number for every other squad",
        arguments: [
            ("Alpha: 60, Delta: 120", ["Alpha": 60, "Delta": 120, "Bravo": nil] as [String: Int?]),
            ("Alpha=60; 30", ["Alpha": 60, "alpha": 60, "Bravo": 30]),
            ("40", ["Alpha": 40]),
        ])
    func capacity(text: String, points: [String: Int?]) throws {
        let capacity = try #require(SquadCapacity(text))
        for (squad, expected) in points {
            #expect(capacity.points(of: squad) == expected, "\(squad)")
        }
    }

    @Test("SLOT-08 a squad capacity that isn't names with points is refused", arguments: ["", "Alpha", "Alpha: -3", "Alpha: x", "10, 20", ": 5"])
    func invalidCapacity(text: String) {
        #expect(SquadCapacity(text) == nil)
        if !text.isEmpty {
            #expect(SettingsStore.issue(of: text, for: .squadCapacity) != nil)
        }
    }

    @Test("SLOT-08 the load is the committed weight over the chip's capacity: a squad's, the sum for Everyone, none for the rest")
    func load() {
        let capacity = SquadCapacity("Alpha: 20, 10")
        #expect(SlotChip.squad("Alpha").capacity(capacity, squads: ["Alpha", "Bravo"]) == 20)
        #expect(SlotChip.squad("Bravo").capacity(capacity, squads: ["Alpha", "Bravo"]) == 10)
        #expect(SlotChip.all.capacity(capacity, squads: ["Alpha", "Bravo"]) == 30)
        #expect(SlotChip.me.capacity(capacity, squads: ["Alpha"]) == nil)
        #expect(SlotChip.all.capacity(nil, squads: ["Alpha"]) == nil)

        let items = [
            Self.item(1, labels: ["slot::2026.45", "commitment::Committed"], closed: true, weight: 5, assignees: ["alex", "jane"]),
            Self.item(2, labels: ["slot::2026.45", "commitment::Committed"], weight: 10, assignees: ["jane"]),
            Self.item(3, labels: ["slot-scheduled::2026.45"], weight: 13, assignees: ["sam"]),
        ]
        let slot = Self.plan(items, capacity: 20).slots.first { $0.name.description == "2026.45" }
        #expect(slot?.committedPoints == 15)
        #expect(slot?.load == 0.75)
        #expect(slot?.members.map(\.username) == ["jane", "alex", "sam"])
        #expect(Self.plan(items).slots.first?.load == nil)
    }

    @Test("SLOT-08 the items group by epic: epics with open items first, no epic last, progress by weight")
    func epics() {
        let items = [
            Self.item(1, labels: ["slot::2026.45", "commitment::Committed"], weight: 3, epic: 9),
            Self.item(2, labels: ["slot::2026.45", "commitment::Committed"], closed: true, weight: 1, epic: 9),
            Self.item(3, labels: ["slot::2026.45", "commitment::Committed"], closed: true, epic: 2),
            Self.item(4, labels: ["slot::2026.45", "commitment::Committed"]),
            Self.item(5, labels: ["slot-scheduled::2026.45"], epic: 9),
        ]
        let groups = Self.plan(items).slots.first { $0.name.description == "2026.45" }?.epicGroups ?? []
        #expect(groups.map { $0.epic?.title } == ["Epic 9", "Epic 2", nil])
        // open before done; planned items join their epic
        #expect(groups[0].items.map(\.workItem.reference) == ["acme/shop#1", "acme/shop#5", "acme/shop#2"])
        // done weight 1 of 3 + 1 + 1 (the planned item has no weight and counts 1)
        #expect(groups[0].progress == 0.2)
        #expect(groups[1].progress == 1)
    }
}

import Foundation
import Testing

@testable import MenubarCore

/// The slot group's issues, the chips, the load, the epics and the planning rules of the Slots section (SLOT-06 to
/// SLOT-08, SLOT-10 to SLOT-13), with made-up teams and slots.
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
            squadLabelPrefix: "squad::", statusLabelPrefix: "status::", squadCapacity: "Alpha: 20, 10",
            blockedLabel: "prerequisite::Blocked", sizeLabelPrefix: "size::", priorityLabelPrefix: "priority::")
    }

    /// an item of the slot group's query (which always says whether it is blocked), or of another one
    private static func item(
        _ number: Int, labels: [String], closed: Bool = false, weight: Int? = nil, epic: Int? = nil, assignees: [String] = [],
        fromGroup: Bool = true
    ) -> WorkItem {
        WorkItem(
            reference: "acme/shop#\(number)", title: "Item \(number)", webURL: gitLab.appending(path: "acme/shop/-/issues/\(number)"),
            state: closed ? .closed : .opened, labels: labels.map { Label(title: $0) }, updatedAt: start,
            assignees: assignees.map { MergeRequest.Person(username: $0, name: $0.capitalized) }, weight: weight,
            epic: epic.map {
                WorkItemEpic(
                    reference: "acme&\($0)", title: "Epic \($0)", webURL: gitLab.appending(path: "groups/acme/-/epics/\($0)"),
                    labels: [Label(title: "size::M")])
            },
            isBlocked: fromGroup ? false : nil)
    }

    private static func plan(
        _ items: [WorkItem], capacity: SlotCapacity? = nil, team: TeamValues = team, epicWeights: [String: Int] = [:]
    ) -> SlotPlan {
        SlotPlan.make(
            workItems: items, mergeRequests: { _ in nil }, build: { _ in nil }, team: team, capacity: capacity,
            epicWeights: epicWeights, today: start, calendar: calendar)
    }

    private static func slot(_ plan: SlotPlan, _ name: String = "2026.45") -> SlotSummary? {
        plan.slots.first { $0.name.description == name }
    }

    /// `[number: value]` of a slot's items
    private static func numbers<Value>(_ items: [SlotItem], _ value: (SlotItem) -> Value) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: items.map { (Int($0.workItem.reference.split(separator: "#").last!)!, value($0)) })
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
         "blocked": true, "labels": {"nodes": [{"title": "slot-scheduled::2026.45", "color": "#9400d3"}, {"title": "squad::Alpha"}]},
         "assignees": {"nodes": [{"username": "alex", "name": "Alex Doe"}]},
         "epic": {"reference": "acme/plan&3", "title": "Search", "webUrl": "https://gitlab.example.com/groups/acme/plan/-/epics/3",
                  "state": "opened", "labels": {"nodes": [{"title": "squad::Alpha"}]},
                  "descendantWeightSum": {"openedIssues": 8, "closedIssues": 5}}}
        """
    private static let secondNode = """
        {"title": "Old bug", "webUrl": "https://gitlab.example.com/acme/shop/-/issues/8", "reference": "acme/shop#8",
         "updatedAt": "2026-10-28T09:00:00Z", "state": "closed", "weight": null, "blocked": false, "epic": null,
         "labels": {"nodes": []}, "assignees": {"nodes": []}}
        """

    @Test("SLOT-06 reads the slot group's issues page by page by the scheduled slot label, with weight, epic and the weight under it, blocked, assignees and due date, and keeps them when GitLab fails")
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
        #expect(store.epicWeights == ["acme/plan&3": 13])
        #expect(store.items.last?.weight == nil && store.items.last?.epic == nil && store.items.last?.state == .closed)
        let variables = world.stub.requests(operation: "SlotItems").compactMap { $0.graphQL?.variables }
        #expect(variables.count == 2)
        // one label, the scheduled slot's: not the due slot's too
        #expect(variables[0].contains(#"["slot-scheduled::2026.45"]"#) && variables[0].contains(#""after":null"#))
        #expect(variables[1].contains(#""after":"c1""#))

        // the cache is there at the next start; GitLab failing keeps the items, with a note
        let down = StubTransport()
        down.fail(operation: "SlotItems", with: .cannotConnect)
        var services = world.services
        services.transport = down
        let failing = SlotItemsStore(services: services)
        #expect(failing.items.count == 2)
        #expect(failing.epicWeights == ["acme/plan&3": 13])
        await failing.load(slots: [SlotName("2026.45")!], force: true)
        #expect(failing.items.count == 2)
        #expect(failing.problem != nil)

        // a GitLab that doesn't know the epics' weight is asked again without it
        let older = StubTransport()
        older.answer(operation: "SlotItems", body: World.page([Self.secondNode], next: nil))
        older.answer(
            operation: "SlotItems", times: 1,
            body: #"{"errors": [{"message": "Field 'descendantWeightSum' doesn't exist on type 'Epic'"}]}"#)
        services.transport = older
        let retried = SlotItemsStore(services: services)
        await retried.load(slots: [SlotName("2026.45")!], force: true)
        #expect(retried.problem == nil)
        let queries = older.requests(operation: "SlotItems").map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(queries.map { $0.contains("descendantWeightSum") } == [true, false])
    }

    @Test("SLOT-06 an item's slot is its scheduled slot label's alone; committed by the committed label, else planned")
    func plannedItems() throws {
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45", "slot::2026.45", "commitment::Committed"], weight: 3),
            Self.item(2, labels: ["slot-scheduled::2026.45"], weight: 8),
            // due in 2026.45, scheduled earlier: the tool shows it in 2026.42
            Self.item(3, labels: ["slot::2026.45", "slot-scheduled::2026.42", "commitment::Committed"]),
            Self.item(4, labels: ["slot-scheduled::2026.48"]),
            // a due label alone is no slot
            Self.item(5, labels: ["slot::2026.45", "commitment::Committed"]),
        ]
        let plan = Self.plan(items)
        let slot = try #require(Self.slot(plan))
        #expect(slot.items.map(\.workItem.reference) == ["acme/shop#1"])
        #expect(slot.planned.map(\.workItem.reference) == ["acme/shop#2"])
        #expect(slot.planned.first?.isCommitted == false)
        #expect(slot.committedPoints == 3 && slot.points == 11)
        let earlier = try #require(Self.slot(plan, "2026.42"))
        #expect(earlier.items.map(\.workItem.reference) == ["acme/shop#3"])
        #expect(earlier.items.first?.dueSlot?.description == "2026.45")
        #expect(slot.items.first?.dueSlot == nil)
        #expect(plan.withoutSlot == 1)
        // a slot only a scheduled label names still shows
        #expect(Self.slot(plan, "2026.48")?.planned.count == 1)
        // without a scheduled prefix in Team, the slot label is the slot
        var single = Self.team
        single.slotScheduledLabelPrefix = ""
        #expect(SlotPlan.slot(of: items[4], team: single)?.description == "2026.45")
        #expect(SlotPlan.slot(of: items[2], team: Self.team)?.description == "2026.42")
        #expect(SlotPlan.dueSlot(of: items[2], team: single) == nil)
    }

    // MARK: - SLOT-07

    @Test("SLOT-07 the chips: Everyone, Triage, Remaining Work (Todo or InProgress), Open Bugs, Me and the squads from the labels")
    func chips() {
        let team = Self.team
        let mine = Self.item(1, labels: ["squad::Alpha", "status::Triage"], assignees: ["alex"])
        let remaining = Self.item(2, labels: ["commitment::Committed", "status::InProgress", "squad::Bravo"])
        let verified = Self.item(3, labels: ["commitment::Committed", "status::Verified"])
        let bug = Self.item(4, labels: ["type::Bug", "status::MaintainerTriage"])
        let closedBug = Self.item(5, labels: ["type::Bug", "commitment::Committed"], closed: true)
        let plannedTodo = Self.item(6, labels: ["status::Todo"])
        let inVerification = Self.item(7, labels: ["commitment::Committed", "status::InVerification"])
        let all = [mine, remaining, verified, bug, closedBug, plannedTodo, inVerification]

        #expect(SlotChip.squads(of: all, prefix: "squad::") == ["Alpha", "Bravo"])
        #expect(SlotChip.chips(squads: ["Alpha"]).map(\.id) == ["all", "triage", "remaining", "bugs", "me", "squad:Alpha"])
        func matching(_ chip: SlotChip, me: String? = "alex") -> [Int] {
            all.filter { chip.matches($0, team: team, me: me) }.compactMap { Int($0.reference.split(separator: "#").last!) }
        }
        #expect(matching(.me, me: nil).isEmpty)
        #expect(matching(.squad("Alpha")) == [1])
        #expect(matching(.triage) == [1, 4])
        // the status alone, committed or not
        #expect(matching(.remainingWork) == [2, 6])
        #expect(matching(.openBugs) == [4])
    }

    @Test(
        "SLOT-07 the remembered chip stays; a gone squad becomes the team of its name, a gone team its squad, else Me",
        arguments: [
            // id, whether the teams are set (else the squads Alpha and Bravo), the id of the chip it reads as
            ("squad:Bravo", false, "squad:Bravo"),
            ("team:Delta", true, "team:Delta"),
            ("triage", true, "triage"),
            ("bugs", false, "bugs"),
            // teams now set instead of squads: the squad's name finds its team, the case doesn't count
            ("squad:Alpha", true, "team:Alpha"),
            ("squad:alpha", true, "team:Alpha"),
            // the other way, when Team's teams are cleared
            ("team:Bravo", false, "squad:Bravo"),
            // gone altogether, or not an id
            ("squad:Bravo", true, "me"),
            ("team:Charlie", true, "me"),
            ("garbage", true, "me"),
        ] as [(String, Bool, String)])
    func restoredChip(id: String, withTeams: Bool, expected: String) {
        let chips = withTeams
            ? SlotChip.chips(squads: ["Alpha", "Bravo"], teams: ["Alpha", "Delta"]) : SlotChip.chips(squads: ["Alpha", "Bravo"])
        #expect(SlotChip.restored(id: id, among: chips).id == expected)
    }

    // MARK: - SLOT-07 combined chips

    @Test("SLOT-07 chips of one field are alternatives, different fields narrow down, Everyone shows all")
    func combinedChips() {
        var team = Self.team
        team.slotTeams = "Alpha: user1; Bravo: user2"
        let alphaBug = Self.item(1, labels: ["type::Bug", "status::Todo"], assignees: ["user1"])
        let alphaStory = Self.item(2, labels: ["status::Triage"], assignees: ["user1"])
        let bravoBug = Self.item(3, labels: ["type::Bug"], assignees: ["user2"])
        let closedAlphaBug = Self.item(4, labels: ["type::Bug"], closed: true, assignees: ["user1"])
        let mine = Self.item(5, labels: ["status::InProgress"], assignees: ["me1"])
        let nobody = Self.item(6, labels: ["status::Triage"])
        let all = [alphaBug, alphaStory, bravoBug, closedAlphaBug, mine, nobody]
        func matching(_ chips: [SlotChip]) -> [Int] {
            all.filter { SlotChipSelection(chips).matches($0, team: team, me: "me1") }
                .compactMap { Int($0.reference.split(separator: "#").last!) }
        }
        #expect(matching([]) == [1, 2, 3, 4, 5, 6])
        // a team and Open Bugs: that team's open bugs
        #expect(matching([.team("Alpha"), .openBugs]) == [1])
        // the same field: either
        #expect(matching([.me, .team("Alpha")]) == [1, 2, 4, 5])
        #expect(matching([.team("Alpha"), .team("Bravo")]) == [1, 2, 3, 4])
        #expect(matching([.triage, .remainingWork]) == [1, 2, 5, 6])
        // status and members and type together
        #expect(matching([.triage, .remainingWork, .team("Alpha")]) == [1, 2])
        #expect(matching([.triage, .openBugs]).isEmpty)
        // Everyone is never a member of the set
        #expect(matching([.all, .openBugs]) == [1, 3])
        // a username matches without its case
        #expect(SlotChip.team("Bravo").matches(Self.item(7, labels: [], assignees: ["USER2"]), team: team, me: nil))
    }

    @Test("SLOT-07 a click turns a chip on or off, Everyone clears the others and shows as on while nothing else is")
    func toggledChips() {
        var chips = SlotChipSelection.everyone
        #expect(chips.isActive(.all) && !chips.isActive(.me))
        chips = chips.toggled(.team("Alpha")).toggled(.openBugs)
        #expect(chips.isActive(.team("Alpha")) && chips.isActive(.openBugs) && !chips.isActive(.all))
        chips = chips.toggled(.openBugs)
        #expect(!chips.isActive(.openBugs) && chips.isActive(.team("Alpha")))
        chips = chips.toggled(.me).toggled(.all)
        #expect(chips == .everyone && chips.isActive(.all))
        // turning the last one off is Everyone again
        #expect(SlotChipSelection.everyone.toggled(.triage).toggled(.triage).isEveryone)
    }

    @Test("SLOT-07 the chips' ids round-trip, the old single id reads, unknown ids are dropped, empty is Everyone")
    func chipSelectionIDs() {
        // one chip's id reads back to the chip; an unknown id reads to nothing
        let single: [SlotChip] = [.me, .all, .triage, .remainingWork, .openBugs, .team("Alpha"), .squad("Bravo"), .squad("A: b")]
        for chip in single {
            #expect(SlotChip(id: chip.id) == chip, "\(chip.id)")
        }
        #expect(single.map(\.id) == ["me", "all", "triage", "remaining", "bugs", "team:Alpha", "squad:Bravo", "squad:A: b"])
        for id in ["", "nobody", "team:", "squad:", "Me"] {
            #expect(SlotChip(id: id) == nil, "\(id)")
        }
        let selection = SlotChipSelection([.team("Alpha"), .openBugs, .me, .squad("A, b%")])
        #expect(SlotChipSelection(id: selection.id) == selection)
        #expect(selection.id == "bugs,me,squad:A%2C b%25,team:Alpha")
        #expect(SlotChipSelection.everyone.id == "all")
        #expect(SlotChipSelection(id: "all") == .everyone && SlotChipSelection(id: "") == .everyone)
        // the id of the old single chip
        #expect(SlotChipSelection(id: "team:Alpha") == SlotChipSelection([.team("Alpha")]))
        #expect(SlotChipSelection(id: "me") == SlotChipSelection([.me]))
        #expect(SlotChipSelection(id: "triage,bogus,bugs") == SlotChipSelection([.triage, .openBugs]))
        // nothing of what was remembered is left: Me, as the single chip fell back
        #expect(SlotChipSelection(id: "bogus") == SlotChipSelection([.me]))

        let chips = SlotChip.chips(squads: [], teams: ["Alpha", "Delta"])
        // a gone team is dropped from the others; a squad of a team's name is that team; all gone is Me
        #expect(SlotChipSelection.restored(id: "team:Gone,bugs", among: chips) == SlotChipSelection([.openBugs]))
        #expect(SlotChipSelection.restored(id: "squad:alpha,triage", among: chips) == SlotChipSelection([.team("Alpha"), .triage]))
        #expect(SlotChipSelection.restored(id: "team:Gone", among: chips) == SlotChipSelection([.me]))
        #expect(SlotChipSelection.restored(id: "all", among: chips) == .everyone)
    }

    @Test("SLOT-13 the load of a combination is over the union of the members' person-days; status and type chips don't change it")
    func combinedCapacity() throws {
        var team = Self.team
        team.slotTeams = "Alpha: user1, user2; Bravo: user2, user3; Charlie: user4"
        team.slotMemberWorkDays = "user3: 4"
        func people(_ chips: [SlotChip], me: String? = "user3") -> [String]? {
            if case .people(let names, let days)? = SlotChipSelection(chips).capacity(team: team, squads: [], me: me) {
                #expect(days.days(of: "user3") == 4)
                return names.sorted()
            }
            return nil
        }
        // each person once, though user2 is in two teams
        #expect(people([.team("Alpha"), .team("Bravo")]) == ["user1", "user2", "user3"])
        // Me joins the union, already in it or not
        #expect(people([.team("Alpha"), .me]) == ["user1", "user2", "user3"])
        #expect(people([.team("Alpha"), .me], me: "user2") == ["user1", "user2"])
        // status and type chips filter the items, not the capacity
        #expect(people([.team("Charlie"), .openBugs, .triage]) == ["user4"])
        #expect(people([.openBugs]) == people([]))
        #expect(people([]) == ["user1", "user2", "user3", "user4"])
        // Me alone, and not a member: none
        #expect(people([.me], me: "stranger") == nil)

        // without teams: the points of the squads selected, summed; Me has none
        var squads = Self.team
        squads.squadCapacity = "Alpha: 20, Bravo: 10, Delta: 5"
        func points(_ chips: [SlotChip]) -> SlotCapacity? {
            SlotChipSelection(chips).capacity(team: squads, squads: ["Alpha", "Bravo", "Delta"], me: "user1")
        }
        #expect(points([.squad("Alpha"), .squad("Bravo")]) == .points(30))
        #expect(points([.squad("Alpha"), .me, .openBugs]) == .points(20))
        #expect(points([.openBugs]) == .points(35))
        #expect(points([.me]) == nil)
    }

    @Test("SLOT-13 a team has its chip only while one of its members is an assignee, sorted by name; teams named never fall back to squads")
    func teamsWithWork() throws {
        let teams = try #require(SlotTeams("Delta: user4; Alpha: user1, user2; Charlie: user3; Bravo: user9"))
        let items = [
            Self.item(1, labels: [], assignees: ["USER3"]), Self.item(2, labels: []),
            Self.item(3, labels: [], assignees: ["user2", "user4"]),
        ]
        #expect(SlotChip.teamsWithWork(teams, items: items) == ["Alpha", "Charlie", "Delta"])
        #expect(SlotChip.teamsWithWork(teams, items: [Self.item(4, labels: [])]).isEmpty)
        // teams named but none with work: no chips for them, and no squads either
        #expect(SlotChip.chips(squads: ["Old"], teams: []).map(\.id) == ["all", "triage", "remaining", "bugs", "me"])
        #expect(SlotChip.chips(squads: ["Old"], teams: nil).map(\.id) == ["all", "triage", "remaining", "bugs", "me", "squad:Old"])
        // teams with work replace the squads
        #expect(
            SlotChip.chips(squads: ["Old"], teams: ["Alpha", "Bravo"]).map(\.id)
                == ["all", "triage", "remaining", "bugs", "me", "team:Alpha", "team:Bravo"])
    }

    @Test("SLOT-07 Suggest Members lists the assignees of each squad's items in the team value's format, a person in one squad")
    func suggestedMembers() throws {
        let items = [
            Self.item(1, labels: ["squad::Bravo"], assignees: ["user2", "user1"]),
            Self.item(2, labels: ["squad::Alpha"], assignees: ["user1"]),
            Self.item(3, labels: ["squad::Alpha"], assignees: ["user1", "user3"]),
            Self.item(4, labels: ["squad::Charlie"]),
            Self.item(5, labels: ["status::Todo"], assignees: ["user9"]),
        ]
        // user1 has 2 items under Alpha and 1 under Bravo; Charlie has no assignee; user9 carries no squad
        let text = SlotChip.suggestedTeams(of: items, prefix: "squad::")
        #expect(text == "Alpha: user1, user3; Bravo: user2")
        // what it suggests is a team value Team accepts
        #expect(SlotTeams(text)?.names == ["Alpha", "Bravo"])
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

    @Test("SLOT-08 without teams the load is every item's weight over the squad capacity: a squad's, the sum for Everyone, none for the rest")
    func load() {
        let team = Self.team
        #expect(SlotChip.squad("Alpha").capacity(team: team, squads: ["Alpha", "Bravo"], me: nil) == .points(20))
        #expect(SlotChip.all.capacity(team: TeamValues(), squads: ["Alpha"], me: nil) == nil)

        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45", "commitment::Committed"], closed: true, weight: 5, assignees: ["alex", "jane"]),
            Self.item(2, labels: ["slot-scheduled::2026.45", "commitment::Committed"], weight: 10, assignees: ["jane"]),
            Self.item(3, labels: ["slot-scheduled::2026.45"], weight: 13, assignees: ["sam"]),
            Self.item(4, labels: ["slot-scheduled::2026.45"], assignees: ["sam"]),
        ]
        let slot = Self.slot(Self.plan(items, capacity: .points(20)))
        // done and planned items count; an item without a weight counts 0
        #expect(slot?.committedPoints == 15 && slot?.points == 28)
        #expect(slot?.load == 1.4 && slot?.loadLevel == .over)
        #expect(slot?.members.map(\.username) == ["jane", "sam", "alex"])
        #expect(Self.slot(Self.plan(items))?.load == nil)
    }

    @Test("SLOT-08 the items group by epic: epics with open items first, no epic last")
    func epics() {
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45", "commitment::Committed"], weight: 3, epic: 9),
            Self.item(2, labels: ["slot-scheduled::2026.45", "commitment::Committed"], closed: true, weight: 1, epic: 9),
            Self.item(3, labels: ["slot-scheduled::2026.45", "commitment::Committed"], closed: true, epic: 2),
            Self.item(4, labels: ["slot-scheduled::2026.45", "commitment::Committed"]),
            Self.item(5, labels: ["slot-scheduled::2026.45"], epic: 9),
        ]
        let groups = Self.slot(Self.plan(items))?.epicGroups ?? []
        #expect(groups.map { $0.epic?.title } == ["Epic 9", "Epic 2", nil])
        // planned items join their epic
        #expect(groups[0].items.map(\.workItem.reference) == ["acme/shop#1", "acme/shop#2", "acme/shop#5"])
    }

    // MARK: - SLOT-10

    @Test("SLOT-10 progress is the tool's: Verified 100 %, in verification 75 %, else 0, by weight; 0 without weight; an epic shows this slot's share")
    func progress() throws {
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45", "status::Verified"], closed: true, weight: 4, epic: 9),
            Self.item(2, labels: ["slot-scheduled::2026.45", "status::InVerification"], weight: 4, epic: 9),
            Self.item(3, labels: ["slot-scheduled::2026.45", "status::InProgress"], weight: 2, epic: 9),
            // without a weight it adds nothing, even when verified
            Self.item(4, labels: ["slot-scheduled::2026.45", "status::Verified"], epic: 9),
            Self.item(5, labels: ["slot-scheduled::2026.45", "status::Todo"], epic: 3),
        ]
        let slot = try #require(Self.slot(Self.plan(items)))
        #expect(Self.numbers(slot.allItems, \.progress) == [1: 1, 2: 0.75, 3: 0, 4: 1, 5: 0])
        // (4 + 3) of 10
        #expect(slot.progress == 0.7)
        let epic = try #require(slot.epicGroups.first { $0.epic?.title == "Epic 9" })
        #expect(epic.progress == 0.7)
        #expect(slot.epicGroups.first { $0.epic?.title == "Epic 3" }?.progress == 0)
        // without a status prefix, closed is done
        var plain = Self.team
        plain.statusLabelPrefix = ""
        #expect(SlotStatusRules.progress(of: items[0], statusPrefix: "") == 1)
        #expect(Self.slot(Self.plan(items, team: plain))?.progress == 0.4)
    }

    @Test("SLOT-10 blocked: never an epic or a finished item; an issue by the blocked label, else GitLab's flag")
    func blocked() {
        let team = Self.team
        var blockedIssue = Self.item(1, labels: ["prerequisite::Blocked", "status::Todo"])
        #expect(SlotStatusRules.isBlocked(blockedIssue, team: team))
        // GitLab's flag alone doesn't count when Team has a blocked label: a blocker in verification is done
        blockedIssue.labels = [Label(title: "status::Todo")]
        blockedIssue.isBlocked = true
        #expect(!SlotStatusRules.isBlocked(blockedIssue, team: team))
        var noLabel = team
        noLabel.blockedLabel = ""
        #expect(SlotStatusRules.isBlocked(blockedIssue, team: noLabel))
        let epic = WorkItem(
            reference: "acme&4", title: "Epic", webURL: Self.gitLab, type: .epic, labels: [Label(title: "prerequisite::Blocked")],
            updatedAt: Self.start)
        #expect(!SlotStatusRules.isBlocked(epic, team: team))
        let verified = Self.item(2, labels: ["prerequisite::Blocked", "status::Verified"])
        #expect(!SlotStatusRules.isBlocked(verified, team: team))
    }

    // MARK: - SLOT-11

    @Test("SLOT-11 an open issue of a slot without a weight or an assignee is a problem; the weight only from the slot group's query")
    func problems() throws {
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45"], weight: 3, assignees: ["alex"]),
            Self.item(2, labels: ["slot-scheduled::2026.45"], weight: 0, assignees: ["alex"]),
            Self.item(3, labels: ["slot-scheduled::2026.45"], weight: 2),
            Self.item(4, labels: ["slot-scheduled::2026.45"], closed: true),
            // my own work item: its query has no weight
            Self.item(5, labels: ["slot-scheduled::2026.45"], assignees: ["alex"], fromGroup: false),
        ]
        let slot = try #require(Self.slot(Self.plan(items)))
        #expect(
            Self.numbers(slot.allItems) { $0.problems.map(\.kind) }
                == [1: [], 2: [.weightMissing], 3: [.assigneeMissing], 4: [], 5: []])
        #expect(slot.problemCount == 2 && slot.weightMissingCount == 1)
    }

    @Test(
        "SLOT-11 an epic's size must fit the weight under it: S 1–5, M 6–15, L 16–30, XL 31 and more",
        arguments: [(0, nil), (1, "S"), (5, "S"), (6, "M"), (15, "M"), (16, "L"), (30, "L"), (31, "XL"), (200, "XL")] as [(Int, String?)])
    func sizes(weight: Int, size: String?) {
        #expect(SlotStatusRules.size(ofWeight: weight) == size)
    }

    @Test("SLOT-11 an epic whose size label doesn't fit its weight in all slots is a problem of its group")
    func sizeMismatch() throws {
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45"], weight: 3, epic: 9, assignees: ["alex"]),
            Self.item(2, labels: ["slot-scheduled::2026.45"], weight: 3, epic: 8, assignees: ["alex"]),
            Self.item(3, labels: ["slot-scheduled::2026.45"], weight: 3, epic: 7, assignees: ["alex"]),
        ]
        // the epics are size M: 40 is XL, 12 fits, and without GitLab's weight nothing is said
        let slot = try #require(Self.slot(Self.plan(items, epicWeights: ["acme&9": 40, "acme&8": 12])))
        #expect(slot.epicProblems.keys.sorted() == ["acme&9"])
        #expect(slot.epicGroups.first { $0.epic?.reference == "acme&9" }?.problem?.kind == .sizeMismatch)
        #expect(slot.problemCount == 1)
        var noSize = Self.team
        noSize.sizeLabelPrefix = ""
        #expect(Self.slot(Self.plan(items, team: noSize, epicWeights: ["acme&9": 40]))?.epicProblems.isEmpty == true)
    }

    // MARK: - SLOT-12

    @Test("SLOT-12 the items sort by status, then priority high to low, then reference; Verified and closed items are done")
    func order() throws {
        let items = [
            Self.item(10, labels: ["slot-scheduled::2026.45", "status::Verified"]),
            Self.item(11, labels: ["slot-scheduled::2026.45", "status::Todo"]),
            Self.item(12, labels: ["slot-scheduled::2026.45", "status::Todo", "priority::Critical"]),
            Self.item(9, labels: ["slot-scheduled::2026.45", "status::Todo"]),
            Self.item(13, labels: ["slot-scheduled::2026.45", "status::Triage", "priority::Minor"]),
            Self.item(14, labels: ["slot-scheduled::2026.45"]),
            Self.item(15, labels: ["slot-scheduled::2026.45", "status::InProgress", "priority::Blocker"]),
        ]
        let slot = try #require(Self.slot(Self.plan(items)))
        #expect(slot.planned.map { Int($0.workItem.reference.split(separator: "#").last!)! } == [13, 12, 9, 11, 15, 10, 14])
        #expect(Self.numbers(slot.planned, \.isDone) == [9: false, 10: true, 11: false, 12: false, 13: false, 14: false, 15: false])
        #expect(SlotStatusRules.isDone(Self.item(1, labels: ["status::Todo"], closed: true), statusPrefix: "status::"))
        #expect(SlotStatusRules.isDone(Self.item(1, labels: ["status::Rejected"]), statusPrefix: "status::"))
    }

    // MARK: - SLOT-13

    @Test("SLOT-13 the teams and the work days read from their team values, and other text is refused")
    func teamValues() throws {
        let teams = try #require(SlotTeams("Alpha: jdoe, @akim; Bravo: slee cnovak\nCharlie:x"))
        #expect(teams.names == ["Alpha", "Bravo", "Charlie"])
        #expect(teams.members(of: "alpha") == ["jdoe", "akim"])
        #expect(teams.members(of: "Bravo") == ["slee", "cnovak"])
        #expect(teams.everyone.count == 5)
        for bad in ["", "Alpha", "Alpha:", ": jdoe", "Alpha: jdoe; Bravo"] {
            #expect(SlotTeams(bad) == nil, "\(bad)")
        }
        let days = try #require(SlotWorkDays("akim: 4, @slee=3"))
        #expect(days.days(of: "AKIM") == 4 && days.days(of: "slee") == 3 && days.days(of: "jdoe") == 5)
        #expect(SlotWorkDays("")?.byMember.isEmpty == true)
        for bad in ["akim", "akim: 0", "akim: 8", "akim: x"] {
            #expect(SlotWorkDays(bad) == nil, "\(bad)")
            #expect(SettingsStore.issue(of: bad, for: .slotMemberWorkDays) != nil)
        }
        #expect(SettingsStore.issue(of: "Alpha", for: .slotTeams) != nil)
        #expect(SettingsStore.issue(of: "Alpha: jdoe", for: .slotTeams) == nil)
    }

    @Test("SLOT-13 the load is every item's weight over the person-days of the members with items, code freeze to release, weekdays only")
    func personDays() throws {
        var team = Self.team
        team.slotTeams = "Alpha: jdoe, akim, idle; Bravo: slee"
        team.slotMemberWorkDays = "akim: 4"
        // 2026.51: code freeze Fri 20 Nov, release Mon 14 Dec: 16 weekdays
        let dates = try #require(SlotRules().dates(of: SlotName("2026.51")!, calendar: Self.calendar))
        #expect(SlotCapacity.weekdays(from: dates.codeFreeze, to: dates.release, calendar: Self.calendar) == 16)
        let capacity = try #require(SlotChip.team("Alpha").capacity(team: team, squads: [], me: nil))
        #expect(abs((capacity.value(dates: dates, calendar: Self.calendar) ?? 0) - 44.8) < 0.0001)
        #expect(capacity.value(dates: nil, calendar: Self.calendar) == nil)

        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.51"], closed: true, weight: 8, assignees: ["jdoe"]),
            Self.item(2, labels: ["slot-scheduled::2026.51"], weight: 13, assignees: ["akim"]),
            Self.item(3, labels: ["slot-scheduled::2026.51"], assignees: ["akim"]),
        ]
        let slot = try #require(Self.slot(Self.plan(items, capacity: capacity, team: team), "2026.51"))
        // idle has no item here and adds no days: 16 + 12.8
        #expect(abs((slot.capacity ?? 0) - 28.8) < 0.0001 && slot.capacityPeople == 2)
        #expect(slot.points == 21)
        #expect(abs((slot.load ?? 0) - 21 / 28.8) < 0.0001)
        #expect(slot.loadLevel == .fine)
        #expect([0.79, 0.8, 1.0, 1.01].map(SlotLoadLevel.init) == [.fine, .tight, .tight, .over])
    }

    // MARK: - SLOT-14

    private static let commitmentsPage = #"""
        {"data": {"group": {"workItems": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
          {"reference": "acme/commitments&5", "title": "Dark mode", "webUrl": "https://gitlab.example.com/groups/acme/commitments/-/epics/5",
           "state": "OPEN", "widgets": [
             {"labels": {"nodes": [{"title": "slot-scheduled::2026.45"}, {"title": "commitment::Committed"}]}},
             {"dueDate": "2026-11-30"},
             {"assignees": {"nodes": [{"username": "jane", "name": "Jane"}]}},
             {"linkedItems": {"nodes": [
               {"linkType": "is_blocked_by", "workItem": {"reference": "acme&9", "webUrl": "https://gitlab.example.com/groups/acme/-/epics/9"}},
               {"linkType": "is_blocked_by", "workItem": {"reference": "acme/shop#4", "webUrl": "https://gitlab.example.com/acme/shop/-/work_items/4"}},
               {"linkType": "relates_to", "workItem": {"reference": "acme/shop#1", "webUrl": "https://gitlab.example.com/acme/shop/-/issues/1"}},
               {"linkType": "is_blocked_by", "workItem": {"reference": "acme/shop#77", "webUrl": "https://gitlab.example.com/acme/shop/-/issues/77"}}]}},
             {}]}]}}}}
        """#

    @Test("SLOT-14 commitments load from the commitment group by the slot label, with their due date and the items they are blocked by; a failure is a quiet note")
    func loadsCommitments() async throws {
        let world = try World()
        var team = Self.team
        team.slotCommitmentGroup = "acme/commitments"
        let store = TeamStore(folder: world.folder.file("support"), report: { _ in })
        try store.save(Project(id: .main, team: team))
        world.stub.answer(operation: "SlotItems", body: World.page([Self.firstNode], next: nil))
        world.stub.answer(operation: "SlotCommitments", body: Self.commitmentsPage)
        let items = SlotItemsStore(services: world.services)
        await items.load(slots: [SlotName("2026.45")!])
        let commitment = try #require(items.commitments.first)
        #expect(commitment.reference == "acme/commitments&5" && commitment.state == .opened && commitment.dueDate == "2026-11-30")
        #expect(commitment.assignees.map(\.username) == ["jane"])
        // only what it is blocked by: not a related item
        #expect(commitment.committed.map(\.reference) == ["acme&9", "acme/shop#4", "acme/shop#77"])
        let variables = try #require(world.stub.requests(operation: "SlotCommitments").first?.graphQL?.variables)
        #expect(variables.contains(#""group":"acme/commitments""#) && variables.contains(#"["slot-scheduled::2026.45"]"#))
        #expect(items.commitmentsProblem == nil)

        // a GitLab that refuses the query keeps the slots, and says so quietly
        world.stub.answer(operation: "SlotCommitments", body: #"{"errors": [{"message": "Field 'workItems' doesn't exist"}]}"#)
        await items.load(slots: [SlotName("2026.45")!], force: true)
        #expect(items.problem == nil && items.items.count == 1)
        #expect(items.commitments.count == 1)
        #expect(items.commitmentsProblem?.contains("workItems") == true)
    }

    @Test("SLOT-14 a commitment heads the slot's items it is blocked by, itself or through their epic, and counts the ones elsewhere")
    func commitmentTree() throws {
        let commitment = SlotCommitment(
            reference: "acme/commitments&5", title: "Dark mode", webURL: Self.gitLab.appending(path: "groups/acme/commitments/-/epics/5"),
            labels: [Label(title: "slot-scheduled::2026.45")],
            committed: [
                .init(reference: "acme&9"),
                // GitLab may name an issue's page /-/work_items/ where the item says /-/issues/
                .init(reference: "other#4", webURL: Self.gitLab.appending(path: "acme/shop/-/work_items/4")),
                .init(reference: "acme/shop#77"),
            ])
        let idle = SlotCommitment(
            reference: "acme/commitments&6", title: "Nothing here", webURL: Self.gitLab,
            labels: [Label(title: "slot-scheduled::2026.45")], committed: [.init(reference: "acme/shop#99")])
        let items = [
            Self.item(1, labels: ["slot-scheduled::2026.45"], weight: 2, epic: 9),
            Self.item(2, labels: ["slot-scheduled::2026.45"], weight: 2, epic: 9),
            Self.item(3, labels: ["slot-scheduled::2026.45"], weight: 1, epic: 8),
            Self.item(4, labels: ["slot-scheduled::2026.45"], weight: 1, epic: 8),
            Self.item(5, labels: ["slot-scheduled::2026.45"], weight: 1),
        ]
        let plan = SlotPlan.make(
            workItems: items, mergeRequests: { _ in nil }, build: { _ in nil }, team: Self.team, commitments: [commitment, idle],
            today: Self.start, calendar: Self.calendar)
        let slot = try #require(Self.slot(plan))
        #expect(slot.commitments.map(\.commitment.title) == ["Dark mode"])
        let group = try #require(slot.commitments.first)
        #expect(group.items.map(\.workItem.reference) == ["acme/shop#4", "acme/shop#1", "acme/shop#2"])
        #expect(group.elsewhere == 1)
        // the rest of the tree: what no commitment has
        #expect(slot.otherGroups.flatMap(\.items).map(\.workItem.reference) == ["acme/shop#3", "acme/shop#5"])
        #expect(slot.allItems.count == 5)
    }
}

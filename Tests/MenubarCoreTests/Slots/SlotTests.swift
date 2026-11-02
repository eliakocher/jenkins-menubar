import Foundation
import Testing

@testable import MenubarCore

/// The slot dates from the names, the states, the joins with merge requests and builds, the flags and the alert
/// (SLOT-01 to SLOT-05), with made-up teams and slots.
@Suite("Slots")
struct SlotTests {
    private static let gitLab = URL(string: "https://gitlab.example.com")!
    private static let project = "acme/shop"
    private static let committed = "plan::committed"

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func team(prefix: String = "slot::", committed: String = committed, _ values: TeamValues = TeamValues()) -> TeamValues {
        var team = values
        team.gitLabURL = gitLab.absoluteString
        team.gitLabProject = project
        team.slotLabelPrefix = prefix
        team.committedLabel = committed
        return team
    }

    private static func name(_ value: String) -> SlotName {
        SlotName(value)!
    }

    private static func dates(_ value: String, _ team: TeamValues = team()) -> SlotDates? {
        SlotRules(team: team).dates(of: name(value), calendar: calendar)
    }

    private static func item(
        _ number: Int, slot: String? = "2026.51", committed: Bool = true, labels: [String] = [], closed: Bool = false
    ) -> WorkItem {
        var titles = labels
        if let slot { titles.append("slot::\(slot)") }
        if committed { titles.append(Self.committed) }
        return WorkItem(
            reference: "\(project)#\(number)", title: "Item \(number)",
            webURL: gitLab.appending(path: "\(project)/-/work_items/\(number)"), state: closed ? .closed : .opened,
            labels: titles.map { Label(title: $0) }, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func mergeRequest(_ iid: Int, _ state: RelatedMergeRequest.State) -> RelatedMergeRequest {
        RelatedMergeRequest(
            iid: iid, state: state, title: "Change \(iid)",
            webURL: gitLab.appending(path: "\(project)/-/merge_requests/\(iid)"), reference: "\(project)!\(iid)")
    }

    private static func buildURL(_ iid: Int) -> URL {
        URL(string: "https://jenkins.example.com/job/shop/job/MR-\(iid)/1/")!
    }

    /// the plan of work items, each with its merge requests, and builds by the MR's iid
    private static func plan(
        _ items: [WorkItem], mergeRequests: [Int: [RelatedMergeRequest]] = [:], builds: [Int: BuildSignal] = [:],
        today: Date, team: TeamValues = team(), known: [Label] = []
    ) -> SlotPlan {
        SlotPlan.make(
            workItems: items,
            mergeRequests: { item in
                let number = Int(item.reference.split(separator: "#").last!)!
                return mergeRequests[number] ?? []
            },
            build: { mergeRequest in
                builds[mergeRequest.iid].map { BuildReality(signal: $0, url: buildURL(mergeRequest.iid)) }
            },
            knownLabels: known, team: team, today: today, calendar: calendar)
    }

    // MARK: - SLOT-01

    struct DatesCase: CustomTestStringConvertible, Sendable {
        var label: String
        var team: TeamValues = TeamValues()
        /// year, month and day of the release; empty when the week doesn't exist
        var release: [Int]
        /// year, month and day of the code freeze; empty when the case says nothing of it
        var codeFreeze: [Int] = []
        var earlyAccess: [Int] = []
        var note: String
        var testDescription: String { "\(label): \(note)" }
    }

    static let dateCases = [
        // the release is a Monday, the code freeze the 4th Friday before, early access the 2nd Monday before
        DatesCase(label: "2026.51", release: [2026, 12, 14], codeFreeze: [2026, 11, 20], earlyAccess: [2026, 11, 30], note: "defaults"),
        DatesCase(
            label: "2026.51", team: TeamValues(slotReleaseWeekday: "Thursday"), release: [2026, 12, 17], codeFreeze: [2026, 11, 20],
            earlyAccess: [2026, 12, 7], note: "the release weekday is the team's"),
        // the release is a Monday, so the 1st Monday before is a week back; Wednesdays before Dec 14: Dec 9, Dec 2, Nov 25
        DatesCase(
            label: "2026.51",
            team: TeamValues(
                slotCodeFreezeNth: "1", slotCodeFreezeWeekday: "Monday", slotEarlyAccessNth: "3", slotEarlyAccessWeekday: "Wed"),
            release: [2026, 12, 14], codeFreeze: [2026, 12, 7], earlyAccess: [2026, 11, 25], note: "the Nth weekday is the team's"),
        // week 1 can start in the year before
        DatesCase(
            label: "2026.01", release: [2025, 12, 29], codeFreeze: [2025, 12, 5], earlyAccess: [2025, 12, 15], note: "week 1 of 2026"),
        DatesCase(
            label: "2027.03", release: [2027, 1, 18], codeFreeze: [2026, 12, 25], earlyAccess: [2027, 1, 4], note: "across the year end"),
        DatesCase(label: "2027.01", release: [2027, 1, 4], note: "week 1 of 2027"),
        // 2026 and 2020 have 53 ISO weeks; 2027 and 2025 have 52
        DatesCase(label: "2026.53", release: [2026, 12, 28], note: "a long year's week 53"),
        DatesCase(label: "2020.53", release: [2020, 12, 28], note: "a long year's week 53"),
        DatesCase(label: "2027.53", release: [], note: "no week 53 in a short year"),
        DatesCase(label: "2025.53", release: [], note: "no week 53 in a short year"),
        DatesCase(
            label: "2025.52", team: TeamValues(slotReleaseWeekday: "7"), release: [2025, 12, 28], note: "a Sunday release of week 52"),
    ]

    @Test("SLOT-01 a slot name is the ISO week of its release; the freeze and early access are the team's Nth weekday before it", arguments: dateCases)
    func releaseDates(_ item: DatesCase) throws {
        let team = Self.team(item.team)
        guard !item.release.isEmpty else {
            #expect(Self.dates(item.label, team) == nil)
            return
        }
        let dates = try #require(Self.dates(item.label, team))
        func date(_ ymd: [Int]) -> Date { Self.day(ymd[0], ymd[1], ymd[2], hour: 0) }
        #expect(dates.release == date(item.release))
        if !item.codeFreeze.isEmpty { #expect(dates.codeFreeze == date(item.codeFreeze)) }
        if !item.earlyAccess.isEmpty { #expect(dates.earlyAccess == date(item.earlyAccess)) }
    }

    @Test("SLOT-01 an empty or invalid rule value reads as its default")
    @MainActor
    func defaults() {
        let rules = SlotRules(team: TeamValues(
            slotReleaseWeekday: "someday", slotCodeFreezeNth: "0", slotCodeFreezeWeekday: "x", slotEarlyAccessNth: "13",
            slotEarlyAccessWeekday: "9", slotWarnDays: "999"))
        #expect(rules == SlotRules())
        #expect(rules == SlotRules(team: TeamValues()))
        #expect(SlotRules.weekday(of: "wed") == 3)
        #expect(SlotRules.weekday(of: " Sunday ") == 7)
        #expect(SlotRules.weekday(of: "0") == nil)
        #expect(SlotRules.weekday(of: "8") == nil)
        #expect(SlotRules.nth(of: "12") == 12)
        #expect(SlotRules.nth(of: "13") == nil)
        #expect(SlotRules.days(of: "365") == 365)
        #expect(SlotRules.days(of: "366") == nil)
        // Settings flags a typed value that reads as its default, and says nothing for an empty one
        #expect(SettingsStore.issue(of: "someday", for: .slotReleaseWeekday) != nil)
        #expect(SettingsStore.issue(of: "ftp://planning", for: .slotPlanningURL) != nil)
        #expect(SettingsStore.issue(of: "", for: .slotCodeFreezeNth) == nil)
    }

    @Test("SLOT-01 parses slot labels: a week strictly, any other value as a slot without dates")
    func parsing() {
        #expect(SlotName(label: "slot::2026.51", prefix: "slot::")?.description == "2026.51")
        #expect(SlotName(label: "slot::2026.5", prefix: "slot::")?.description == "2026.05")
        #expect(SlotName(label: "slot::2026.51", prefix: "") == nil)
        #expect(SlotName(label: "other::2026.51", prefix: "slot::") == nil)
        #expect(SlotName(label: "slot::", prefix: "slot::") == nil)
        for other in ["26.51", "2026.54", "2026.0", "2026-51", "2026.51.1", "2026.5x", "hotfix_2026-10-20", "beta"] {
            let name = SlotName(other)
            #expect(name?.isoWeek == nil && name?.description == other, "\(other)")
            #expect(name.flatMap { SlotRules().dates(of: $0, calendar: Self.calendar) } == nil, "\(other)")
        }
        #expect(SlotName("2026.51")! < SlotName("2027.01")!)
        #expect(SlotName("2026.09")! < SlotName("2026.10")!)
        // weeks first, then the other names
        #expect(SlotName("2099.01")! < SlotName("beta")!)
        // a slot without dates shows last while it has open items, never as the current one
        let plan = Self.plan(
            [Self.item(1, slot: "beta"), Self.item(2), Self.item(3, slot: "old", closed: true)], today: Self.day(2026, 10, 29))
        #expect(plan.slots.map(\.name.description) == ["2026.51", "beta"])
        #expect(plan.slots[1].dates == nil && plan.slots[1].state == .upcoming)
        #expect(plan.current?.name.description == "2026.51")
    }

    // MARK: - SLOT-02

    @Test("SLOT-02 the current slot is the next release not yet passed; the release day still counts")
    func states() throws {
        let items = ["2026.45", "2026.48", "2026.51"].enumerated().map { Self.item($0.offset + 1, slot: $0.element) }
        // 2026.45 releases on Mon Nov 2, 2026.48 on Nov 23, 2026.51 on Dec 14
        func states(on today: Date) -> [String: SlotState] {
            Dictionary(uniqueKeysWithValues: Self.plan(items, today: today).slots.map { ($0.name.description, $0.state) })
        }
        #expect(states(on: Self.day(2026, 10, 29)) == ["2026.45": .current, "2026.48": .upcoming, "2026.51": .upcoming])
        #expect(states(on: Self.day(2026, 11, 2)) == ["2026.45": .current, "2026.48": .upcoming, "2026.51": .upcoming])
        // after the release, the slot is overdue, and still shown while it has open items
        #expect(states(on: Self.day(2026, 11, 3)) == ["2026.45": .overdue, "2026.48": .current, "2026.51": .upcoming])
    }

    @Test("SLOT-02 the current slot is the earliest of all slot labels not yet released, not only the user's")
    @MainActor
    func currentOfAllSlots() {
        // my only item is in 2026.51, but GitLab has the slots before it: 2026.45 releases on Monday 2 November
        let labels = ["2026.42", "2026.45", "2026.48", "2026.51"].map { Label(title: "slot::\($0)") }
        let plan = Self.plan(
            [Self.item(1)], today: Self.day(2026, 10, 30), team: Self.team(TeamValues(slotPastShown: "0")), known: labels)
        // 2026.42 released on 12 October with nothing open, so it doesn't show with no past slots shown
        #expect(plan.slots.map(\.name.description) == ["2026.45", "2026.48", "2026.51"])
        #expect(plan.current?.name.description == "2026.45")
        #expect(plan.slots.map(\.state) == [.current, .upcoming, .upcoming])
        #expect(plan.slots[0].items.isEmpty)
        // only the next few upcoming slots show, later ones when they have committed items
        let years = (3...30).filter { $0 % 3 == 0 }.map { Label(title: String(format: "slot::2027.%02d", $0)) }
        let far = Self.plan(
            [Self.item(1, slot: "2027.30")], today: Self.day(2026, 10, 30), team: Self.team(TeamValues(slotPastShown: "0")),
            known: labels + years)
        // the current one and the next 4 by default, the team's number otherwise
        #expect(far.slots.map(\.name.description) == ["2026.45", "2026.48", "2026.51", "2027.03", "2027.06", "2027.30"])
        let two = Self.plan(
            [Self.item(1, slot: "2027.30")], today: Self.day(2026, 10, 30), team: Self.team(TeamValues(slotUpcomingShown: "2", slotPastShown: "0")),
            known: labels + years)
        #expect(two.slots.map(\.name.description) == ["2026.45", "2026.48", "2026.51", "2027.30"])
    }

    @Test("SLOT-02 the latest released slots show as many as Team says, besides the overdue ones; the rest only while open")
    func pastSlotsShown() {
        // 2026.42 to 2026.45 released on 12, 19, 26 October and 2 November; today is 5 November, 2026.48 is current
        let labels = ["2026.41", "2026.42", "2026.43", "2026.44", "2026.45", "2026.48"].map { Label(title: "slot::\($0)") }
        let items = [Self.item(1, slot: "2026.48"), Self.item(2, slot: "2026.42")]  // 2026.42 is overdue
        func plan(_ pastShown: String) -> SlotPlan {
            Self.plan(items, today: Self.day(2026, 11, 5), team: Self.team(TeamValues(slotPastShown: pastShown)), known: labels)
        }
        func names(_ pastShown: String) -> [String] { plan(pastShown).slots.map(\.name.description) }
        // the default 2: the latest two released ones, and the overdue one on top of them
        #expect(names("") == ["2026.42", "2026.44", "2026.45", "2026.48"])
        #expect(plan("").slots.map(\.state) == [.overdue, .released, .released, .current])
        #expect(names("0") == ["2026.42", "2026.48"])
        // the overdue one is kept whatever the number; 3 adds 2026.43
        #expect(names("3") == ["2026.42", "2026.43", "2026.44", "2026.45", "2026.48"])
        #expect(names("12") == ["2026.41", "2026.42", "2026.43", "2026.44", "2026.45", "2026.48"])
        // an invalid number is the default
        #expect(names("13") == names(""))
        // an overdue slot shows only while it has open committed items
        let none = Self.team(TeamValues(slotPastShown: "0"))
        let done = Self.item(1, slot: "2026.45", closed: true)
        let closedOut = Self.plan([done, Self.item(2, slot: "2026.48")], today: Self.day(2026, 11, 30), team: none)
        #expect(closedOut.slots.map(\.name.description) == ["2026.48"])
        let overdue = Self.plan([done, Self.item(3, slot: "2026.45")], today: Self.day(2026, 11, 30), team: none)
        #expect(overdue.slots.map(\.name.description) == ["2026.45"])
        #expect(overdue.slots[0].state == .overdue)
    }

    @Test("SLOT-02 groups the committed items by slot and counts the rest")
    func grouping() {
        let items = [
            Self.item(1), Self.item(2), Self.item(3, committed: false), Self.item(4, slot: "2027.03"),
            Self.item(5, slot: nil), Self.item(6, slot: "2027.53"),
        ]
        let plan = Self.plan(items, today: Self.day(2026, 10, 29))
        #expect(plan.slots.map(\.name.description) == ["2026.51", "2027.03"])
        #expect(plan.slots[0].items.map(\.workItem.reference) == ["acme/shop#1", "acme/shop#2"])
        #expect(plan.slots[0].uncommittedCount == 1)
        // no slot label; a week the year doesn't have is a slot that doesn't show
        #expect(plan.withoutSlot == 1)
        #expect(plan.current?.name.description == "2026.51")
        // without a committed label, every item counts
        let all = Self.plan(items, today: Self.day(2026, 10, 29), team: Self.team(committed: ""))
        #expect(all.slots[0].items.count == 3)
    }

    @Test("SLOT-02 a slot from a remembered label shows without items; no prefix means no slots")
    func knownLabels() {
        let plan = Self.plan([], today: Self.day(2026, 10, 29), known: [Label(title: "slot::2026.48", color: "#9400d3"), Label(title: "other")])
        #expect(plan.slots.map(\.name.description) == ["2026.48"])
        #expect(plan.slots[0].label.color == "#9400d3")
        #expect(plan.slots[0].items.isEmpty)
        let none = Self.plan([Self.item(1)], today: Self.day(2026, 10, 29), team: Self.team(prefix: ""))
        #expect(none.slots.isEmpty)
    }

    // MARK: - SLOT-03

    private static func flags(
        _ items: [WorkItem], _ mergeRequests: [Int: [RelatedMergeRequest]] = [:], builds: [Int: BuildSignal] = [:],
        today: Date = day(2026, 11, 1), team: TeamValues = team()
    ) -> [String: [SlotFlag.Kind]] {
        Dictionary(
            uniqueKeysWithValues: plan(items, mergeRequests: mergeRequests, builds: builds, today: today, team: team).slots
                .flatMap(\.items).map { ($0.workItem.reference, $0.flags.map(\.kind)) })
    }

    @Test("SLOT-03 an item in progress (the team's label, else the status) whose merge request is merged and not red is ready to verify")
    func readyToVerify() {
        let inProgress = Self.item(1, labels: ["status::InProgress"])
        let flags = Self.flags(
            [inProgress, Self.item(2, labels: ["status::In Progress"]), Self.item(3, labels: ["status::InProgress"]),
             Self.item(4, labels: ["status::InProgress"]), Self.item(5)],
            [1: [Self.mergeRequest(11, .merged)], 2: [Self.mergeRequest(12, .merged)], 3: [Self.mergeRequest(13, .merged)],
             4: [Self.mergeRequest(14, .merged), Self.mergeRequest(15, .opened)], 5: [Self.mergeRequest(16, .merged)]],
            builds: [11: .green, 12: .green, 13: .red])
        #expect(flags["acme/shop#1"] == [.readyToVerify])
        // any spelling of in progress
        #expect(flags["acme/shop#2"] == [.readyToVerify])
        // a red build is no green, an open MR is not done, and an item not in progress isn't offered
        #expect(flags["acme/shop#3"] == [])
        #expect(flags["acme/shop#4"] == [])
        #expect(flags["acme/shop#5"] == [])
        // the fix opens the item
        let plan = Self.plan([inProgress], mergeRequests: [1: [Self.mergeRequest(11, .merged)]], today: Self.day(2026, 11, 1))
        #expect(plan.slots[0].items[0].flags[0].fixURL == inProgress.webURL)
        // the team's in-progress label replaces the guess
        let team = Self.team(TeamValues(inProgressLabel: "wip"))
        let labelled = Self.flags(
            [Self.item(1, labels: ["wip"]), Self.item(2, labels: ["status::InProgress"])],
            [1: [Self.mergeRequest(11, .merged)], 2: [Self.mergeRequest(12, .merged)]], team: team)
        #expect(labelled["acme/shop#1"] == [.readyToVerify])
        #expect(labelled["acme/shop#2"] == [])
    }

    @Test("SLOT-03 a committed item with an open merge request and a red build has a red pipeline, fixed at the build; a done item with a red build is flagged")
    func redPipeline() throws {
        let item = Self.item(1)
        let plan = Self.plan(
            [item, Self.item(2), Self.item(3)],
            mergeRequests: [1: [Self.mergeRequest(11, .opened)], 2: [Self.mergeRequest(12, .opened)], 3: [Self.mergeRequest(13, .opened)]],
            builds: [13: .red, 12: .green, 11: .running], today: Self.day(2026, 11, 1))
        let items = plan.slots[0].items
        #expect(items.map { $0.flags.map(\.kind) } == [[], [], [.redPipeline]])
        #expect(items[2].workItem.reference == "acme/shop#3")
        #expect(plan.slots[0].flagCount == 1)
        #expect(items[2].mergeRequests[0].build?.signal == .red)
        #expect(items[2].flags[0].fixURL == Self.buildURL(13))
        // without a known build, the fix is the merge request
        let noURL = SlotPlan.make(
            workItems: [item], mergeRequests: { _ in [Self.mergeRequest(11, .opened)] },
            build: { _ in BuildReality(signal: .red) }, team: Self.team(), today: Self.day(2026, 11, 1), calendar: Self.calendar)
        #expect(noURL.slots[0].items[0].flags[0].fixURL == Self.mergeRequest(11, .opened).webURL)
        // a done item with a red build is flagged too
        let done = Self.flags(
            [Self.item(1, closed: true), Self.item(2, closed: true)],
            [1: [Self.mergeRequest(11, .merged)], 2: [Self.mergeRequest(12, .merged)]], builds: [11: .red, 12: .green])
        #expect(done["acme/shop#1"] == [.doneWithRedBuild])
        #expect(done["acme/shop#2"] == [])
    }

    @Test("SLOT-03 no merge request is flagged only from the warning days before the code freeze")
    func noMergeRequest() {
        let items = [Self.item(1), Self.item(2), Self.item(3), Self.item(4, closed: true)]
        let mergeRequests = [2: [Self.mergeRequest(12, .opened)], 3: [Self.mergeRequest(13, .closed)]]
        // the code freeze of 2026.51 is Nov 20; warning days 3 means from Nov 17
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 11, 16))["acme/shop#1"] == [])
        let flags = Self.flags(items, mergeRequests, today: Self.day(2026, 11, 17))
        #expect(flags["acme/shop#1"] == [.noMergeRequest])
        #expect(flags["acme/shop#2"] == [])
        // a closed merge request is no work on it
        #expect(flags["acme/shop#3"] == [.noMergeRequest])
        // a done item needs none
        #expect(flags["acme/shop#4"] == [])
        // the team's warning days
        let wider = Self.team(TeamValues(slotWarnDays: "10"))
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 11, 10), team: wider)["acme/shop#1"] == [.noMergeRequest])
        // after the freeze it stays, while the slot isn't past
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 12, 10))["acme/shop#1"] == [.noMergeRequest])
        // an answer GitLab hasn't given yet says nothing
        let unanswered = SlotPlan.make(
            workItems: [Self.item(1)], mergeRequests: { _ in nil }, build: { _ in nil }, team: Self.team(),
            today: Self.day(2026, 11, 18), calendar: Self.calendar)
        #expect(unanswered.slots[0].items[0].flags.isEmpty)
        // the merge requests that only mention the item don't count
        let ignored = Self.team(TeamValues(ignoredMergeRequestPrefix: "Change"))
        #expect(Self.flags([Self.item(1)], [1: [Self.mergeRequest(11, .opened)]], today: Self.day(2026, 11, 18), team: ignored)["acme/shop#1"] == [.noMergeRequest])
    }

    @Test("SLOT-03 reads builds and pipelines as green, red or running")
    func buildSignals() {
        func build(_ phase: BuildPhase) -> Build {
            Build(job: "MR-1", number: 1, kind: .mine, phase: phase, startedAt: Date(timeIntervalSince1970: 0))
        }
        #expect(BuildSignal(build(.finished(result: .success, duration: 1))) == .green)
        #expect(BuildSignal(build(.finished(result: .failure, duration: 1))) == .red)
        #expect(BuildSignal(build(.finished(result: .unstable, duration: 1))) == .red)
        #expect(BuildSignal(build(.finished(result: .aborted, duration: 1))) == nil)
        #expect(BuildSignal(build(.running)) == .running)
        #expect(BuildSignal(MergeRequest.PipelineStatus.success) == .green)
        #expect(BuildSignal(MergeRequest.PipelineStatus.failed) == .red)
        #expect(BuildSignal(MergeRequest.PipelineStatus.canceled) == nil)
    }

    // MARK: - SLOT-04

    @Test("SLOT-04 the alert comes once per slot from the warning days before the code freeze, for items without a merged MR")
    func alertRule() {
        let items = [Self.item(1), Self.item(2), Self.item(3), Self.item(4, closed: true)]
        let mergeRequests = [2: [Self.mergeRequest(12, .opened)], 3: [Self.mergeRequest(13, .merged)]]
        func notices(on today: Date, announced: Set<String> = []) -> [SlotNotice] {
            SlotAlerts.notices(
                of: Self.plan(items, mergeRequests: mergeRequests, today: today), warnDays: 3, announced: announced)
        }
        #expect(notices(on: Self.day(2026, 11, 16)).isEmpty)
        // items 1 and 2 have no merged MR: the closed one and the merged one don't count
        let notice = notices(on: Self.day(2026, 11, 17)).first
        #expect(notice?.body.hasPrefix("2 ") == true)
        #expect(notice?.url == AppRoute.open(.slots).url)
        #expect(notices(on: Self.day(2026, 11, 19)).count == 1)
        #expect(notices(on: Self.day(2026, 11, 20)).count == 1)
        // after the freeze, and once announced, nothing more
        #expect(notices(on: Self.day(2026, 11, 21)).isEmpty)
        #expect(notices(on: Self.day(2026, 11, 18), announced: ["2026.51"]).isEmpty)
        // nothing to say when everything is merged
        let merged = Self.plan(
            [Self.item(1)], mergeRequests: [1: [Self.mergeRequest(11, .merged)]], today: Self.day(2026, 11, 18))
        #expect(SlotAlerts.notices(of: merged, warnDays: 3, announced: []).isEmpty)
        // and waits for GitLab's answers
        let unanswered = SlotPlan.make(
            workItems: [Self.item(1)], mergeRequests: { _ in nil }, build: { _ in nil }, team: Self.team(),
            today: Self.day(2026, 11, 18), calendar: Self.calendar)
        #expect(SlotAlerts.notices(of: unanswered, warnDays: 3, announced: []).isEmpty)
    }

    @Test("SLOT-04 the alert is off by default, posts a banner without a sound, and posts each slot once")
    @MainActor
    func alertAnnounce() async throws {
        let folder = try TemporaryFolder()
        let defaults = try #require(UserDefaults(suiteName: "SlotTests.\(UUID().uuidString)"))
        let effects = FakeEffects()
        let log = ActivityLog(folder: folder.url)
        let plan = Self.plan([Self.item(1)], today: Self.day(2026, 11, 18))
        #expect(Preferences().slotAlerts == false)
        await SlotAlerts.announce(
            plan, team: Self.team(), preferences: Preferences(), defaults: defaults, effects: effects, log: log)
        #expect(await effects.calls.isEmpty)
        let on = Preferences(slotAlerts: true)
        await SlotAlerts.announce(plan, team: Self.team(), preferences: on, defaults: defaults, effects: effects, log: log)
        await SlotAlerts.announce(plan, team: Self.team(), preferences: on, defaults: defaults, effects: effects, log: log)
        #expect(await effects.notices.count == 1)
        #expect(await effects.sounds.isEmpty)
        #expect(await effects.alertWindows.isEmpty)
        #expect(await log.entries().count == 1)
    }

    // MARK: - SLOT-05

    @Test("SLOT-05 a planning URL is for web pages only")
    func teamValues() {
        #expect(TeamValues(slotPlanningURL: "https://planning.example.com/slots").slotPlanning?.host == "planning.example.com")
        #expect(TeamValues().slotPlanning == nil)
        #expect(TeamValues(slotPlanningURL: "javascript:alert(1)").slotPlanning == nil)
        #expect(TeamValues(slotPlanningURL: "planning.example.com").slotPlanning == nil)
    }
}

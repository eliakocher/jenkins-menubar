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

    @Test("SLOT-01 a slot name is the ISO week of its year, on the team's weekday")
    func weekOfYear() throws {
        let dates = try #require(Self.dates("2026.51"))
        #expect(dates.release == Self.day(2026, 12, 14, hour: 0))
        #expect(dates.codeFreeze == Self.day(2026, 11, 30, hour: 0))
        #expect(dates.earlyAccess == Self.day(2026, 12, 7, hour: 0))
        let friday = try #require(Self.dates("2026.51", Self.team(TeamValues(slotReleaseWeekday: "Friday"))))
        #expect(friday.release == Self.day(2026, 12, 18, hour: 0))
    }

    @Test("SLOT-01 weeks across the year end: week 1 can start in the year before, week 53 only exists in long years")
    func yearEnds() throws {
        #expect(try #require(Self.dates("2026.01")).release == Self.day(2025, 12, 29, hour: 0))
        #expect(try #require(Self.dates("2027.01")).release == Self.day(2027, 1, 4, hour: 0))
        // the code freeze of week 1 lies in the year before
        #expect(try #require(Self.dates("2026.01")).codeFreeze == Self.day(2025, 12, 15, hour: 0))
        // 2026 and 2020 have 53 ISO weeks; 2027 and 2025 have 52
        #expect(try #require(Self.dates("2026.53")).release == Self.day(2026, 12, 28, hour: 0))
        #expect(try #require(Self.dates("2020.53")).release == Self.day(2020, 12, 28, hour: 0))
        #expect(Self.dates("2027.53") == nil)
        #expect(Self.dates("2025.53") == nil)
        // a Sunday release of week 52 in 2025 is December 28
        #expect(try #require(Self.dates("2025.52", Self.team(TeamValues(slotReleaseWeekday: "7")))).release == Self.day(2025, 12, 28, hour: 0))
    }

    @Test("SLOT-01 the offsets are the team's days before the release")
    func offsets() throws {
        let team = Self.team(TeamValues(slotCodeFreezeDays: "10", slotEarlyAccessDays: "3"))
        let dates = try #require(Self.dates("2026.51", team))
        #expect(dates.codeFreeze == Self.day(2026, 12, 4, hour: 0))
        #expect(dates.earlyAccess == Self.day(2026, 12, 11, hour: 0))
        let none = try #require(Self.dates("2026.51", Self.team(TeamValues(slotCodeFreezeDays: "0"))))
        #expect(none.codeFreeze == none.release)
    }

    @Test("SLOT-01 an empty or invalid rule value reads as its default")
    @MainActor
    func defaults() {
        let rules = SlotRules(team: TeamValues(slotReleaseWeekday: "someday", slotCodeFreezeDays: "-3", slotEarlyAccessDays: "x", slotWarnDays: "999"))
        #expect(rules == SlotRules())
        #expect(SlotRules(team: TeamValues()) == SlotRules(releaseWeekday: 1, codeFreezeDays: 14, earlyAccessDays: 7, warnDays: 3))
        #expect(SlotRules.weekday(of: "wed") == 3)
        #expect(SlotRules.weekday(of: " Sunday ") == 7)
        #expect(SlotRules.weekday(of: "0") == nil)
        #expect(SlotRules.weekday(of: "8") == nil)
        #expect(SlotRules.days(of: "365") == 365)
        #expect(SlotRules.days(of: "366") == nil)
        // Settings says what is wrong with a typed value, and nothing for an empty one
        #expect(SettingsStore.issue(of: "someday", for: .slotReleaseWeekday) != nil)
        #expect(SettingsStore.issue(of: "-1", for: .slotCodeFreezeDays) != nil)
        #expect(SettingsStore.issue(of: "ftp://planning", for: .slotPlanningURL) != nil)
        #expect(SettingsStore.issue(of: "", for: .slotCodeFreezeDays) == nil)
    }

    @Test("SLOT-01 parses slot labels strictly")
    func parsing() {
        #expect(SlotName(label: "slot::2026.51", prefix: "slot::")?.description == "2026.51")
        #expect(SlotName(label: "slot::2026.5", prefix: "slot::")?.description == "2026.05")
        #expect(SlotName(label: "slot::2026.51", prefix: "") == nil)
        #expect(SlotName(label: "other::2026.51", prefix: "slot::") == nil)
        for bad in ["26.51", "2026.54", "2026.0", "2026.00", "2026-51", "2026.51.1", "2026.", ".51", "2026.5x", "soon", ""] {
            #expect(SlotName(bad) == nil, "\(bad)")
        }
        #expect(SlotName("2026.51")! < SlotName("2027.01")!)
        #expect(SlotName("2026.09")! < SlotName("2026.10")!)
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
        // after the release, the slot is past, and still shown while it has open items
        #expect(states(on: Self.day(2026, 11, 3)) == ["2026.45": .past, "2026.48": .current, "2026.51": .upcoming])
    }

    @Test("SLOT-02 a past slot shows only while it has open committed items")
    func pastSlots() {
        let done = Self.item(1, slot: "2026.45", closed: true)
        let open = Self.item(2, slot: "2026.48")
        let plan = Self.plan([done, open], today: Self.day(2026, 11, 30))
        #expect(plan.slots.map(\.name.description) == ["2026.48"])
        let overdue = Self.plan([done, Self.item(3, slot: "2026.45")], today: Self.day(2026, 11, 30))
        #expect(overdue.slots.map(\.name.description) == ["2026.45"])
        #expect(overdue.slots[0].state == .past)
    }

    @Test("SLOT-02 the countdown names the next date")
    func countdown() throws {
        let dates = try #require(Self.dates("2026.51"))
        func text(_ today: Date) -> String { dates.countdown(from: today, calendar: Self.calendar) }
        #expect(text(Self.day(2026, 11, 27)) == "Code freeze in 3 days")
        #expect(text(Self.day(2026, 11, 29)) == "Code freeze tomorrow")
        #expect(text(Self.day(2026, 11, 30)) == "Code freeze today")
        #expect(text(Self.day(2026, 12, 1)) == "Early access in 6 days")
        #expect(text(Self.day(2026, 12, 8)) == "Release in 6 days")
        #expect(text(Self.day(2026, 12, 14)) == "Release today")
        #expect(text(Self.day(2026, 12, 15)) == "Released yesterday")
        #expect(text(Self.day(2026, 12, 20)) == "Released 6 days ago")
    }

    @Test("SLOT-02 groups the committed items by slot and counts the rest")
    func grouping() {
        let items = [
            Self.item(1), Self.item(2), Self.item(3, committed: false), Self.item(4, slot: "2027.03"),
            Self.item(5, slot: nil), Self.item(6, slot: "2026.54"),
        ]
        let plan = Self.plan(items, today: Self.day(2026, 10, 29))
        #expect(plan.slots.map(\.name.description) == ["2026.51", "2027.03"])
        #expect(plan.slots[0].items.map(\.workItem.reference) == ["acme/shop#1", "acme/shop#2"])
        #expect(plan.slots[0].uncommittedCount == 1)
        // no slot label, and a label that is no slot's name
        #expect(plan.withoutSlot == 2)
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
        today: Date = day(2026, 11, 20), team: TeamValues = team()
    ) -> [String: [SlotFlag.Kind]] {
        Dictionary(
            uniqueKeysWithValues: plan(items, mergeRequests: mergeRequests, builds: builds, today: today, team: team).slots
                .flatMap(\.items).map { ($0.workItem.reference, $0.flags.map(\.kind)) })
    }

    @Test("SLOT-03 an item in progress whose merge request is merged and not red is ready to verify")
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
        let plan = Self.plan([inProgress], mergeRequests: [1: [Self.mergeRequest(11, .merged)]], today: Self.day(2026, 11, 20))
        #expect(plan.slots[0].items[0].flags[0].fixURL == inProgress.webURL)
    }

    @Test("SLOT-03 the team's in-progress label replaces the guess")
    func inProgressLabel() {
        let team = Self.team(TeamValues(inProgressLabel: "wip"))
        let flags = Self.flags(
            [Self.item(1, labels: ["wip"]), Self.item(2, labels: ["status::InProgress"])],
            [1: [Self.mergeRequest(11, .merged)], 2: [Self.mergeRequest(12, .merged)]], team: team)
        #expect(flags["acme/shop#1"] == [.readyToVerify])
        #expect(flags["acme/shop#2"] == [])
    }

    @Test("SLOT-03 a committed item with an open merge request and a red build has a red pipeline, fixed at the build")
    func redPipeline() throws {
        let item = Self.item(1)
        let plan = Self.plan(
            [item, Self.item(2), Self.item(3)],
            mergeRequests: [1: [Self.mergeRequest(11, .opened)], 2: [Self.mergeRequest(12, .opened)], 3: [Self.mergeRequest(13, .opened)]],
            builds: [11: .red, 12: .green, 13: .running], today: Self.day(2026, 11, 20))
        let items = plan.slots[0].items
        #expect(items.map { $0.flags.map(\.kind) } == [[.redPipeline], [], []])
        #expect(items[0].flags[0].fixURL == Self.buildURL(11))
        // without a known build, the fix is the merge request
        let noURL = SlotPlan.make(
            workItems: [item], mergeRequests: { _ in [Self.mergeRequest(11, .opened)] },
            build: { _ in BuildReality(signal: .red) }, team: Self.team(), today: Self.day(2026, 11, 20), calendar: Self.calendar)
        #expect(noURL.slots[0].items[0].flags[0].fixURL == Self.mergeRequest(11, .opened).webURL)
    }

    @Test("SLOT-03 no merge request is flagged only from the warning days before the code freeze")
    func noMergeRequest() {
        let items = [Self.item(1), Self.item(2), Self.item(3), Self.item(4, closed: true)]
        let mergeRequests = [2: [Self.mergeRequest(12, .opened)], 3: [Self.mergeRequest(13, .closed)]]
        // the code freeze of 2026.51 is Nov 30; warning days 3 means from Nov 27
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 11, 26))["acme/shop#1"] == [])
        let flags = Self.flags(items, mergeRequests, today: Self.day(2026, 11, 27))
        #expect(flags["acme/shop#1"] == [.noMergeRequest])
        #expect(flags["acme/shop#2"] == [])
        // a closed merge request is no work on it
        #expect(flags["acme/shop#3"] == [.noMergeRequest])
        // a done item needs none
        #expect(flags["acme/shop#4"] == [])
        // the team's warning days
        let wider = Self.team(TeamValues(slotWarnDays: "10"))
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 11, 20), team: wider)["acme/shop#1"] == [.noMergeRequest])
        // after the freeze it stays, while the slot isn't past
        #expect(Self.flags(items, mergeRequests, today: Self.day(2026, 12, 10))["acme/shop#1"] == [.noMergeRequest])
        // an answer GitLab hasn't given yet says nothing
        let unanswered = SlotPlan.make(
            workItems: [Self.item(1)], mergeRequests: { _ in nil }, build: { _ in nil }, team: Self.team(),
            today: Self.day(2026, 11, 28), calendar: Self.calendar)
        #expect(unanswered.slots[0].items[0].flags.isEmpty)
        // the merge requests that only mention the item don't count
        let ignored = Self.team(TeamValues(ignoredMergeRequestPrefix: "Change"))
        #expect(Self.flags([Self.item(1)], [1: [Self.mergeRequest(11, .opened)]], today: Self.day(2026, 11, 28), team: ignored)["acme/shop#1"] == [.noMergeRequest])
    }

    @Test("SLOT-03 a done item with a red build is flagged")
    func doneWithRedBuild() {
        let flags = Self.flags(
            [Self.item(1, closed: true), Self.item(2, closed: true)],
            [1: [Self.mergeRequest(11, .merged)], 2: [Self.mergeRequest(12, .merged)]], builds: [11: .red, 12: .green])
        #expect(flags["acme/shop#1"] == [.doneWithRedBuild])
        #expect(flags["acme/shop#2"] == [])
    }

    @Test("SLOT-03 flagged items come first, and the build comes from the app's builds")
    func order() {
        let plan = Self.plan(
            [Self.item(1), Self.item(2)], mergeRequests: [1: [Self.mergeRequest(11, .opened)], 2: [Self.mergeRequest(12, .opened)]],
            builds: [12: .red], today: Self.day(2026, 11, 20))
        #expect(plan.slots[0].items.map(\.workItem.reference) == ["acme/shop#2", "acme/shop#1"])
        #expect(plan.slots[0].flagCount == 1)
        #expect(plan.slots[0].items[0].mergeRequests[0].build?.signal == .red)
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
        #expect(notices(on: Self.day(2026, 11, 26)).isEmpty)
        let notice = notices(on: Self.day(2026, 11, 27)).first
        #expect(notice?.title == "Code freeze in 3 days")
        #expect(notice?.body == "2 committed items have no merged MR")
        #expect(notice?.subtitle == "Slot 2026.51")
        #expect(notice?.url == AppRoute.open(.slots).url)
        #expect(notices(on: Self.day(2026, 11, 29)).first?.title == "Code freeze tomorrow")
        #expect(notices(on: Self.day(2026, 11, 30)).first?.title == "Code freeze today")
        // after the freeze, and once announced, nothing more
        #expect(notices(on: Self.day(2026, 12, 1)).isEmpty)
        #expect(notices(on: Self.day(2026, 11, 28), announced: ["2026.51"]).isEmpty)
        // nothing to say when everything is merged
        let merged = Self.plan(
            [Self.item(1)], mergeRequests: [1: [Self.mergeRequest(11, .merged)]], today: Self.day(2026, 11, 28))
        #expect(SlotAlerts.notices(of: merged, warnDays: 3, announced: []).isEmpty)
        // one item reads in the singular
        let single = Self.plan([Self.item(1)], today: Self.day(2026, 11, 28))
        #expect(SlotAlerts.notices(of: single, warnDays: 3, announced: []).first?.body == "1 committed item has no merged MR")
        // and waits for GitLab's answers
        let unanswered = SlotPlan.make(
            workItems: [Self.item(1)], mergeRequests: { _ in nil }, build: { _ in nil }, team: Self.team(),
            today: Self.day(2026, 11, 28), calendar: Self.calendar)
        #expect(SlotAlerts.notices(of: unanswered, warnDays: 3, announced: []).isEmpty)
    }

    @Test("SLOT-04 the alert is off by default, posts a banner without a sound, and posts each slot once")
    @MainActor
    func alertAnnounce() async throws {
        let folder = try TemporaryFolder()
        let defaults = try #require(UserDefaults(suiteName: "SlotTests.\(UUID().uuidString)"))
        let effects = FakeEffects()
        let log = ActivityLog(folder: folder.url)
        let plan = Self.plan([Self.item(1)], today: Self.day(2026, 11, 28))
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

    @Test("SLOT-05 the slot values are team values: kept in a team file, empty in an older one, with a planning URL only for web pages")
    func teamValues() throws {
        let team = TeamValues(
            slotReleaseWeekday: "Friday", slotCodeFreezeDays: "10", slotEarlyAccessDays: "3", slotWarnDays: "5",
            inProgressLabel: "wip", slotPlanningURL: "https://planning.example.com/slots")
        let decoded = try JSONDecoder().decode(TeamValues.self, from: JSONEncoder().encode(team))
        #expect(decoded == team)
        #expect(decoded.slotPlanning?.host == "planning.example.com")
        let old = try JSONDecoder().decode(TeamValues.self, from: Data(#"{"committedLabel": "c"}"#.utf8))
        #expect(old.slotReleaseWeekday.isEmpty && old.slotPlanningURL.isEmpty && old.slotPlanning == nil)
        #expect(TeamValues(slotPlanningURL: "javascript:alert(1)").slotPlanning == nil)
        #expect(TeamValues(slotPlanningURL: "planning.example.com").slotPlanning == nil)
        #expect(TeamValues.Key.allCases.filter(\.isRequired).count == 3)
    }
}

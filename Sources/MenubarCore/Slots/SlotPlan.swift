import Foundation

/// What a build or pipeline says about a merge request's code (SLOT-03).
public enum BuildSignal: Hashable, Sendable {
    case green
    case red
    case running

    /// Reads a Jenkins build: SUCCESS is green, FAILURE and UNSTABLE are red, a running build runs; other results
    /// (aborted, not built) say nothing.
    public init?(_ build: Build) {
        switch build.phase {
        case .running: self = .running
        case .finished(let result, _):
            switch result {
            case .success: self = .green
            case .failure, .unstable: self = .red
            default: return nil
            }
        }
    }

    /// Reads a GitLab head pipeline; other statuses (canceled, skipped, …) say nothing.
    public init?(_ status: MergeRequest.PipelineStatus) {
        switch status {
        case .success: self = .green
        case .failed: self = .red
        case .running: self = .running
        default: return nil
        }
    }
}

/// The build of a merge request that the app knows, with the page that opens it.
public struct BuildReality: Hashable, Sendable {
    public var signal: BuildSignal
    /// the Jenkins build's or GitLab pipeline's page; `nil` when the team has no Jenkins job URL
    public var url: URL?
    /// like "#7", the build's number; `nil` for a GitLab pipeline
    public var label: String?

    public init(signal: BuildSignal, url: URL? = nil, label: String? = nil) {
        self.signal = signal
        self.url = url
        self.label = label
    }
}

/// A merge request of a slot's work item with its build.
public struct SlotMergeRequest: Hashable, Sendable, Identifiable {
    public var mergeRequest: RelatedMergeRequest
    /// the build the app knows: Jenkins' (mine and the watched ones), else GitLab's head pipeline of my open MRs;
    /// `nil` when it knows none
    public var build: BuildReality?

    public init(mergeRequest: RelatedMergeRequest, build: BuildReality? = nil) {
        self.mergeRequest = mergeRequest
        self.build = build
    }

    public var id: URL { mergeRequest.webURL }
}

/// A problem that only the merge requests and the builds reveal, with the link that fixes it (SLOT-03).
public struct SlotFlag: Hashable, Sendable, Identifiable {
    public var kind: Kind
    /// the page to fix it on
    public var fixTitle: String
    public var fixURL: URL

    public init(kind: Kind, fixTitle: String, fixURL: URL) {
        self.kind = kind
        self.fixTitle = fixTitle
        self.fixURL = fixURL
    }

    public var id: Kind { kind }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// in progress, but its merge request is merged and not red
        case readyToVerify
        /// committed, with an open merge request whose build is red
        case redPipeline
        /// committed, within the warning days of the code freeze, and no merge request yet
        case noMergeRequest
        /// done, with a red build
        case doneWithRedBuild

        public var text: String {
            switch self {
            case .readyToVerify: "Ready to verify"
            case .redPipeline: "Red pipeline"
            case .noMergeRequest: "No merge request"
            case .doneWithRedBuild: "Done with a red build"
            }
        }

        /// the SF Symbol
        public var symbol: String {
            switch self {
            case .readyToVerify: "checkmark.seal"
            case .redPipeline, .doneWithRedBuild: "xmark.octagon"
            case .noMergeRequest: "exclamationmark.triangle"
            }
        }

        /// whether it is good news, which shows in the accent color and not as a warning
        public var isPositive: Bool { self == .readyToVerify }
    }
}

/// One work item of a slot with the real work it has: its merge requests, their builds and the flags (SLOT-03), and its
/// planning: progress, blocked, problems (SLOT-10, SLOT-11).
public struct SlotItem: Hashable, Sendable, Identifiable {
    public var workItem: WorkItem
    /// whether it has the committed label (every item does without one in Team); else it is Planned
    public var isCommitted: Bool
    /// whether it is finished: closed, or a status the team's tool closes it for, like Verified; it shows dimmed
    public var isDone: Bool
    /// whether it carries the in-progress label
    public var isInProgress: Bool
    /// the merge requests that count (not the ignored prefix's), newest first as GitLab sent them; empty without an
    /// answer too, see ``mergeRequestsLoaded``
    public var mergeRequests: [SlotMergeRequest]
    /// whether GitLab answered for its merge requests; epics have none and count as answered
    public var mergeRequestsLoaded: Bool
    public var flags: [SlotFlag]
    /// the status label's value, like `InVerification`; `nil` without one
    public var status: String? = nil
    /// how far it is, the tool's way: 1 Verified, 0.75 InVerification, else 0 (SLOT-10)
    public var progress: Double = 0
    /// whether it waits for another item, by the team's blocked label; never an epic (SLOT-10)
    public var isBlocked = false
    /// its planning gaps: no weight, no assignee (SLOT-11)
    public var problems: [SlotProblem] = []
    /// the slot it is committed to, when that is a later one than its slot; `nil` otherwise
    public var dueSlot: SlotName? = nil
    /// the sort's keys: the status's place and the priority (SLOT-12)
    var statusRank = 0
    var priority = 0

    public var id: String { workItem.id }

    /// whether a counted merge request is merged
    public var hasMergedMergeRequest: Bool {
        mergeRequests.contains { $0.mergeRequest.state == .merged }
    }

    /// the weight that counts: its own, 0 without one (SLOT-10)
    public var weight: Int { max(workItem.weight ?? 0, 0) }

    /// Returns whether one item sorts before another, the tool's default: the status's place, the priority high to low,
    /// then the reference (SLOT-12).
    public static func sortsBefore(_ left: SlotItem, _ right: SlotItem) -> Bool {
        if left.statusRank != right.statusRank { return left.statusRank < right.statusRank }
        if left.priority != right.priority { return left.priority > right.priority }
        return left.workItem.reference.localizedStandardCompare(right.workItem.reference) == .orderedAscending
    }
}

/// Whether a slot is overdue, the next one, or later (SLOT-02).
public enum SlotState: String, Hashable, Sendable {
    /// the release is before today and work is still open in it
    case overdue
    /// the release is before today and no work is open in it: one of the latest few, which Team's past slots shown lets
    /// show (SLOT-02)
    case released
    /// the next release not yet passed
    case current
    /// a later release, or a slot whose name isn't a week and has no dates
    case upcoming

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .released: "Released"
        case .current: "Current"
        case .upcoming: "Upcoming"
        }
    }
}

/// One slot with its dates, its state and its work items (SLOT-02).
public struct SlotSummary: Hashable, Sendable, Identifiable {
    public var name: SlotName
    /// the slot's label, with GitLab's color when known
    public var label: Label
    /// the dates; `nil` for a name that isn't a week (SLOT-01)
    public var dates: SlotDates?
    public var state: SlotState
    /// "Code freeze in 3 days"; "No dates" for a slot without
    public var countdown: String
    /// the days until the code freeze, negative once it passed; `nil` without dates
    public var daysToCodeFreeze: Int?
    /// the committed work items in the tool's order (SLOT-12)
    public var items: [SlotItem]
    /// the slot's work items without the committed label
    public var uncommittedCount: Int
    /// the work items without the committed label, as Planned (SLOT-06), in the tool's order
    public var planned: [SlotItem] = []
    /// what the slot can take under the chip, in person-days or points; `nil` shows no load (SLOT-08, SLOT-13)
    public var capacity: Double? = nil
    /// how many people the person-days are of; `nil` for points
    public var capacityPeople: Int? = nil
    /// the size problems of the epics, by the epic's reference (SLOT-11)
    public var epicProblems: [String: SlotProblem] = [:]
    /// the slot's commitments that have items here, with them, the top of the tree (SLOT-14)
    public var commitments: [SlotCommitmentGroup] = []

    public var id: SlotName { name }

    /// every item of the slot: the committed, then the planned
    public var allItems: [SlotItem] { items + planned }

    /// the weight of every item of the slot, done and planned ones too, as the tool's load counts it (SLOT-13)
    public var points: Int { allItems.reduce(0) { $0 + $1.weight } }

    /// the weight of the committed items, done ones too (SLOT-08)
    public var committedPoints: Int { items.reduce(0) { $0 + $1.weight } }

    /// the items without a weight, which the points don't count
    public var unweightedCount: Int { allItems.count { !$0.workItem.isEpic && $0.weight == 0 } }

    /// the points over the capacity, `0.74` for 74 %; `nil` without a capacity above 0 (SLOT-13)
    public var load: Double? {
        guard let capacity, capacity > 0 else { return nil }
        return Double(points) / capacity
    }

    /// how full the slot is; `nil` without a load (SLOT-13)
    public var loadLevel: SlotLoadLevel? { load.map(SlotLoadLevel.init) }

    /// the done weight over all the weight, the tool's progress: `0.5` is half; 0 without weight (SLOT-10)
    public var progress: Double { Self.progress(of: allItems) }

    /// the people the items are assigned to, each once, the most items first (SLOT-08)
    public var members: [MergeRequest.Person] {
        var counts: [String: (person: MergeRequest.Person, count: Int)] = [:]
        for person in allItems.flatMap({ $0.workItem.assignees ?? [] }) {
            counts[person.username, default: (person, 0)].count += 1
        }
        return counts.values.sorted { ($1.count, $0.person.username) < ($0.count, $1.person.username) }.map(\.person)
    }

    /// the items by their epic, as ``SlotEpicGroup/groups(of:problems:)`` orders them (SLOT-08)
    public var epicGroups: [SlotEpicGroup] { SlotEpicGroup.groups(of: allItems, problems: epicProblems) }

    /// the epic groups with the items no commitment has: the rest of the tree after the commitments (SLOT-14)
    public var otherGroups: [SlotEpicGroup] {
        guard !commitments.isEmpty else { return epicGroups }
        let under = Set(commitments.flatMap(\.items).map(\.id))
        return epicGroups.compactMap { group in
            var rest = group
            rest.items = group.items.filter { !under.contains($0.id) }
            return rest.items.isEmpty ? nil : rest
        }
    }

    /// the committed items that aren't done
    public var openItems: [SlotItem] { items.filter { !$0.isDone } }

    /// how many flags the items have
    public var flagCount: Int { items.reduce(0) { $0 + $1.flags.count } }

    /// how many planning problems the items and the epics have (SLOT-11)
    public var problemCount: Int { allItems.reduce(0) { $0 + $1.problems.count } + epicProblems.count }

    /// how many open items have no weight (SLOT-11)
    public var weightMissingCount: Int { allItems.count { $0.problems.contains { $0.kind == .weightMissing } } }

    /// "3 of 8 done", or "No work items" when the app has none
    public var progressText: String {
        let all = allItems
        guard !all.isEmpty else { return "No work items" }
        return "\(all.count { $0.isDone }) of \(all.count) done"
    }

    /// Returns the done weight over all the weight of items: each item's weight times its progress; 0 without weight
    /// (SLOT-10).
    public static func progress(of items: [SlotItem]) -> Double {
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return items.reduce(0.0) { $0 + Double($1.weight) * $1.progress } / Double(total)
    }
}

/// The slots, built from the work items, the merge requests and the builds the app already has (SLOT-02, SLOT-03).
public struct SlotPlan: Hashable, Sendable {
    /// the slots to show by release date: the latest ``SlotRules/pastShown`` released ones (Team; 2 by default), more
    /// overdue ones while they have open items, the current one, the next ``SlotRules/upcomingShown`` (Team; 4 by
    /// default) and later ones that have committed items, then the slots without dates that have open items
    public var slots: [SlotSummary]
    /// the work items without a slot, which don't show
    public var withoutSlot: Int

    public init(slots: [SlotSummary] = [], withoutSlot: Int = 0) {
        self.slots = slots
        self.withoutSlot = withoutSlot
    }

    /// the slot that is current, if any
    public var current: SlotSummary? { slots.first { $0.state == .current } }

    /// Builds the plan.
    ///
    /// - Slots come from the slot labels of the work items and from `knownLabels`, which should hold every slot label
    ///   GitLab has. A week the year doesn't have is left out; a name that isn't a week shows without dates, while it
    ///   has open items.
    /// - An item's slot is its scheduled slot label's, as in the team's slot planning web tool (``slot(of:team:)``).
    /// - The current slot is the earliest slot, of all of them, whose release is today or later.
    /// - Committed work items have the committed label; without one in Team, all work items count.
    /// - The flags are ``SlotFlag/Kind``: ready to verify, red pipeline, no merge request and done with a red build. The
    ///   problems are ``SlotProblem/Kind``.
    ///
    /// - Parameters:
    ///   - workItems: the loaded work items
    ///   - mergeRequests: the related merge requests of a work item; `nil` before GitLab answered
    ///   - build: the build the app knows of a merge request
    ///   - knownLabels: more labels, like GitLab's slot labels and the remembered ones, whose slots show without items
    ///   - team: the team values: the slot prefixes, the committed label, the status, priority, size and blocked
    ///     labels, the ignored MR prefix and the date rules
    ///   - capacity: what each slot can take, for its load; `nil` shows none
    ///   - epicWeights: the weight of everything under an epic, in any slot, by the epic's reference, for its size
    ///   - commitments: the commitments of the slots, each in the slot of its scheduled slot label (SLOT-14)
    ///   - today: the current time
    ///   - calendar: the calendar whose time zone and days count
    public static func make(
        workItems: [WorkItem],
        mergeRequests: (WorkItem) -> [RelatedMergeRequest]?,
        build: (RelatedMergeRequest) -> BuildReality?,
        knownLabels: [Label] = [],
        team: TeamValues,
        capacity: SlotCapacity? = nil,
        epicWeights: [String: Int] = [:],
        commitments: [SlotCommitment] = [],
        today: Date,
        calendar: Calendar = .current
    ) -> SlotPlan {
        let prefix = team.slotPrefix
        let rules = SlotRules(team: team)
        guard !prefix.isEmpty else { return SlotPlan() }

        var labels: [SlotName: Label] = [:]
        for label in workItems.flatMap(\.labels) + knownLabels {
            if let name = SlotName(label: label.title, prefix: prefix), labels[name] == nil || labels[name]?.color == nil {
                labels[name] = label
            }
        }
        var items: [SlotName: [SlotItem]] = [:]
        var planned: [SlotName: [SlotItem]] = [:]
        var withoutSlot = 0
        for workItem in workItems {
            guard let name = slot(of: workItem, team: team) else {
                withoutSlot += 1
                continue
            }
            if labels[name] == nil {
                labels[name] = Label(title: prefix + name.description)
            }
            var slotItem = item(workItem, mergeRequests: mergeRequests, build: build, team: team)
            if let due = dueSlot(of: workItem, team: team), due != name {
                slotItem.dueSlot = due
            }
            if slotItem.isCommitted {
                items[name, default: []].append(slotItem)
            } else {
                planned[name, default: []].append(slotItem)
            }
        }

        var commitmentsBySlot: [SlotName: [SlotCommitment]] = [:]
        for commitment in commitments {
            if let name = commitment.labels.lazy.compactMap({ SlotName(label: $0.title, prefix: prefix) }).first {
                commitmentsBySlot[name, default: []].append(commitment)
            }
        }

        let start = calendar.startOfDay(for: today)
        var summaries: [SlotSummary] = []
        var undated: [SlotSummary] = []
        for (name, label) in labels {
            let dates = rules.dates(of: name, calendar: calendar)
            if dates == nil, name.isoWeek != nil { continue }
            let daysToFreeze = dates.map { SlotRules.days(from: start, to: $0.codeFreeze, calendar: calendar) }
            let isPast = dates.map { $0.release < start } ?? false
            let slotItems = (items[name] ?? [])
                .map { flagged($0, rules: rules, daysToFreeze: daysToFreeze, isPast: isPast) }
                .sorted(by: SlotItem.sortsBefore)
            let slotPlanned = (planned[name] ?? []).sorted(by: SlotItem.sortsBefore)
            let all = slotItems + slotPlanned
            // A past slot, and one without dates, shows only while work is left in it; a past one without also when it is
            // one of the latest released (below).
            let hasOpen = all.contains { !$0.isDone }
            if dates == nil, !hasOpen { continue }
            var epicProblems: [String: SlotProblem] = [:]
            for epic in all.compactMap(\.workItem.epic) where epicProblems[epic.reference] == nil {
                if let problem = SlotProblem.sizeProblem(
                    of: epic, weight: epicWeights[epic.reference], prefix: team.sizeLabelPrefix)
                {
                    epicProblems[epic.reference] = problem
                }
            }
            let (slotCapacity, people) = Self.capacity(capacity, dates: dates, items: all, calendar: calendar)
            var summary = SlotSummary(
                name: name, label: label, dates: dates, state: isPast ? (hasOpen ? .overdue : .released) : .upcoming,
                countdown: dates?.countdown(from: today, calendar: calendar) ?? "No dates", daysToCodeFreeze: daysToFreeze,
                items: slotItems, uncommittedCount: slotPlanned.count, planned: slotPlanned, capacity: slotCapacity,
                capacityPeople: people, epicProblems: epicProblems)
            summary.commitments = SlotCommitmentGroup.groups(of: commitmentsBySlot[name] ?? [], in: summary.epicGroups)
            if dates == nil {
                undated.append(summary)
            } else {
                summaries.append(summary)
            }
        }
        summaries.sort { ($0.dates?.release ?? .distantFuture) < ($1.dates?.release ?? .distantFuture) }
        // Of the released slots, the overdue ones show, and the latest ones as Team says.
        summaries = Self.keepingLatestReleased(summaries, count: rules.pastShown)
        // The current slot is the earliest of all known slots not yet released, whoever's items are in it.
        if let index = summaries.firstIndex(where: { $0.state == .upcoming }) {
            summaries[index].state = .current
            // Every label GitLab has can reach years ahead: after the next few, only slots with committed items show.
            var shown = 0
            summaries = summaries.enumerated().filter { offset, summary in
                guard offset > index else { return true }
                shown += 1
                return shown <= rules.upcomingShown || !summary.items.isEmpty
            }.map(\.element)
        }
        return SlotPlan(slots: summaries + undated.sorted { $0.name < $1.name }, withoutSlot: withoutSlot)
    }

    /// Returns the slots with the released ones that have no open work left out, except the latest `count` of the released
    /// slots (SLOT-02). The slots are in release order.
    static func keepingLatestReleased(_ slots: [SlotSummary], count: Int) -> [SlotSummary] {
        let latest = Set(slots.filter { $0.state == .overdue || $0.state == .released }.suffix(count).map(\.name))
        return slots.filter { $0.state != .released || latest.contains($0.name) }
    }

    /// Returns a slot's capacity and how many people it is of: people count only when one of the slot's issues is
    /// assigned to them, as in the team's tool, where a member without an item adds no days (SLOT-13).
    private static func capacity(
        _ capacity: SlotCapacity?, dates: SlotDates?, items: [SlotItem], calendar: Calendar
    ) -> (Double?, Int?) {
        switch capacity {
        case nil:
            return (nil, nil)
        case .points:
            return (capacity?.value(dates: dates, calendar: calendar), nil)
        case .people(let members, let workDays):
            let assigned = Set(items.filter { !$0.workItem.isEpic }.flatMap { $0.workItem.assignees ?? [] }.map { $0.username.lowercased() })
            let working = members.filter { assigned.contains($0.lowercased()) }
            let value = SlotCapacity.people(working, workDays: workDays).value(dates: dates, calendar: calendar)
            return (value, value == nil ? nil : working.count)
        }
    }

    // MARK: - Items

    /// Returns a work item's slot: its scheduled slot label's, as the team's slot planning web tool groups by; with no
    /// scheduled prefix in Team, its slot label's (SLOT-06). The bot sets the scheduled slot to the earlier of the planned
    /// and the due slot, so a committed item due later is still in the earlier slot.
    ///
    /// - Parameters:
    ///   - workItem: the work item
    ///   - team: the slot label prefixes
    /// - Returns: the slot; `nil` without one
    public static func slot(of workItem: WorkItem, team: TeamValues) -> SlotName? {
        let prefix = team.slotPrefix
        guard !prefix.isEmpty else { return nil }
        return workItem.labels.lazy.compactMap { SlotName(label: $0.title, prefix: prefix) }.first
    }

    /// Returns a work item's due slot, the slot it is committed to; `nil` without one, or without a scheduled prefix in
    /// Team (SLOT-06).
    public static func dueSlot(of workItem: WorkItem, team: TeamValues) -> SlotName? {
        guard let prefix = team.dueSlotPrefix else { return nil }
        return workItem.labels.lazy.compactMap { SlotName(label: $0.title, prefix: prefix) }.first
    }

    /// Returns a work item with its counted merge requests and their builds, its planning and its problems, without
    /// flags: the plan flags only the committed items of a shown slot.
    static func item(
        _ workItem: WorkItem, mergeRequests: (WorkItem) -> [RelatedMergeRequest]?,
        build: (RelatedMergeRequest) -> BuildReality?, team: TeamValues
    ) -> SlotItem {
        let answer = mergeRequests(workItem)
        let ignored = team.ignoredMergeRequestPrefix
        let counted = (answer ?? []).filter { ignored.isEmpty || !$0.title.hasPrefix(ignored) }
        let status = SlotStatusRules.value(of: workItem, prefix: team.statusLabelPrefix)
        return SlotItem(
            workItem: workItem,
            isCommitted: team.committedLabel.isEmpty || workItem.labels.contains { $0.title == team.committedLabel },
            isDone: SlotStatusRules.isDone(workItem, statusPrefix: team.statusLabelPrefix),
            isInProgress: isInProgress(workItem, label: team.inProgressLabel),
            mergeRequests: counted.map { SlotMergeRequest(mergeRequest: $0, build: build($0)) },
            mergeRequestsLoaded: answer != nil || workItem.isEpic,
            flags: [],
            status: status,
            progress: SlotStatusRules.progress(of: workItem, statusPrefix: team.statusLabelPrefix),
            isBlocked: SlotStatusRules.isBlocked(workItem, team: team),
            problems: SlotProblem.problems(of: workItem),
            statusRank: SlotStatusRules.rank(of: status),
            priority: SlotStatusRules.priority(of: workItem, prefix: team.priorityLabelPrefix))
    }

    /// Returns whether a work item is being worked on: it has the in-progress label of Team, or without one a label
    /// whose value is "in progress" in any spelling (`status::InProgress`, `in-progress`).
    static func isInProgress(_ workItem: WorkItem, label: String) -> Bool {
        workItem.labels.contains { candidate in
            if !label.isEmpty {
                return candidate.title.caseInsensitiveCompare(label) == .orderedSame
            }
            let value = candidate.title.components(separatedBy: "::").last ?? candidate.title
            return value.lowercased().filter { $0.isLetter } == "inprogress"
        }
    }

    // MARK: - Flags

    private static func flagged(
        _ item: SlotItem, rules: SlotRules, daysToFreeze: Int?, isPast: Bool
    ) -> SlotItem {
        var item = item
        let itemURL = item.workItem.webURL
        let alive = item.mergeRequests.filter { $0.mergeRequest.state != .closed }
        let open = alive.filter { $0.mergeRequest.state == .opened }
        let merged = alive.filter { $0.mergeRequest.state == .merged }
        let red = alive.first { $0.build?.signal == .red }
        var flags: [SlotFlag] = []
        if item.isDone {
            if let red {
                flags.append(SlotFlag(kind: .doneWithRedBuild, fixTitle: "Show Build", fixURL: red.build?.url ?? red.mergeRequest.webURL))
            }
        } else {
            if item.isInProgress, open.isEmpty, !merged.isEmpty,
                !merged.contains(where: { $0.build?.signal == .red || $0.build?.signal == .running })
            {
                flags.append(SlotFlag(kind: .readyToVerify, fixTitle: "Show Work Item", fixURL: itemURL))
            }
            if let red = open.first(where: { $0.build?.signal == .red }) {
                flags.append(SlotFlag(kind: .redPipeline, fixTitle: "Show Build", fixURL: red.build?.url ?? red.mergeRequest.webURL))
            }
            if !isPast, let daysToFreeze, item.mergeRequestsLoaded, !item.workItem.isEpic, alive.isEmpty,
                daysToFreeze <= rules.warnDays
            {
                flags.append(SlotFlag(kind: .noMergeRequest, fixTitle: "Show Work Item", fixURL: itemURL))
            }
        }
        item.flags = flags
        return item
    }
}

/// The items of a slot under one epic, or under none (SLOT-08).
public struct SlotEpicGroup: Hashable, Sendable, Identifiable {
    /// the epic; `nil` for the items without one
    public var epic: WorkItemEpic?
    /// in the tool's order: status, priority, reference (SLOT-12)
    public var items: [SlotItem]
    /// the epic's size problem (SLOT-11)
    public var problem: SlotProblem? = nil

    public var id: String { epic?.reference ?? "" }

    /// this slot's share of the epic's progress: the done weight of its items here over their weight, the tool's way;
    /// the epic's items in other slots don't count (SLOT-10)
    public var progress: Double { SlotSummary.progress(of: items) }

    /// the weight of its items in this slot
    public var points: Int { items.reduce(0) { $0 + $1.weight } }

    /// Returns the items grouped by their epic: the epics with open items first, then by title; the items without an
    /// epic last. Each group keeps the items' order.
    ///
    /// - Parameters:
    ///   - items: the slot's items, sorted
    ///   - problems: the epics' size problems by their reference
    /// - Returns: the groups
    public static func groups(of items: [SlotItem], problems: [String: SlotProblem] = [:]) -> [SlotEpicGroup] {
        var order: [String] = []
        var byEpic: [String: SlotEpicGroup] = [:]
        for item in items {
            let key = item.workItem.epic?.reference ?? ""
            if byEpic[key] == nil {
                order.append(key)
                byEpic[key] = SlotEpicGroup(epic: item.workItem.epic, items: [], problem: problems[key])
            }
            byEpic[key]?.items.append(item)
        }
        var groups = order.compactMap { byEpic[$0] }
        for index in groups.indices {
            groups[index].items.sort(by: SlotItem.sortsBefore)
        }
        return groups.sorted { left, right in
            func key(_ group: SlotEpicGroup) -> (Int, Int, String) {
                (group.epic == nil ? 1 : 0, group.items.contains { !$0.isDone } ? 0 : 1, group.epic?.title.lowercased() ?? "")
            }
            return key(left) < key(right)
        }
    }
}

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

/// One work item of a slot with the real work it has: its merge requests, their builds and the flags (SLOT-03).
public struct SlotItem: Hashable, Sendable, Identifiable {
    public var workItem: WorkItem
    /// whether it has the committed label (every item does without one in Team)
    public var isCommitted: Bool
    /// whether it is closed
    public var isDone: Bool
    /// whether it carries the in-progress label
    public var isInProgress: Bool
    /// the merge requests that count (not the ignored prefix's), newest first as GitLab sent them; empty without an
    /// answer too, see ``mergeRequestsLoaded``
    public var mergeRequests: [SlotMergeRequest]
    /// whether GitLab answered for its merge requests; epics have none and count as answered
    public var mergeRequestsLoaded: Bool
    public var flags: [SlotFlag]

    public var id: String { workItem.id }

    /// whether a counted merge request is merged
    public var hasMergedMergeRequest: Bool {
        mergeRequests.contains { $0.mergeRequest.state == .merged }
    }
}

/// Whether a slot is overdue, the next one, or later (SLOT-02).
public enum SlotState: String, Hashable, Sendable {
    /// the release is before today and work is still open in it; a slot behind us without open work isn't shown
    case overdue
    /// the next release not yet passed
    case current
    case upcoming

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .current: "Current"
        case .upcoming: "Upcoming"
        }
    }
}

/// One slot with its dates, its state and the committed work items the app has (SLOT-02).
public struct SlotSummary: Hashable, Sendable, Identifiable {
    public var name: SlotName
    /// the slot's label, with GitLab's color when known
    public var label: Label
    public var dates: SlotDates
    public var state: SlotState
    /// "Code freeze in 3 days"
    public var countdown: String
    /// the days until the code freeze, negative once it passed
    public var daysToCodeFreeze: Int
    /// the committed work items, flagged ones first
    public var items: [SlotItem]
    /// the slot's work items without the committed label
    public var uncommittedCount: Int
    /// the work items without the committed label, by the slot or the scheduled slot label, as Planned (SLOT-06)
    public var planned: [SlotItem] = []
    /// the points the slot can take under the chip, from the squad capacity; `nil` shows no load (SLOT-08)
    public var capacity: Int? = nil

    public var id: SlotName { name }

    /// the weight of the committed items, done ones too: what the slot committed to (SLOT-08)
    public var committedPoints: Int { items.reduce(0) { $0 + ($1.workItem.weight ?? 0) } }

    /// the committed items without a weight, which the points don't count
    public var unweightedCount: Int { items.count { $0.workItem.weight == nil } }

    /// the committed points over the capacity, `0.74` for 74 %; `nil` without a capacity above 0 (SLOT-08)
    public var load: Double? {
        guard let capacity, capacity > 0 else { return nil }
        return Double(committedPoints) / Double(capacity)
    }

    /// the people the committed and planned items are assigned to, each once, the most items first (SLOT-08)
    public var members: [MergeRequest.Person] {
        var counts: [String: (person: MergeRequest.Person, count: Int)] = [:]
        for person in (items + planned).flatMap({ $0.workItem.assignees ?? [] }) {
            counts[person.username, default: (person, 0)].count += 1
        }
        return counts.values.sorted { ($1.count, $0.person.username) < ($0.count, $1.person.username) }.map(\.person)
    }

    /// the committed and then the planned items by their epic, as ``SlotEpicGroup/groups(of:)`` orders them (SLOT-08)
    public var epicGroups: [SlotEpicGroup] { SlotEpicGroup.groups(of: items + planned) }

    /// the committed items that aren't done
    public var openItems: [SlotItem] { items.filter { !$0.isDone } }

    /// how many flags the items have
    public var flagCount: Int { items.reduce(0) { $0 + $1.flags.count } }

    /// "3 of 8 done", or "No committed work items" when the app has none
    public var progressText: String {
        guard !items.isEmpty else { return "No committed work items" }
        return "\(items.count { $0.isDone }) of \(items.count) done"
    }
}

/// The slots, built from the work items, the merge requests and the builds the app already has (SLOT-02, SLOT-03).
public struct SlotPlan: Hashable, Sendable {
    /// the slots to show by release date: the current one, the next ``SlotRules/upcomingShown`` (Team; 4 by default) and later ones that have committed
    /// items, and an overdue one while it has open items
    public var slots: [SlotSummary]
    /// the work items without a slot (or with a label that isn't a slot's name), which don't show
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
    ///   GitLab has. A slot whose name has no date (a week the year hasn't) is left out.
    /// - The current slot is the earliest slot, of all of them, whose release is today or later.
    /// - Committed work items have the committed label; without one in Team, all work items count.
    /// - The flags are ``SlotFlag/Kind``: ready to verify, red pipeline, no merge request and done with a red build.
    ///
    /// - Parameters:
    ///   - workItems: the loaded work items
    ///   - mergeRequests: the related merge requests of a work item; `nil` before GitLab answered
    ///   - build: the build the app knows of a merge request
    ///   - knownLabels: more labels, like GitLab's slot labels and the remembered ones, whose slots show without items
    ///   - team: the team values: the slot and scheduled slot prefixes, the committed label, the ignored MR prefix and
    ///     the date rules
    ///   - capacity: the points each slot can take, for its load; `nil` shows none
    ///   - today: the current time
    ///   - calendar: the calendar whose time zone and days count
    public static func make(
        workItems: [WorkItem],
        mergeRequests: (WorkItem) -> [RelatedMergeRequest]?,
        build: (RelatedMergeRequest) -> BuildReality?,
        knownLabels: [Label] = [],
        team: TeamValues,
        capacity: Int? = nil,
        today: Date,
        calendar: Calendar = .current
    ) -> SlotPlan {
        let prefix = team.slotLabelPrefix
        let rules = SlotRules(team: team)
        guard !prefix.isEmpty else { return SlotPlan() }

        var labels: [SlotName: Label] = [:]
        for label in workItems.flatMap(\.labels) + knownLabels {
            if let name = SlotName(label: label.title, prefix: prefix), labels[name] == nil || labels[name]?.color == nil {
                labels[name] = label
            }
        }
        var items: [SlotName: [SlotItem]] = [:]
        var uncommitted: [SlotName: Int] = [:]
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
            let isCommitted = team.committedLabel.isEmpty || workItem.labels.contains { $0.title == team.committedLabel }
            guard isCommitted else {
                uncommitted[name, default: 0] += 1
                planned[name, default: []].append(
                    item(workItem, mergeRequests: mergeRequests, build: build, team: team))
                continue
            }
            items[name, default: []].append(
                item(workItem, mergeRequests: mergeRequests, build: build, team: team))
        }

        let start = calendar.startOfDay(for: today)
        var summaries: [SlotSummary] = []
        for (name, label) in labels {
            guard let dates = rules.dates(of: name, calendar: calendar) else { continue }
            let daysToFreeze = SlotRules.days(from: start, to: dates.codeFreeze, calendar: calendar)
            let isPast = dates.release < start
            var slotItems = (items[name] ?? []).map { flagged($0, rules: rules, daysToFreeze: daysToFreeze, isPast: isPast) }
            slotItems.sort { ($0.flags.isEmpty ? 1 : 0, $0.workItem.reference) < ($1.flags.isEmpty ? 1 : 0, $1.workItem.reference) }
            // A past slot shows only while work is left in it.
            if isPast, !slotItems.contains(where: { !$0.isDone }) { continue }
            summaries.append(
                SlotSummary(
                    name: name, label: label, dates: dates, state: isPast ? .overdue : .upcoming,
                    countdown: dates.countdown(from: today, calendar: calendar), daysToCodeFreeze: daysToFreeze,
                    items: slotItems, uncommittedCount: uncommitted[name] ?? 0,
                    planned: (planned[name] ?? []).sorted { $0.workItem.reference < $1.workItem.reference },
                    capacity: capacity))
        }
        summaries.sort { $0.dates.release < $1.dates.release }
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
        return SlotPlan(slots: summaries, withoutSlot: withoutSlot)
    }

    // MARK: - Items

    /// Returns a work item's slot: its slot label's, else its scheduled slot label's (SLOT-06).
    ///
    /// - Parameters:
    ///   - workItem: the work item
    ///   - team: the slot and the scheduled slot label prefixes
    /// - Returns: the slot; `nil` without one
    public static func slot(of workItem: WorkItem, team: TeamValues) -> SlotName? {
        for prefix in [team.slotLabelPrefix, team.slotScheduledLabelPrefix] where !prefix.isEmpty {
            if let name = workItem.labels.lazy.compactMap({ SlotName(label: $0.title, prefix: prefix) }).first {
                return name
            }
        }
        return nil
    }

    /// Returns a work item with its counted merge requests and their builds, without flags: the plan flags only the
    /// committed items of a shown slot.
    static func item(
        _ workItem: WorkItem, mergeRequests: (WorkItem) -> [RelatedMergeRequest]?,
        build: (RelatedMergeRequest) -> BuildReality?, team: TeamValues
    ) -> SlotItem {
        let answer = mergeRequests(workItem)
        let ignored = team.ignoredMergeRequestPrefix
        let counted = (answer ?? []).filter { ignored.isEmpty || !$0.title.hasPrefix(ignored) }
        return SlotItem(
            workItem: workItem,
            isCommitted: team.committedLabel.isEmpty || workItem.labels.contains { $0.title == team.committedLabel },
            isDone: workItem.state == .closed,
            isInProgress: isInProgress(workItem, label: team.inProgressLabel),
            mergeRequests: counted.map { SlotMergeRequest(mergeRequest: $0, build: build($0)) },
            mergeRequestsLoaded: answer != nil || workItem.isEpic,
            flags: [])
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
        _ item: SlotItem, rules: SlotRules, daysToFreeze: Int, isPast: Bool
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
            if !isPast, item.mergeRequestsLoaded, !item.workItem.isEpic, alive.isEmpty, daysToFreeze <= rules.warnDays {
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
    /// flagged ones first, then the open ones, then the done ones
    public var items: [SlotItem]

    public var id: String { epic?.reference ?? "" }

    /// the done items' weight over all items' weight, an item without a weight counting 1; `0.5` is half (SLOT-08)
    public var progress: Double {
        let weights = items.map { (done: $0.isDone, weight: max($0.workItem.weight ?? 1, 0)) }
        let total = weights.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return items.allSatisfy(\.isDone) && !items.isEmpty ? 1 : 0 }
        return Double(weights.filter(\.done).reduce(0) { $0 + $1.weight }) / Double(total)
    }

    /// Returns the items grouped by their epic: the epics with open items first, then by title; the items without an
    /// epic last.
    ///
    /// - Parameter items: the slot's items
    /// - Returns: the groups
    public static func groups(of items: [SlotItem]) -> [SlotEpicGroup] {
        var order: [String] = []
        var byEpic: [String: SlotEpicGroup] = [:]
        for item in items {
            let key = item.workItem.epic?.reference ?? ""
            if byEpic[key] == nil {
                order.append(key)
                byEpic[key] = SlotEpicGroup(epic: item.workItem.epic, items: [])
            }
            byEpic[key]?.items.append(item)
        }
        var groups = order.compactMap { byEpic[$0] }
        for index in groups.indices {
            groups[index].items.sort {
                ($0.flags.isEmpty ? 1 : 0, $0.isDone ? 1 : 0, $0.workItem.reference)
                    < ($1.flags.isEmpty ? 1 : 0, $1.isDone ? 1 : 0, $1.workItem.reference)
            }
        }
        return groups.sorted { left, right in
            func key(_ group: SlotEpicGroup) -> (Int, Int, String) {
                (group.epic == nil ? 1 : 0, group.items.contains { !$0.isDone } ? 0 : 1, group.epic?.title.lowercased() ?? "")
            }
            return key(left) < key(right)
        }
    }
}

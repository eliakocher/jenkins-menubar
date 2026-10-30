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

    public var id: SlotName { name }

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
    /// the slots to show by release date: the current and the upcoming ones, and an overdue one while it has open items
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
    /// - Slots come from the slot labels of the work items and from `knownLabels`. A slot whose name has no date (a
    ///   week the year hasn't) is left out.
    /// - Committed work items have the committed label; without one in Team, all work items count.
    /// - The flags are ``SlotFlag/Kind``: ready to verify, red pipeline, no merge request and done with a red build.
    ///
    /// - Parameters:
    ///   - workItems: the loaded work items
    ///   - mergeRequests: the related merge requests of a work item; `nil` before GitLab answered
    ///   - build: the build the app knows of a merge request
    ///   - knownLabels: more labels the app has seen, like the remembered ones, whose slots show without items
    ///   - team: the team values: the slot prefix, the committed label, the ignored MR prefix and the date rules
    ///   - today: the current time
    ///   - calendar: the calendar whose time zone and days count
    public static func make(
        workItems: [WorkItem],
        mergeRequests: (WorkItem) -> [RelatedMergeRequest]?,
        build: (RelatedMergeRequest) -> BuildReality?,
        knownLabels: [Label] = [],
        team: TeamValues,
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
        var withoutSlot = 0
        for workItem in workItems {
            guard let name = workItem.labels.lazy.compactMap({ SlotName(label: $0.title, prefix: prefix) }).first else {
                withoutSlot += 1
                continue
            }
            let isCommitted = team.committedLabel.isEmpty || workItem.labels.contains { $0.title == team.committedLabel }
            guard isCommitted else {
                uncommitted[name, default: 0] += 1
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
                    items: slotItems, uncommittedCount: uncommitted[name] ?? 0))
        }
        summaries.sort { $0.dates.release < $1.dates.release }
        if let index = summaries.firstIndex(where: { $0.state == .upcoming }) {
            summaries[index].state = .current
        }
        return SlotPlan(slots: summaries, withoutSlot: withoutSlot)
    }

    // MARK: - Items

    private static func item(
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
                flags.append(SlotFlag(kind: .doneWithRedBuild, fixTitle: "Open Build", fixURL: red.build?.url ?? red.mergeRequest.webURL))
            }
        } else {
            if item.isInProgress, open.isEmpty, !merged.isEmpty,
                !merged.contains(where: { $0.build?.signal == .red || $0.build?.signal == .running })
            {
                flags.append(SlotFlag(kind: .readyToVerify, fixTitle: "Open Work Item", fixURL: itemURL))
            }
            if let red = open.first(where: { $0.build?.signal == .red }) {
                flags.append(SlotFlag(kind: .redPipeline, fixTitle: "Open Build", fixURL: red.build?.url ?? red.mergeRequest.webURL))
            }
            if !isPast, item.mergeRequestsLoaded, !item.workItem.isEpic, alive.isEmpty, daysToFreeze <= rules.warnDays {
                flags.append(SlotFlag(kind: .noMergeRequest, fixTitle: "Open Work Item", fixURL: itemURL))
            }
        }
        item.flags = flags
        return item
    }
}

import Foundation

// MARK: - The daily digest's facts (AI-04)

/// One thing the daily digest is about, from the app's own stores (AI-04): a merge request of mine, a review waiting
/// on me, a red build, a work item, a slot, or a note of Claude's. The app knows its title, state and link; Claude only
/// adds why it matters and the next step.
public struct DigestItem: Codable, Hashable, Sendable, Identifiable {
    /// What the item is.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case mergeRequest
        case review
        case build
        case workItem
        case slot
        /// a remark of Claude's that is about no single item
        case note
    }

    public var kind: Kind
    /// the stable reference, unique in a digest and the same in the next one: `group/project!42`,
    /// `group/project#1234`, `build:main/MR-42`, `slot:2026.48`
    public var ref: String
    /// what a row shows of the reference: `!42`, `#1234`, `MR-42 #7`, `2026.48`
    public var shortRef: String
    public var title: String
    public var state: DigestState
    /// the facts after the state, a few words each: "1 of 2 approved", "by Sam Lee", "updated 3 h ago"
    public var details: [String]
    /// the item's page, which the app opens in its section; `nil` for a slot and a note
    public var link: URL?
    /// a work item's slot, like `2026.48`
    public var slot: String?
    /// the slot label's color as GitLab has it, `#rrggbb`; `nil` when unknown
    public var slotColor: String?
    /// the build Rebuild starts again: a finished red build whose project has its job in Team (PIPE-09)
    public var rebuild: BuildID?
    /// whether the app's own rules say it needs the developer now, for a digest whose answer doesn't say
    public var needsYou: Bool

    public init(
        kind: Kind, ref: String, shortRef: String, title: String, state: DigestState, details: [String] = [],
        link: URL? = nil, slot: String? = nil, slotColor: String? = nil, rebuild: BuildID? = nil, needsYou: Bool = false
    ) {
        self.kind = kind
        self.ref = ref
        self.shortRef = shortRef
        self.title = title
        self.state = state
        self.details = details
        self.link = link
        self.slot = slot
        self.slotColor = slotColor
        self.rebuild = rebuild
        self.needsYou = needsYou
    }

    public var id: String { ref }
}

/// An item's state as a badge: its words, an SF Symbol and one of GitLab's colors.
public struct DigestState: Codable, Hashable, Sendable {
    /// "Pipeline failed", "Review requested", "Code freeze in 3 days"
    public var text: String
    public var symbol: String
    public var color: MergeRequestStatus.Color

    public init(text: String, symbol: String, color: MergeRequestStatus.Color) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }
}

/// What the digest is written from: the items of the app's own stores, and the nearest slot date (AI-04).
public struct DigestFacts: Hashable, Sendable {
    /// in the order of their parts: my merge requests, reviews, red builds, work items, slots
    public var items: [DigestItem]
    /// the nearest date of a slot my open work items are in, like "Code freeze in 4 days"; `nil` without one
    public var deadline: Deadline?
    /// when the facts were gathered: the digest's identity, so asking again compares with the digest before
    public var gatheredAt: Date
    /// how many open work items of mine there are, also those past the cap of ``items``; the digest says "+N more in
    /// Work Items" for those it doesn't list
    public var openWorkItems: Int

    /// The nearest milestone of a slot.
    public struct Deadline: Hashable, Sendable {
        public var slot: String
        /// "Code freeze in 4 days", "Release tomorrow"
        public var text: String
        public var days: Int
        /// whether it is within the team's warning days, or past
        public var isClose: Bool

        public init(slot: String, text: String, days: Int, isClose: Bool) {
            self.slot = slot
            self.text = text
            self.days = days
            self.isClose = isClose
        }
    }

    public init(
        items: [DigestItem] = [], deadline: Deadline? = nil, gatheredAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        openWorkItems: Int = 0
    ) {
        self.items = items
        self.deadline = deadline
        self.gatheredAt = gatheredAt
        self.openWorkItems = openWorkItems
    }

    /// whether there is nothing to write about
    public var isEmpty: Bool { items.isEmpty }

    /// how many items each part lists at most
    public static let listedPerPart = 20

    /// Returns the items of a kind, in their order.
    public func items(_ kind: DigestItem.Kind) -> [DigestItem] {
        items.filter { $0.kind == kind }
    }

    /// Gathers the digest's facts from what the app has loaded (AI-04): my merge requests with their MR-02 status,
    /// the reviews waiting on me, the red builds (mine and watched, the newest of each job), my open work items, and
    /// the slots they are in with their next date (SLOT-01). The app's own rules mark what needs me now: a merge request
    /// of mine to merge or to fix, a review that isn't a draft, a red build of mine, a blocked item, a slot past its
    /// release or near its code freeze.
    ///
    /// - Parameters:
    ///   - mergeRequests: the merge requests in their sections; `nil` before the first load
    ///   - builds: the builds Pipelines follows, mine and watched
    ///   - workItems: the work items; empty before the first load
    ///   - me: my GitLab username; a work item assigned to others only isn't mine. `nil` when unknown: all count
    ///   - slotFlags: the Slots problem of a work item, by its reference: a red pipeline, or no merge request near the
    ///     code freeze, for the items of the current and next slot
    ///   - slotPrefix: the slot label prefix from Team; empty means no slots
    ///   - slotRules: how a slot's name becomes its dates
    ///   - jobURL: the Jenkins job of a build's project, for its page and Rebuild; `nil` when Team has none
    ///   - now: the current time, for the ages and the countdowns
    ///   - calendar: the calendar whose days count
    /// - Returns: the facts
    public static func gather(
        mergeRequests: MergeRequestSections?, builds: [Build], workItems: [WorkItem], me: String? = nil,
        slotFlags: [String: SlotFlag.Kind] = [:], slotPrefix: String, slotRules: SlotRules = SlotRules(), jobURL: (ProjectID) -> URL? = { _ in nil }, now: Date,
        calendar: Calendar = .current
    ) -> DigestFacts {
        var items: [DigestItem] = []
        let mine = (mergeRequests?.yours ?? []).prefix(listedPerPart)
        items += mine.map { mergeRequestItem($0, now: now) }
        let reviews = (mergeRequests?.reviewRequested ?? []).prefix(listedPerPart)
        items += reviews.map { reviewItem($0, now: now) }
        items += redBuilds(builds).prefix(listedPerPart).map { buildItem($0, jobURL: jobURL($0.project), now: now) }

        // Mine: assigned to me. Items of others only share the list's filter; the digest is about me.
        let open = workItems.filter { $0.state != .closed && !$0.isEpic && $0.isMine(me) }
        items += open.prefix(listedPerPart * 2).map {
            workItemItem($0, slotPrefix: slotPrefix, flag: slotFlags[$0.reference], now: now, calendar: calendar)
        }

        // The slots of my open items, by their next date.
        var counts: [String: Int] = [:]
        var colors: [String: String] = [:]
        for item in open {
            if let slot = item.slot(prefix: slotPrefix) {
                counts[slot, default: 0] += 1
                colors[slot] = colors[slot] ?? item.labels.first { $0.title == slotPrefix + slot }?.color
            }
        }
        var slots: [(item: DigestItem, days: Int, deadline: Deadline?)] = []
        for (name, count) in counts {
            guard let slot = SlotName(name), let dates = slotRules.dates(of: slot, calendar: calendar) else { continue }
            var slotted = slotItem(name, dates: dates, openItems: count, rules: slotRules, now: now, calendar: calendar)
            slotted.item.slotColor = colors[name]
            slots.append(slotted)
        }
        slots.sort { ($0.days, $0.item.ref) < ($1.days, $1.item.ref) }
        items += slots.map(\.item)
        // The nearest date that is still ahead.
        let deadline = slots.compactMap(\.deadline).min { $0.days < $1.days }
        return DigestFacts(items: items, deadline: deadline, gatheredAt: now, openWorkItems: open.count)
    }

    // MARK: The items

    private static func mergeRequestItem(_ mergeRequest: MergeRequest, now: Date) -> DigestItem {
        let status = MergeRequestStatus.of(mergeRequest)
        var details: [String] = []
        if !mergeRequest.reviewers.isEmpty {
            let approved = mergeRequest.reviewers.filter(\.approved).count
            details.append("\(approved) of \(mergeRequest.reviewers.count) approved")
        }
        if mergeRequest.pipelineStatus == .failed, status.kind != .pipelineFailed {
            details.append("pipeline failed")
        }
        details.append(age(mergeRequest.updatedAt, now: now, verb: "updated"))
        let needsYou: Set<MergeRequestStatus.Kind> = [
            .readyToMerge, .pipelineFailed, .conflicts, .needsRebase, .changesRequested, .unresolvedThreads,
        ]
        return DigestItem(
            kind: .mergeRequest, ref: mergeRequest.reference, shortRef: "!\(mergeRequest.iid)", title: mergeRequest.title,
            state: DigestState(text: status.text, symbol: status.symbol, color: status.color), details: details,
            link: mergeRequest.webURL, needsYou: needsYou.contains(status.kind))
    }

    private static func reviewItem(_ mergeRequest: MergeRequest, now: Date) -> DigestItem {
        let author = mergeRequest.author.name.isEmpty ? mergeRequest.author.username : mergeRequest.author.name
        var details = ["by \(author)"]
        if let stats = mergeRequest.diffStats {
            details.append("+\(stats.additions) −\(stats.deletions)")
        }
        details.append(age(mergeRequest.updatedAt, now: now, verb: "updated"))
        let state = mergeRequest.isDraft
            ? DigestState(text: "Draft", symbol: "pencil.circle.fill", color: .neutral)
            : DigestState(text: "Waiting on you", symbol: "eye.circle.fill", color: .orange)
        return DigestItem(
            kind: .review, ref: mergeRequest.reference, shortRef: "!\(mergeRequest.iid)", title: mergeRequest.title,
            state: state, details: details, link: mergeRequest.webURL, needsYou: !mergeRequest.isDraft)
    }

    /// The failed and unstable builds, the newest of each job, newest first.
    private static func redBuilds(_ builds: [Build]) -> [Build] {
        var newest: [String: Build] = [:]
        for build in builds where newest[build.jobKey].map({ $0.startedAt < build.startedAt }) ?? true {
            newest[build.jobKey] = build
        }
        return newest.values
            .filter { $0.result == .failure || $0.result == .unstable }
            .sorted { ($0.startedAt, $0.jobKey) > ($1.startedAt, $1.jobKey) }
    }

    private static func buildItem(_ build: Build, jobURL: URL?, now: Date) -> DigestItem {
        let state = build.result == .unstable
            ? DigestState(text: "Unstable", symbol: "exclamationmark.triangle.fill", color: .orange)
            : DigestState(text: "Failed", symbol: "xmark.circle.fill", color: .red)
        var details: [String] = []
        if let stages = build.failedStages, !stages.isEmpty {
            details.append("in \(stages.joined(separator: ", "))")
        }
        if let tests = build.testCounts, tests.failed > 0 {
            details.append("\(tests.failed) of \(tests.total) tests failed")
        }
        details.append(build.kind == .watched ? "watched" : "mine")
        details.append(age(build.finishedAt ?? build.startedAt, now: now, verb: "finished"))
        return DigestItem(
            kind: .build, ref: "build:\(build.jobKey)", shortRef: build.id.label, title: build.title ?? build.label,
            state: state, details: details,
            link: jobURL.map { AlertContent.buildURL(job: build.job, number: build.number, jobURL: $0) },
            rebuild: jobURL == nil ? nil : build.id, needsYou: build.kind != .watched)
    }

    private static func workItemItem(
        _ item: WorkItem, slotPrefix: String, flag: SlotFlag.Kind?, now: Date, calendar: Calendar
    ) -> DigestItem {
        let slot = item.slot(prefix: slotPrefix)
        let dueDays = item.dueDate.flatMap { day($0, calendar: calendar) }
            .map { SlotRules.days(from: now, to: $0, calendar: calendar) }
        var state = DigestState(text: "Open", symbol: "circle", color: .neutral)
        var needsYou = false
        var saysDue = false
        if item.isBlocked == true {
            state = DigestState(text: "Blocked", symbol: "hand.raised.fill", color: .red)
            needsYou = true
        } else if let days = dueDays, days <= 3 {
            state = days < 0
                ? DigestState(text: "Overdue", symbol: "calendar.badge.exclamationmark", color: .red)
                : DigestState(
                    text: days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days) days",
                    symbol: "calendar", color: .orange)
            needsYou = true
            saysDue = true
        } else if let flag {
            // The Slots problem the item has: a red pipeline, or no merge request near the code freeze.
            state = flag == .redPipeline
                ? DigestState(text: "Red pipeline", symbol: "xmark.octagon.fill", color: .red)
                : DigestState(text: "No merge request", symbol: "exclamationmark.triangle.fill", color: .orange)
            needsYou = true
        }
        var details = [item.type.rawValue.lowercased()]
        if let slot {
            details.append("slot \(slot)")
        }
        if let due = item.dueDate, !saysDue {
            details.append("due \(due.prefix(10))")
        }
        return DigestItem(
            kind: .workItem, ref: item.reference, shortRef: item.iid.map { "#\($0)" } ?? item.reference,
            title: item.displayTitle, state: state, details: details, link: item.webURL, slot: slot,
            slotColor: slot.flatMap { slot in item.labels.first { $0.title == slotPrefix + slot }?.color }, needsYou: needsYou)
    }

    private static func slotItem(
        _ name: String, dates: SlotDates, openItems: Int, rules: SlotRules, now: Date, calendar: Calendar
    ) -> (item: DigestItem, days: Int, deadline: Deadline?) {
        let countdown = dates.countdown(from: now, calendar: calendar)
        let next = dates.next(from: now, calendar: calendar)
        let freezeDays = SlotRules.days(from: now, to: dates.codeFreeze, calendar: calendar)
        let state: DigestState
        let needsYou: Bool
        if next == nil {
            // Released with my items still open.
            state = DigestState(text: countdown, symbol: "exclamationmark.circle.fill", color: .red)
            needsYou = true
        } else if freezeDays >= 0, freezeDays <= rules.warnDays {
            state = DigestState(text: countdown, symbol: "snowflake", color: .orange)
            needsYou = true
        } else {
            state = DigestState(text: countdown, symbol: "calendar", color: .blue)
            needsYou = false
        }
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar)
        let details = [
            openItems == 1 ? "1 open item of mine" : "\(openItems) open items of mine",
            "code freeze \(dates.codeFreeze.formatted(format))", "release \(dates.release.formatted(format))",
        ]
        let item = DigestItem(
            kind: .slot, ref: "slot:\(name)", shortRef: name, title: "Slot \(name)", state: state, details: details,
            slot: name, needsYou: needsYou)
        let deadline = next.map {
            Deadline(slot: name, text: countdown, days: $0.days, isClose: needsYou)
        }
        return (item, next?.days ?? -1, deadline)
    }

    /// "updated 3 h ago", "updated within the hour", "updated 4 days ago"
    static func age(_ date: Date, now: Date, verb: String) -> String {
        let hours = Int(now.timeIntervalSince(date) / 3600)
        return hours < 1 ? "\(verb) within the hour" : hours < 48 ? "\(verb) \(hours) h ago" : "\(verb) \(hours / 24) days ago"
    }

    /// A due date as GitLab gives it, `2026-11-10`, at the start of that day.
    private static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

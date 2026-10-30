import Foundation

extension AppModel {
    /// The slots of the primary project from what the app already has (SLOT-02, SLOT-03): its loaded work items, their
    /// related merge requests, the builds of Jenkins (mine and the watched ones) and the head pipelines of my merge
    /// requests, every slot label GitLab has, and the labels it remembers.
    ///
    /// - Parameters:
    ///   - now: the current time; the model's clock by default
    ///   - calendar: the calendar whose days count
    /// - Returns: the plan; empty before the work items loaded, and without a slot prefix in Team
    public func slotPlan(now: Date? = nil, calendar: Calendar = .current) -> SlotPlan {
        let team = pipelines.project.team
        let related = workItems.relatedMergeRequests
        let labels = workItems.labels
        let myMergeRequests = mergeRequests.list?.mergeRequests ?? []
        let stores = projects.stores
        return SlotPlan.make(
            workItems: workItems.lists?.all ?? [],
            mergeRequests: { related.entries[$0.reference]?.mergeRequests },
            build: { mergeRequest in
                Self.slotBuild(of: mergeRequest, stores: stores, myMergeRequests: myMergeRequests)
            },
            knownLabels: slotLabels.labels + labels.known.map { Label(title: $0, color: labels.colors[$0]) },
            team: team, today: now ?? dependencies.now(), calendar: calendar)
    }

    /// The slots of the Slots section under a chip (SLOT-06 to SLOT-08): the slot group's issues of the shown slots
    /// with my work items, the ones the chip matches, each slot's load against the chip's capacity. Without a slot
    /// group in Team, only my work items, as ``slotPlan(now:calendar:)``.
    ///
    /// - Parameters:
    ///   - chip: the chip
    ///   - now: the current time; the model's clock by default
    ///   - calendar: the calendar whose days count
    /// - Returns: the plan
    public func slotPlan(chip: SlotChip, now: Date? = nil, calendar: Calendar = .current) -> SlotPlan {
        let team = pipelines.project.team
        let related = workItems.relatedMergeRequests
        let labels = workItems.labels
        let myMergeRequests = mergeRequests.list?.mergeRequests ?? []
        let stores = projects.stores
        let source = slotSourceItems
        let me = slotUsername
        let squads = SlotChip.squads(of: source, prefix: team.squadLabelPrefix)
        return SlotPlan.make(
            workItems: source.filter { chip.matches($0, team: team, me: me) },
            mergeRequests: { related.entries[$0.reference]?.mergeRequests },
            build: { mergeRequest in
                Self.slotBuild(of: mergeRequest, stores: stores, myMergeRequests: myMergeRequests)
            },
            knownLabels: slotLabels.labels + labels.known.map { Label(title: $0, color: labels.colors[$0]) },
            team: team, capacity: chip.capacity(SquadCapacity(team.squadCapacity), squads: squads),
            today: now ?? dependencies.now(), calendar: calendar)
    }

    /// The chips of the Slots section: Me, Everyone, one per squad of the loaded items, Triage, Remaining Work and
    /// Open Bugs (SLOT-07).
    public var slotChips: [SlotChip] {
        SlotChip.chips(squads: SlotChip.squads(of: slotSourceItems, prefix: pipelines.project.team.squadLabelPrefix))
    }

    /// The slots whose group issues the section loads: the shown ones of my work items and every slot label, and the
    /// two latest slots already released, whose open items make them overdue (SLOT-06).
    ///
    /// - Parameters:
    ///   - now: the current time; the model's clock by default
    ///   - calendar: the calendar whose days count
    /// - Returns: the slot names, the earliest first
    public func slotNamesToLoad(now: Date? = nil, calendar: Calendar = .current) -> [SlotName] {
        let team = pipelines.project.team
        let today = calendar.startOfDay(for: now ?? dependencies.now())
        let rules = SlotRules(team: team)
        let shown = slotPlan(now: now, calendar: calendar).slots.map(\.name)
        let past = Set(slotLabels.labels.compactMap { SlotName(label: $0.title, prefix: team.slotLabelPrefix) })
            .filter { (rules.dates(of: $0, calendar: calendar)?.release ?? .distantFuture) < today }
            .sorted().suffix(2)
        return Set(shown + past).sorted()
    }

    /// the items the chips filter: the slot group's issues, then my work items that aren't among them
    private var slotSourceItems: [WorkItem] {
        let group = slotItems.items
        let known = Set(group.map(\.reference))
        return group + (workItems.lists?.all ?? []).filter { !known.contains($0.reference) }
    }

    /// my GitLab username, from Jenkins' lookup or my merge requests' answer
    private var slotUsername: String? {
        pipelines.gitLabUsername ?? mergeRequests.list?.username
    }

    /// The real work of one work item, for its detail (SLOT-03): its merge requests that count with their builds, and
    /// its flags when the slot plan has it, as a committed item of a shown slot. Any other item, also one without a
    /// slot, gets its merge requests and builds without flags.
    ///
    /// - Parameters:
    ///   - workItem: the work item
    ///   - now: the current time; the model's clock by default
    ///   - calendar: the calendar whose days count
    /// - Returns: the item with its merge requests, builds and flags
    public func slotItem(of workItem: WorkItem, now: Date? = nil, calendar: Calendar = .current) -> SlotItem {
        let planned = slotPlan(now: now, calendar: calendar).slots.lazy.flatMap(\.items).first { $0.id == workItem.id }
        if let planned {
            return planned
        }
        let related = workItems.relatedMergeRequests
        let myMergeRequests = mergeRequests.list?.mergeRequests ?? []
        let stores = projects.stores
        return SlotPlan.item(
            workItem, mergeRequests: { related.entries[$0.reference]?.mergeRequests },
            build: { Self.slotBuild(of: $0, stores: stores, myMergeRequests: myMergeRequests) },
            team: pipelines.project.team)
    }

    /// Returns the build the app knows of a merge request: the last Jenkins build of its `MR-<iid>` job in the project
    /// the MR belongs to, else the head pipeline GitLab gave for one of my open MRs.
    @MainActor
    private static func slotBuild(
        of mergeRequest: RelatedMergeRequest, stores: [PipelinesStore], myMergeRequests: [MergeRequest]
    ) -> BuildReality? {
        let path = mergeRequest.reference.split(separator: "!").first.map(String.init) ?? ""
        for store in stores where store.project.team.gitLabProject == path {
            let build = store.state.builds.first { $0.mergeRequestIID == mergeRequest.iid }
            if let build, let signal = BuildSignal(build) {
                let url = store.project.team.jenkinsJob.map {
                    AlertContent.buildURL(job: build.job, number: build.number, jobURL: $0)
                }
                return BuildReality(signal: signal, url: url, label: "#\(build.number)")
            }
        }
        if let status = myMergeRequests.first(where: { $0.webURL == mergeRequest.webURL })?.pipelineStatus,
            let signal = BuildSignal(status)
        {
            return BuildReality(signal: signal)
        }
        return nil
    }

    /// Posts the slot alert when it is on and a slot needs it (SLOT-04). The work items store calls it after each load.
    func checkSlotAlerts() {
        let plan = slotPlan()
        let team = pipelines.project.team
        let preferences = pipelines.preferences
        let (defaults, effects, log) = (dependencies.preferences, dependencies.effects, log)
        Task { @MainActor in
            await SlotAlerts.announce(
                plan, team: team, preferences: preferences, defaults: defaults, effects: effects, log: log)
        }
    }
}

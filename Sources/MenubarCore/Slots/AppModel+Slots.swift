import Foundation

extension AppModel {
    /// The slots of the primary project from what the app already has (SLOT-02, SLOT-03): its loaded work items, their
    /// related merge requests, the builds of Jenkins (mine and the watched ones) and the head pipelines of my merge
    /// requests, and the labels it remembers.
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
            knownLabels: labels.known.map { Label(title: $0, color: labels.colors[$0]) },
            team: team, today: now ?? dependencies.now(), calendar: calendar)
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

import Foundation

extension AppModel {
    /// Hands the AI store what the digest is written from: the app's own stores (AI-04).
    func connectAI() {
        let config = McpConfigReader()
        ai.configuredMcpServers = { folder in await config.serverKeys(folder: folder) }
        ai.digestFacts = { [weak self] in
            self?.digestFacts() ?? DigestFacts()
        }
        ai.refreshBeforeDigest = { [weak self] in
            guard let self else {
                return
            }
            await mergeRequests.load()
            await workItems.load()
        }
    }

    /// Returns the digest's facts from what the app has loaded: my merge requests, the reviews waiting for me, the red
    /// builds of every project, my open work items and their slots with their dates (AI-04). Of the work items the facts
    /// list only those that need me: Slots' red pipelines and items without a merge request near the freeze, in the
    /// current and next slot, and what is new or changed since the last digest (see ``DigestFacts/focused(changes:)``).
    public func digestFacts() -> DigestFacts {
        let primary = team.primaryProject()
        // Slots' problems, for the items of the slots that matter now: the overdue ones, the current and the next.
        let plan = slotPlan()
        let next = plan.slots.first { $0.state == .upcoming }
        var flags: [String: SlotFlag.Kind] = [:]
        for slot in plan.slots where slot.state == .overdue || slot.state == .current || slot.name == next?.name {
            for item in slot.items {
                let kinds = Set(item.flags.map(\.kind))
                if kinds.contains(.redPipeline) {
                    flags[item.workItem.reference] = .redPipeline
                } else if kinds.contains(.noMergeRequest), flags[item.workItem.reference] == nil {
                    flags[item.workItem.reference] = .noMergeRequest
                }
            }
        }
        let jobs = Dictionary(team.projects().map { ($0.id, $0.team.jenkinsJob) }, uniquingKeysWith: { first, _ in first })
        return DigestFacts.gather(
            mergeRequests: mergeRequests.sections, builds: projects.myBuilds + projects.watchedBuilds,
            workItems: workItems.lists?.all ?? [], me: pipelines.gitLabUsername ?? mergeRequests.list?.username,
            slotFlags: flags, slotPrefix: primary.team.slotPrefix,
            slotRules: SlotRules(team: primary.team),
            jobURL: { jobs[$0] ?? primary.team.jenkinsJob }, now: dependencies.now())
    }
}

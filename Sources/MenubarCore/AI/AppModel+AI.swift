import Foundation

extension AppModel {
    /// Hands the AI store what the digest is written from: the app's own stores (AI-04).
    func connectAI() {
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
    /// builds of every project and the work items by slot (AI-04).
    public func digestFacts() -> DigestFacts {
        DigestFacts.gather(
            mergeRequests: mergeRequests.sections, builds: projects.myBuilds + projects.watchedBuilds,
            workItems: workItems.lists?.all ?? [], slotPrefix: team.primaryProject().team.slotLabelPrefix,
            now: dependencies.now())
    }
}

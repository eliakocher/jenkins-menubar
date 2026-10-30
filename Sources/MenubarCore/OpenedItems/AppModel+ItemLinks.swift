import Foundation

extension AppModel {
    /// Returns the work items of a merge request: its title's references, GitLab's links and the related merge requests
    /// the Work Items section loaded (``ItemLinks``).
    ///
    /// - Parameters:
    ///   - reference: the merge request's full reference, like `group/project!12`
    ///   - title: the merge request's title
    /// - Returns: the work items, the strongest link first
    public func workItems(ofMergeRequest reference: String, title: String?) -> [LinkedWorkItem] {
        ItemLinks.workItems(
            ofMergeRequest: reference, title: title, evidence: evidence(ofMergeRequest: reference),
            ignoredPrefix: team.primaryProject().team.ignoredMergeRequestPrefix, gitLab: team.primaryProject().team.gitLab,
            titleOf: workItemTitle)
    }

    /// Returns the merge request of a build, `!12477` for the job `MR-12477`.
    ///
    /// - Parameter build: the build
    /// - Returns: the merge request; `nil` for a branch job
    public func mergeRequest(ofBuild build: Build) -> LinkedMergeRequest? {
        team.project(build.project).flatMap { ItemLinks.mergeRequest(ofBuild: build, team: $0.team) }
    }

    /// Returns the work items of a build, through its merge request. The merge request's title is Jenkins' name of the
    /// build, or the list's own when the merge request is in one.
    ///
    /// - Parameter build: the build
    /// - Returns: the work items; empty for a branch job
    public func workItems(ofBuild build: Build) -> [LinkedWorkItem] {
        guard let project = team.project(build.project), let linked = mergeRequest(ofBuild: build) else {
            return []
        }
        let known = knownMergeRequest(linked.reference)
        return ItemLinks.workItems(
            ofBuild: build, team: project.team, title: known?.title ?? linked.title,
            evidence: evidence(ofMergeRequest: linked.reference), gitLab: project.team.gitLab, titleOf: workItemTitle)
    }

    /// Asks GitLab for the links of a merge request, once while they are fresh.
    ///
    /// - Parameters:
    ///   - reference: the merge request's full reference
    ///   - webURL: its page
    ///   - updatedAt: when it last changed, when known
    public func loadItemLinks(ofMergeRequest reference: String, webURL: URL, updatedAt: Date? = nil) async {
        await itemLinks.load(reference: reference, webURL: webURL, updatedAt: updatedAt)
    }

    /// Asks GitLab for the links of the merge request of a build.
    ///
    /// - Parameter build: the build
    public func loadItemLinks(ofBuild build: Build) async {
        guard let linked = mergeRequest(ofBuild: build) else {
            return
        }
        await itemLinks.load(reference: linked.reference, webURL: linked.webURL, updatedAt: knownMergeRequest(linked.reference)?.updatedAt)
    }

    private func evidence(ofMergeRequest reference: String) -> WorkItemEvidence {
        let links = itemLinks.links(of: reference)
        return WorkItemEvidence(
            closes: links?.closes ?? [], related: links?.related ?? [],
            mentionedBy: workItems.relatedMergeRequests.workItems(mentioning: reference))
    }

    /// the merge request of my list or an opened one with a reference, lowercase compared
    private func knownMergeRequest(_ reference: String) -> MergeRequest? {
        let wanted = reference.lowercased()
        return mergeRequests.list?.mergeRequests.first { $0.reference.lowercased() == wanted }
            ?? opened.mergeRequests.values.first { $0.reference.lowercased() == wanted }
    }

    /// a work item's title by its lowercase full reference, from my lists and the opened ones
    private func workItemTitle(_ reference: String) -> String? {
        let item = workItems.lists?.all.first { $0.reference.lowercased() == reference }
            ?? opened.workItems.values.first { $0.reference.lowercased() == reference }
        return item?.displayTitle
    }
}

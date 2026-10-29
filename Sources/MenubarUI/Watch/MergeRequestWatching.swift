import MenubarCore

/// Watching from a merge request: "Watch Builds" in the MR detail and the panel's MR row menu, and the Watch a Build…
/// sheet that starts with the selected MR (WATCH-01).
@MainActor
enum MergeRequestWatching {
    /// Watches the job `MR-<iid>` in one click, as Return does in the sheet. Jenkins confirms the job first; a
    /// refusal, such as a missing token or a job Jenkins doesn't have, opens the sheet with the reason, since the
    /// buttons have no room for it.
    ///
    /// - Parameters:
    ///   - mergeRequest: the MR, watched in its own project; an MR of a project not set up watches nothing
    ///   - model: the app's model
    ///   - router: the router that opens the sheet
    static func watch(_ mergeRequest: MergeRequest, model: AppModel, router: WindowRouter) {
        guard let pipelines = model.projects.store(forMergeRequest: mergeRequest) else {
            return
        }
        let iid = mergeRequest.iid
        Task {
            if case .failure(let refusal) = await pipelines.watch("!\(iid)") {
                var request = WatchRequest(text: "!\(iid)", refusal: refusal)
                request.project = pipelines.projectID
                router.open(.watch(request))
            }
        }
    }

    /// Returns the request the toolbar's and the menu's Watch a Build… open the sheet with: the MR selected in Merge
    /// Requests as `!12437`, else an empty field.
    ///
    /// - Parameters:
    ///   - model: the app's model, for the MR's number
    ///   - router: the router, which holds the section and the selections
    static func request(model: AppModel, router: WindowRouter) -> WatchRequest {
        guard router.section == .mergeRequests, let id = router.selection.mergeRequests,
            let mergeRequest = model.mergeRequests.list?.mergeRequests.first(where: { $0.id == id })
        else {
            return WatchRequest()
        }
        var request = WatchRequest(text: "!\(mergeRequest.iid)")
        request.project = model.projects.store(forMergeRequest: mergeRequest)?.projectID
        return request
    }
}

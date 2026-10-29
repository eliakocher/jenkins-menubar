import Foundation

/// What an MR offers for watching its Jenkins builds: "Watch Builds" in the MR detail and the panel's MR row menu
/// (WATCH-01).
///
/// The job is `MR-<iid>`, as Watch a Build… takes it from `!<iid>`. My own MRs are tracked anyway (PIPE-01), so they
/// offer nothing.
public enum MergeRequestWatch: Hashable, Sendable {
    /// nothing is offered: the MR is mine, so its builds show anyway
    case hidden
    /// "Watch Builds" watches the job, in one click and without the sheet
    case watch(job: String)
    /// the job is watched already: the button reads "Watching" and does nothing
    case watching(job: String)

    /// whether the job is watched already
    public var isWatching: Bool {
        if case .watching = self { true } else { false }
    }

    /// Returns what an MR offers.
    ///
    /// - Parameters:
    ///   - mergeRequest: the MR
    ///   - me: my GitLab username; `nil` when it isn't known yet
    ///   - myJobs: my jobs, from the last Jenkins lookup (PIPE-01); `nil` before the first one
    ///   - watchedJobs: the jobs watched now, whether or not their builds show yet
    ///   - project: the MR's project; the jobs are its ``BuildID/jobKey``s, plain for ``ProjectID/main``
    /// - Returns: what to offer
    public static func of(
        _ mergeRequest: MergeRequest, me: String?, myJobs: [String]?, watchedJobs: [String], project: ProjectID = .main
    ) -> MergeRequestWatch {
        let job = BuildID.jobKey("MR-\(mergeRequest.iid)", project: project)
        if mergeRequest.roles.contains(.authored) || (me != nil && mergeRequest.author.username == me)
            || myJobs?.contains(job) == true
        {
            return .hidden
        }
        return watchedJobs.contains(job) ? .watching(job: job) : .watch(job: job)
    }
}

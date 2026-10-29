import Foundation

/// The links back from a merge request or a build to the checkout it lives in: one workspace is one task (WS-07). A
/// merge request lives in the checkout that has its source branch checked out, a build in that of its merge request, or
/// of its branch for a branch build. Nothing is asked for it: the checkouts' last readings and the loaded merge requests
/// are all it needs.
public struct WorkspaceLinks: Hashable, Sendable {
    /// A checkout with the branch it has checked out.
    public struct Entry: Hashable, Sendable {
        /// the checkout's folder name, like `develop3`: what the tag shows
        public var name: String
        /// the checkout's path, its id in the Workspaces section
        public var id: Checkout.ID
        public var branch: String

        public init(name: String, id: Checkout.ID, branch: String) {
            self.name = name
            self.id = id
            self.branch = branch
        }
    }

    /// the checkouts that are on a branch of their own, in the order of Settings
    public var entries: [Entry]
    /// the loaded merge requests, which lead a build to its branch
    public var mergeRequests: [MergeRequest]

    public init(entries: [Entry] = [], mergeRequests: [MergeRequest] = []) {
        self.entries = entries
        self.mergeRequests = mergeRequests
    }

    /// Builds the links from the checkouts and what git last said of them. A checkout on its base branch, on a detached
    /// HEAD or unread has no task, so no tag.
    ///
    /// - Parameters:
    ///   - checkouts: the checkouts, in the order of Settings
    ///   - readings: each checkout's reading, by its path
    ///   - mergeRequests: the loaded merge requests
    public init(checkouts: [Checkout], readings: [Checkout.ID: CheckoutReading], mergeRequests: [MergeRequest]) {
        entries = checkouts.compactMap { checkout in
            guard let branch = readings[checkout.id]?.state?.status.branch, branch != checkout.baseBranch else {
                return nil
            }
            return Entry(name: checkout.name, id: checkout.id, branch: branch)
        }
        self.mergeRequests = mergeRequests
    }

    /// whether no checkout is on a task's branch, so no row has a tag
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Returns the checkout that has a branch checked out. Two checkouts on one branch (rare: the clones are
    /// independent) give the first.
    ///
    /// - Parameter branch: the branch's name
    /// - Returns: the checkout, or `nil`
    public func checkout(onBranch branch: String?) -> Entry? {
        guard let branch, !branch.isEmpty else {
            return nil
        }
        return entries.first { $0.branch == branch }
    }

    /// Returns the checkout a merge request lives in: the one on its source branch.
    ///
    /// - Parameter mergeRequest: the merge request
    /// - Returns: the checkout, or `nil`
    public func checkout(for mergeRequest: MergeRequest) -> Entry? {
        checkout(onBranch: mergeRequest.sourceBranch)
    }

    /// Returns the checkout a build lives in: for `MR-<iid>` the one on its merge request's source branch (the loaded
    /// merge request with that iid, in the build's project), for a branch build the one on that branch.
    ///
    /// - Parameter build: the build
    /// - Returns: the checkout, or `nil`
    public func checkout(for build: Build) -> Entry? {
        guard let iid = build.mergeRequestIID else {
            return checkout(onBranch: Build.label(forJob: build.job))
        }
        let mergeRequest = mergeRequests.first { $0.iid == iid && WorkspaceTask.sameProject(build, $0) }
        return mergeRequest.flatMap(checkout(for:))
    }
}

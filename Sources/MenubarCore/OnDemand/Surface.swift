import Foundation

/// A part of the panel or the window whose GitLab data loads only while it is shown (OD-02).
///
/// The panel and the window tell the ``Scheduler`` which surfaces they show with ``Scheduler/setVisible(_:)``. A
/// collapsed section of the panel counts as shown, so its header's counts stay current.
public enum Surface: String, Hashable, Sendable, CaseIterable {
    /// my merge requests (MR-01)
    case mergeRequests
    /// the work items, with their related merge requests (WI-01, OD-03)
    case workItems
}

/// A GitLab load that the ``Scheduler`` runs while its surface is shown (OD-02): ``MergeRequestsStore`` and
/// ``WorkItemsStore``.
///
/// The loader keeps its data, its problem and its loading state; the scheduler only decides when it loads.
public protocol OnDemandLoading: Sendable {
    /// Returns how long ago the data was last loaded or tried, so the scheduler knows when it gets older than the
    /// maximum age.
    ///
    /// - Returns: the age; `nil` when it never was
    func dataAge() async -> Duration?

    /// Loads the data and keeps it, or keeps the problem next to the old data (MR-05). A load that is cancelled keeps
    /// what was there, without a problem.
    func load() async
}

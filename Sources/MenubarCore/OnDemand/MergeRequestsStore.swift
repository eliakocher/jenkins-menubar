import Foundation
import Observation

/// My open merge requests, loaded while the panel or the window shows them (MR-01, OD-02).
///
/// It shows the cached MRs at once (OD-01). A failed load keeps them and adds its problem (MR-05). The ``Scheduler``
/// decides when it loads; ``load()`` does it.
@Observable @MainActor
public final class MergeRequestsStore {
    /// the key of its problem in the ``ProblemTracker``
    public nonisolated static let problemKey = "gitlab.mergeRequests"

    /// my open MRs and my username, as last loaded; `nil` before the first load, and after the GitLab token is removed
    public private(set) var list: MergeRequestList? {
        didSet { updateReviewCount() }
    }
    /// how many of them wait for my review (MR-01's Review Requested), kept apart so the menu bar's count observes only
    /// a number that rarely changes (APP-11)
    public private(set) var reviewCount = 0
    /// when ``list`` was loaded
    public private(set) var fetchedAt: Date?
    /// when the last load ended, whether it worked or not: "Last checked HH:MM" (WI-07)
    public private(set) var lastLoadAt: Date?
    /// the problem of the last load, shown above the cached MRs (MR-05); ``Problem/noToken(_:)`` shows the setup steps
    /// (MR-04)
    public private(set) var problem: Problem?
    /// whether a load is under way, which shows a spinner (OD-01)
    public private(set) var isLoading = false

    /// called after each load that ended, like the job lookup for a new MR of mine (OD-06)
    @ObservationIgnored public var onLoaded: @MainActor () -> Void = {}

    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private let project: ProjectID
    /// when the recently merged MRs were last asked for, whether it worked or not (MR-17)
    @ObservationIgnored private var mergedAskedAt: Date?
    /// how long the recently merged MRs are kept before they are asked for again, in seconds: they change slowly, and
    /// their query is a second request
    nonisolated static let mergedInterval: TimeInterval = 600

    /// Creates the store with the cached MRs of the current project. Nothing is asked yet.
    ///
    /// - Parameter services: the transport, the token, the team values, the caches and the logs
    public init(services: GitLabServices) {
        self.services = services
        project = services.team.primaryProject().id
        if let cached = services.caches.load(.mergeRequestList, for: project) {
            list = cached.value
            fetchedAt = cached.fetchedAt
            lastLoadAt = cached.fetchedAt
            problem = cached.problem
        }
        updateReviewCount()
    }

    private func updateReviewCount() {
        let count = sections?.reviewRequested.count ?? 0
        if count != reviewCount {
            reviewCount = count
        }
    }

    /// the MRs in their sections (MR-01); `nil` before the first load
    public var sections: MergeRequestSections? {
        list.map { MergeRequestSections($0.mergeRequests, me: $0.username) }
    }

    /// Loads my open MRs, unless a load is under way.
    ///
    /// - Without a GitLab token, it asks nothing and discards the cached MRs (MR-04).
    /// - A failed load keeps the cached MRs, and saves its problem with them (MR-05).
    /// - A cancelled load changes nothing.
    public func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        let problem: Problem?
        var leftOpenLists = false
        var client: GitLabClient?
        switch await services.session() {
        case .failure(let refusal):
            if refusal.problem == .noToken(.gitLab) {
                tokenRemoved()
            }
            problem = refusal.problem
        case .success(let session):
            do {
                let open = try await services.measure { try await session.client.send(.mergeRequests) }
                // The merged MRs are asked for apart (MR-17): the last ones stay until the next answer.
                let before = Set(list?.mergeRequests.map(\.id) ?? [])
                list = MergeRequestList(username: open.username, mergeRequests: open.mergeRequests, merged: list?.merged ?? [])
                fetchedAt = services.now()
                problem = nil
                // An MR that left the open lists may have been merged: ask for the merged ones now.
                leftOpenLists = !before.isSubset(of: Set(open.mergeRequests.map(\.id)))
                client = session.client
            } catch let error as GitLabError where !Task.isCancelled {
                problem = error.problem
            } catch {
                // Cancelled, as sleep does: its requests would only time out after the wake. GitLabClient throws
                // nothing else.
                return
            }
        }
        self.problem = problem
        lastLoadAt = services.now()
        save()
        await services.track(Self.problemKey, problem)
        onLoaded()
        if let client {
            await loadMerged(client, force: leftOpenLists)
        }
    }

    /// Loads the recently merged MRs (MR-17), at most every ``mergedInterval`` seconds unless `force`. Its own query: when it
    /// fails, whatever the reason, the merged MRs stay as they were, the open MRs and the problem are untouched, and the
    /// reason goes to the log.
    private func loadMerged(_ client: GitLabClient, force: Bool) async {
        let now = services.now()
        if !force, let asked = mergedAskedAt, now.timeIntervalSince(asked) < Self.mergedInterval {
            return
        }
        mergedAskedAt = now
        do {
            let answer = try await client.send(.recentlyMerged(now: now))
            guard var current = list else {
                return
            }
            current.merged = answer.merged
            list = current
            save()
        } catch let error as GitLabError where !Task.isCancelled {
            await services.log.log(
                .warning, .gitlab, "Recently Merged couldn't be loaded: \(error.problem.message)", outcome: .warning("MERGED"))
        } catch {
            // Cancelled: nothing to say.
        }
    }

    /// Forgets the MRs, deletes their cache and shows the setup steps: the GitLab token was removed (MR-04). Settings
    /// calls it when it removes the token; a load that finds no token does it too.
    public func tokenRemoved() {
        list = nil
        mergedAskedAt = nil
        fetchedAt = nil
        problem = .noToken(.gitLab)
        try? services.caches.delete(.mergeRequestList, for: project)
    }

    private func save() {
        guard let list, let fetchedAt else {
            return
        }
        // A cache that can't be written only costs the next launch its instant data.
        try? services.caches.save(Cached(value: list, fetchedAt: fetchedAt, problem: problem), as: .mergeRequestList, for: project)
    }
}

extension MergeRequestsStore: OnDemandLoading {
    public func dataAge() async -> Duration? {
        services.age(since: lastLoadAt)
    }
}

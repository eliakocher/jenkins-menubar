import Foundation
import Observation

/// The work items of the filters, with their related merge requests and the labels, loaded while the panel or the
/// window shows them (WI-01, WI-05, WI-06, OD-02, OD-03).
///
/// It shows the cached work items at once (OD-01). A failed load keeps them and adds its problem (MR-05). The
/// ``Scheduler`` decides when it loads; ``load()`` does it.
@Observable @MainActor
public final class WorkItemsStore {
    /// the key of its problem in the ``ProblemTracker``
    public nonisolated static let problemKey = "gitlab.workItems"
    /// how many related-MR requests run at once (OD-03)
    public nonisolated static let relatedRequestsAtOnce = 6
    /// how long a related-MR answer is reused while its work item is unchanged: an MR can be merged meanwhile (OD-03)
    public nonisolated static let relatedReusedFor: TimeInterval = 600
    /// how long a related-MR answer is kept at all (OD-03)
    public nonisolated static let relatedKeptFor: TimeInterval = 86400

    /// the work items as last loaded; `nil` before the first load, and after the GitLab token is removed
    public private(set) var lists: WorkItemLists?
    /// when ``lists`` was loaded
    public private(set) var fetchedAt: Date?
    /// when the last load ended, whether it worked or not: "Last checked HH:MM" (WI-07)
    public private(set) var lastLoadAt: Date?
    /// the problem of the last load, shown above the cached work items (MR-05); ``Problem/noToken(_:)`` points to
    /// the merge requests' setup steps (MR-04)
    public private(set) var problem: Problem?
    /// whether a load is under way, its related MRs included, which shows a spinner (OD-01)
    public private(set) var isLoading = false
    /// the related MRs of the work items, by reference, for their markers (WI-05)
    public private(set) var relatedMergeRequests: RelatedMergeRequestsCache
    /// the remembered labels, their colors and the gone filter labels (WI-06)
    public private(set) var labels: LabelMemory

    /// called after each load that ended, for what follows the work items, like the slot alert (SLOT-04)
    @ObservationIgnored public var onLoaded: @MainActor () -> Void = {}

    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private let preferences: @MainActor () -> Preferences
    @ObservationIgnored private let project: ProjectID

    /// Creates the store with the cached work items, related MRs and labels of the current project. Nothing is asked
    /// yet.
    ///
    /// - Parameters:
    ///   - services: the transport, the token, the team values, the caches and the logs
    ///   - preferences: the current preferences, read at each load for the work item filters
    public init(services: GitLabServices, preferences: @escaping @MainActor () -> Preferences) {
        self.services = services
        self.preferences = preferences
        project = services.team.primaryProject().id
        let caches = services.caches
        if let cached = caches.load(.workItems, for: project) {
            lists = cached.value
            fetchedAt = cached.fetchedAt
            lastLoadAt = cached.fetchedAt
            problem = cached.problem
        }
        relatedMergeRequests = caches.load(.relatedMergeRequests, for: project)?.value ?? RelatedMergeRequestsCache()
        labels = caches.load(.labels, for: project)?.value ?? LabelMemory()
    }

    /// Returns the marker of a work item from its related MRs (WI-05).
    ///
    /// - Parameters:
    ///   - workItem: the work item
    ///   - ignoredPrefix: the ignored MR prefix from Team
    /// - Returns: the marker, or `nil`
    public func marker(of workItem: WorkItem, ignoredPrefix: String) -> RelatedMergeRequestMarker? {
        relatedMergeRequests.marker(of: workItem, ignoredPrefix: ignoredPrefix)
    }

    /// Loads the work items of the current filters, unless a load is under way. Then, in the same check time:
    ///
    /// - it remembers their labels, asks GitLab about the filter labels none of them has, and logs each newly gone one
    ///   once (WI-06);
    /// - it refreshes their related MRs, 6 at a time, reusing an answer for 10 min while its work item is unchanged
    ///   (OD-03). A failed request keeps the old answer.
    ///
    /// Without a GitLab token, it asks nothing and discards the cached work items (MR-04). A failed load keeps them,
    /// and saves its problem with them (MR-05). A cancelled load keeps what it got so far.
    public func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        let problem: Problem?
        switch await services.session() {
        case .failure(let refusal):
            if refusal.problem == .noToken(.gitLab) {
                tokenRemoved()
            }
            problem = refusal.problem
        case .success(let session):
            do {
                problem = try await services.measure { try await load(in: session) }
            } catch {
                // Cancelled, as sleep does: its requests would only time out after the wake.
                return
            }
        }
        self.problem = problem
        lastLoadAt = services.now()
        if problem != nil {
            // Loaded work items were saved as they came.
            saveWorkItems()
        }
        await services.track(Self.problemKey, problem)
        onLoaded()
    }

    /// Searches the labels for the label picker: the remembered ones, the filter labels and GitLab's (WI-06). The
    /// colors GitLab sends are remembered.
    ///
    /// It waits ``LabelSearch/pause`` first: cancel the task of the previous search when the text changes, so the
    /// newer search wins.
    ///
    /// - Parameter text: the search text; empty gives the known labels without asking GitLab
    /// - Returns: the labels, their colors, and why only the labels of the work items show, when GitLab wasn't asked
    ///   or didn't answer
    /// - Throws: `CancellationError` when the task was cancelled
    public func searchLabels(_ text: String) async throws -> LabelSearchResult {
        let session = try? await services.session().get()
        let search = LabelSearch(client: session?.client, project: session?.path ?? "", clock: services.clock)
        let result = try await search.searchLabels(text, memory: labels, filters: preferences().workItems)
        if !result.found.isEmpty {
            labels.remember(colorsOf: result.found)
            saveLabels()
        }
        return result
    }

    /// Forgets the work items and their related MRs, deletes their caches and shows the setup steps: the GitLab token
    /// was removed (MR-04). Settings calls it when it removes the token; a load that finds no token does it too. The
    /// remembered labels stay: they are the filters' vocabulary, not GitLab's answer.
    public func tokenRemoved() {
        lists = nil
        fetchedAt = nil
        problem = .noToken(.gitLab)
        relatedMergeRequests = RelatedMergeRequestsCache()
        try? services.caches.delete(.workItems, for: project)
        try? services.caches.delete(.relatedMergeRequests, for: project)
    }

    // MARK: - Loading

    /// Loads the work items, then their labels and related MRs.
    ///
    /// - Returns: the problem of the work items; `nil` when they loaded
    /// - Throws: `CancellationError` when the task was cancelled
    private func load(in session: GitLabSession) async throws -> Problem? {
        let preferences = preferences()
        let lists: WorkItemLists
        do {
            let me = try await username(in: session)
            lists = try await session.client.send(.workItems(WorkItemQuery.variables(preferences: preferences, project: session.project, me: me)))
        } catch let error as GitLabError where !Task.isCancelled {
            return error.problem
        } catch {
            throw CancellationError()
        }
        self.lists = lists
        fetchedAt = services.now()
        problem = nil
        // Saved before the labels and the related MRs, so a load cancelled after this point keeps the new work items.
        saveWorkItems()
        try await checkLabels(of: lists.all, filters: preferences.workItems, client: session.client, path: session.path)
        try await refreshRelatedMergeRequests(of: lists.all, client: session.client)
        return nil
    }

    /// My username for the WorkItems query: the background check's, or GitLab's answer when it has none yet.
    private func username(in session: GitLabSession) async throws -> String {
        if let known = await services.gitLabUsername(), !known.isEmpty {
            return known
        }
        return try await session.client.send(.currentUser)
    }

    /// Remembers the labels of the loaded work items, and flags the filter labels GitLab no longer has (WI-06). Each
    /// newly gone label is logged once.
    private func checkLabels(of workItems: [WorkItem], filters: WorkItemFilters, client: GitLabClient, path: String) async throws {
        var memory = labels
        memory.remember(workItems, filters: filters, at: services.now())
        let check = try await LabelSearch(client: client, project: path, clock: services.clock)
            .checkFilterLabels(filters: filters, workItems: workItems, memory: memory)
        labels = check.memory
        saveLabels()
        for label in check.newlyMissing {
            await services.log.log(.warning, .gitlab, LabelMemory.missingMessage(label: label), outcome: .warning("MISSING"))
        }
    }

    /// Asks GitLab for the related MRs of the work items whose answer is missing, older than 10 min, or older than the
    /// work item's last update; 6 at a time (OD-03). Answers older than a day are dropped first.
    ///
    /// Each answer shows as soon as it arrives. A failed or cancelled request keeps the work item's old answer.
    private func refreshRelatedMergeRequests(of workItems: [WorkItem], client: GitLabClient) async throws {
        let now = services.now()
        relatedMergeRequests.entries = relatedMergeRequests.entries.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.relatedKeptFor }
        let due: [(WorkItem, GitLabOperation<[RelatedMergeRequest]>)] = workItems.compactMap { item in
            guard let operation = GitLabOperation.relatedMergeRequests(of: item) else {
                return nil
            }
            if let entry = relatedMergeRequests.entries[item.reference], entry.workItemUpdatedAt == item.updatedAt,
                now.timeIntervalSince(entry.fetchedAt) < Self.relatedReusedFor
            {
                return nil
            }
            return (item, operation)
        }
        let currentTime = services.now
        await withTaskGroup(of: (String, RelatedMergeRequestsCache.Entry?).self) { group in
            var pending = due.makeIterator()
            func askNext() {
                guard !Task.isCancelled, let (item, operation) = pending.next() else {
                    return
                }
                group.addTask {
                    let mergeRequests = try? await client.send(operation)
                    return (item.reference, mergeRequests.map {
                        RelatedMergeRequestsCache.Entry(workItemUpdatedAt: item.updatedAt, fetchedAt: currentTime(), mergeRequests: $0)
                    })
                }
            }
            for _ in 0..<Self.relatedRequestsAtOnce {
                askNext()
            }
            for await (reference, entry) in group {
                if let entry {
                    relatedMergeRequests.entries[reference] = entry
                }
                askNext()
            }
        }
        saveRelatedMergeRequests()
        try Task.checkCancellation()
    }

    // MARK: - Saving

    // A cache that can't be written only costs the next launch its instant data.

    private func saveWorkItems() {
        guard let lists, let fetchedAt else {
            return
        }
        try? services.caches.save(Cached(value: lists, fetchedAt: fetchedAt, problem: problem), as: .workItems, for: project)
    }

    private func saveRelatedMergeRequests() {
        try? services.caches.save(Cached(value: relatedMergeRequests, fetchedAt: services.now()), as: .relatedMergeRequests, for: project)
    }

    private func saveLabels() {
        try? services.caches.save(Cached(value: labels, fetchedAt: services.now()), as: .labels, for: project)
    }
}

extension WorkItemsStore: OnDemandLoading {
    public func dataAge() async -> Duration? {
        services.age(since: lastLoadAt)
    }
}

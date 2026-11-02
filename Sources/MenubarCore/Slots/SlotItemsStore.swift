import Foundation
import Observation

/// Every issue of the slot group in the shown slots, committed or planned, by their scheduled slot label, loaded while
/// the Slots section shows (SLOT-06).
///
/// One paged query per slot, a few at a time; each slot's answer shows as it comes. It shows the cached items at once.
/// A failed slot keeps what it had and says so in ``problem``.
@Observable @MainActor
public final class SlotItemsStore {
    /// how long an answer is reused before the section asks again
    public nonisolated static let reusedFor: TimeInterval = 1800
    /// how many pages of 100 one slot reads at most
    public nonisolated static let maxPages = 10

    /// the issues by slot name, like `2026.45`, as last loaded
    public private(set) var bySlot: [String: [WorkItem]]
    /// the weight under each epic of the loaded issues, by the epic's reference (SLOT-11)
    public private(set) var epicWeights: [String: Int]
    /// the commitments by slot name, from the commitment group (SLOT-14)
    public private(set) var commitmentsBySlot: [String: [SlotCommitment]]
    /// why the commitments didn't load; `nil` when they did or Team has no commitment group. A quiet note: the slots
    /// show without them.
    public private(set) var commitmentsProblem: String?
    /// when the slots in ``bySlot`` were loaded; `nil` before the first load
    public private(set) var fetchedAt: Date?
    /// why a slot's issues aren't GitLab's current answer; `nil` when the last load worked
    public private(set) var problem: String?
    public private(set) var isLoading = false

    @ObservationIgnored private let services: GitLabServices
    @ObservationIgnored private let project: ProjectID

    /// - Parameter services: the transport, the token, the team values and the caches
    public init(services: GitLabServices) {
        self.services = services
        project = services.team.primaryProject().id
        let cached = services.caches.load(.slotItems, for: project)
        bySlot = cached?.value ?? [:]
        epicWeights = services.caches.load(.slotEpicWeights, for: project)?.value ?? [:]
        commitmentsBySlot = services.caches.load(.slotCommitments, for: project)?.value ?? [:]
        fetchedAt = cached?.fetchedAt
    }

    /// every loaded commitment, each once (SLOT-14)
    public var commitments: [SlotCommitment] {
        var seen: Set<String> = []
        return commitmentsBySlot.keys.sorted().flatMap { commitmentsBySlot[$0] ?? [] }.filter { seen.insert($0.reference).inserted }
    }

    /// every loaded issue, each once
    public var items: [WorkItem] {
        var seen: Set<String> = []
        return bySlot.keys.sorted().flatMap { bySlot[$0] ?? [] }.filter { seen.insert($0.reference).inserted }
    }

    /// Loads the issues of the slots, unless an answer younger than ``reusedFor`` has all of them.
    ///
    /// Without a slot group or a slot prefix nothing is asked. A load that is cancelled keeps what was there.
    ///
    /// - Parameters:
    ///   - slots: the slots to load
    ///   - force: asks even when the last answer is recent
    public func load(slots: [SlotName], force: Bool = false) async {
        let team = services.team.primaryProject().team
        let group = team.slotGroup.trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, !team.slotPrefix.isEmpty, !slots.isEmpty, !isLoading else { return }
        let names = slots.map(\.description)
        if !force, problem == nil, let fetchedAt, services.now().timeIntervalSince(fetchedAt) < Self.reusedFor,
            names.allSatisfy({ bySlot[$0] != nil })
        {
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard case .success(let session) = await services.session() else {
            // A missing token or team value is a setup step that the section already shows.
            problem = nil
            return
        }
        let client = session.client
        let prefix = team.slotPrefix
        var failed: String?
        var loaded = bySlot.filter { names.contains($0.key) }
        var weights = epicWeights
        await withTaskGroup(of: (String, Result<SlotItemsPage, GitLabError>?).self) { tasks in
            var pending = names[...]
            func next() {
                guard let name = pending.popFirst() else { return }
                tasks.addTask { (name, await Self.fetch(client: client, group: group, label: prefix + name)) }
            }
            // Three slots at a time, so GitLab isn't flooded.
            for _ in 0..<3 { next() }
            for await (name, result) in tasks {
                switch result {
                case .success(let page):
                    loaded[name] = page.items
                    bySlot[name] = page.items
                    weights.merge(page.epicWeights) { $1 }
                    epicWeights = weights
                case .failure(let error):
                    failed = error.problem.message
                case nil:
                    break
                }
                next()
            }
        }
        if Task.isCancelled { return }
        if let failed {
            problem = "GitLab did not answer for the slot group: \(failed)"
        } else {
            bySlot = loaded
            fetchedAt = services.now()
            problem = nil
            try? services.caches.save(Cached(value: loaded, fetchedAt: services.now()), as: .slotItems, for: project)
            try? services.caches.save(Cached(value: weights, fetchedAt: services.now()), as: .slotEpicWeights, for: project)
        }
        await loadCommitments(names: names, team: team, client: client)
    }

    /// Loads the commitments of the slots, one slot after the other; a failure keeps what was there and says so in
    /// ``commitmentsProblem``, quietly (SLOT-14).
    private func loadCommitments(names: [String], team: TeamValues, client: GitLabClient) async {
        let group = team.slotCommitmentGroup.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !group.isEmpty else {
            commitmentsBySlot = [:]
            commitmentsProblem = nil
            return
        }
        var loaded = commitmentsBySlot.filter { names.contains($0.key) }
        var failed: String?
        for name in names {
            var commitments: [SlotCommitment] = []
            var cursor: String?
            do {
                for _ in 0..<Self.maxPages {
                    let page = try await client.send(.slotCommitments(group: group, labels: [team.slotPrefix + name], after: cursor))
                    commitments += page.commitments
                    guard let next = page.nextCursor else { break }
                    cursor = next
                }
                loaded[name] = commitments
            } catch let error as GitLabError {
                failed = error.problem.message
            } catch {
                return
            }
        }
        commitmentsBySlot = loaded
        if let failed {
            commitmentsProblem = "The commitments didn't load: \(failed)"
        } else {
            commitmentsProblem = nil
            try? services.caches.save(Cached(value: loaded, fetchedAt: services.now()), as: .slotCommitments, for: project)
        }
    }

    /// Reads every page of one slot's issues, all in one page value; `nil` when cancelled. A GitLab that refuses the
    /// epics' weight is asked again without it.
    private nonisolated static func fetch(
        client: GitLabClient, group: String, label: String, epicWeights: Bool = true
    ) async -> Result<SlotItemsPage, GitLabError>? {
        var all = SlotItemsPage(items: [], count: 0)
        var cursor: String?
        do {
            for _ in 0..<maxPages {
                let page = try await client.send(.slotItems(group: group, labels: [label], after: cursor, epicWeights: epicWeights))
                all.items += page.items
                all.count = page.count
                all.epicWeights.merge(page.epicWeights) { $1 }
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            return .success(all)
        } catch let error as GitLabError {
            if epicWeights, case .graphQLErrors(let messages) = error.problem,
                messages.contains(where: { $0.contains("descendantWeightSum") })
            {
                return await fetch(client: client, group: group, label: label, epicWeights: false)
            }
            return .failure(error)
        } catch {
            return nil
        }
    }
}

extension CacheFile where Value == [String: [SlotCommitment]] {
    /// the commitments by slot name (SLOT-14)
    public static var slotCommitments: CacheFile { CacheFile("slot-commitments") }
}

extension CacheFile where Value == [String: Int] {
    /// the weight under each epic of the slot group's issues (SLOT-11)
    public static var slotEpicWeights: CacheFile { CacheFile("slot-epic-weights") }
}

extension CacheFile where Value == [String: [WorkItem]] {
    /// the slot group's issues by slot name (SLOT-06)
    public static var slotItems: CacheFile { CacheFile("slot-items") }
}

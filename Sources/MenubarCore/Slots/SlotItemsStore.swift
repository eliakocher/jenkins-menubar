import Foundation
import Observation

/// Every issue of the slot group in the shown slots, committed or planned, loaded while the Slots section shows
/// (SLOT-06).
///
/// One paged query per slot, a few at a time; each slot's answer shows as it comes. It shows the cached items at once.
/// A failed slot keeps what it had and says so in ``problem``.
@Observable @MainActor
public final class SlotItemsStore {
    /// how long an answer is reused before the section asks again
    public nonisolated static let reusedFor: TimeInterval = 600
    /// how many pages of 100 one slot reads at most
    public nonisolated static let maxPages = 10

    /// the issues by slot name, like `2026.45`, as last loaded
    public private(set) var bySlot: [String: [WorkItem]]
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
        fetchedAt = cached?.fetchedAt
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
        guard !group.isEmpty, !team.slotLabelPrefix.isEmpty, !slots.isEmpty, !isLoading else { return }
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
        let prefixes = [team.slotLabelPrefix, team.slotScheduledLabelPrefix].filter { !$0.isEmpty }
        var failed: String?
        var loaded = bySlot.filter { names.contains($0.key) }
        await withTaskGroup(of: (String, Result<[WorkItem], GitLabError>?).self) { tasks in
            var pending = names[...]
            func next() {
                guard let name = pending.popFirst() else { return }
                let labels = prefixes.map { $0 + name }
                tasks.addTask { (name, await Self.fetch(client: client, group: group, labels: labels)) }
            }
            // Three slots at a time, so GitLab isn't flooded.
            for _ in 0..<3 { next() }
            for await (name, result) in tasks {
                switch result {
                case .success(let items):
                    loaded[name] = items
                    bySlot[name] = items
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
        }
    }

    /// Reads every page of one slot's issues; `nil` when cancelled.
    private nonisolated static func fetch(client: GitLabClient, group: String, labels: [String]) async -> Result<[WorkItem], GitLabError>? {
        var items: [WorkItem] = []
        var cursor: String?
        do {
            for _ in 0..<maxPages {
                let page = try await client.send(.slotItems(group: group, labels: labels, after: cursor))
                items += page.items
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            return .success(items)
        } catch let error as GitLabError {
            return .failure(error)
        } catch {
            return nil
        }
    }
}

extension CacheFile where Value == [String: [WorkItem]] {
    /// the slot group's issues by slot name (SLOT-06)
    public static var slotItems: CacheFile { CacheFile("slot-items") }
}

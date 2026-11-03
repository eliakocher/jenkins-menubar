import Foundation

// MARK: - The work items the digest lists (AI-04)

extension WorkItem {
    /// Returns whether the digest is about the item: it is assigned to me. An item whose assignees are unknown, or when
    /// my name is, counts.
    ///
    /// - Parameter me: my GitLab username; `nil` when unknown
    func isMine(_ me: String?) -> Bool {
        guard let me, let assignees else {
            return true
        }
        return assignees.contains { $0.username.caseInsensitiveCompare(me) == .orderedSame }
    }
}

extension DigestFacts {
    /// how many work items the digest lists at most; the rest is "+N more in Work Items"
    public static let workItemsShown = 5

    /// Returns the facts with only the work items that need me listed: what the app's rules say needs me now (a blocked
    /// or due item, a red pipeline, no merge request near the code freeze), then the items new since the last digest,
    /// then those whose state changed, at most ``workItemsShown``, each group in its order. Everything else of mine
    /// stays in Work Items and in ``openWorkItems``. Slots stay, whole.
    ///
    /// - Parameter changes: what changed since the digest before
    /// - Returns: the facts to show and to send to Claude
    public func focused(changes: DigestChanges) -> DigestFacts {
        let workItems = items(.workItem)
        func rank(_ item: DigestItem) -> Int? {
            if item.needsYou {
                0
            } else if changes.new.contains(item.ref) {
                1
            } else if changes.changed[item.ref] != nil {
                2
            } else {
                nil
            }
        }
        let listed = workItems.enumerated()
            .compactMap { index, item in rank(item).map { (rank: $0, index: index, item: item) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .prefix(Self.workItemsShown)
            .map(\.item)
        var focused = self
        // The order of the parts stays: the work items before the slots.
        focused.items = items.filter { Self.order($0.kind) < Self.order(.workItem) } + listed
            + items.filter { Self.order($0.kind) > Self.order(.workItem) }
        focused.openWorkItems = openWorkItemCount
        return focused
    }

    /// how many open work items of mine there are
    public var openWorkItemCount: Int { max(openWorkItems, items(.workItem).count) }

    private static func order(_ kind: DigestItem.Kind) -> Int {
        switch kind {
        case .mergeRequest: 0
        case .review: 1
        case .build: 2
        case .workItem: 3
        case .slot: 4
        case .note: 5
        }
    }
}

extension DigestHistory {
    /// Returns what changed since the digest before, without recording anything: the comparison ``record(_:)`` makes,
    /// for the prompt, which is written before the answer.
    ///
    /// - Parameter facts: the facts about to be sent
    /// - Returns: the changes
    public func changes(for facts: DigestFacts) -> DigestChanges {
        if let last, abs(last.gatheredAt.timeIntervalSince(facts.gatheredAt)) < 0.001 {
            return DigestChanges(since: beforeLast, to: facts)
        }
        return DigestChanges(since: last, to: facts)
    }
}

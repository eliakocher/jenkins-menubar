import Foundation

/// The Inbox rows the user opened, so the list shows them faded while they stay (the user, 2026-11-03: opening a row
/// does not mark it done). Kept on this Mac, in `Inbox/seen.json`, for 60 days and at most 500 ids; each id is observed
/// on its own, so marking one row draws that row, not the list.
@MainActor
public final class InboxSeen {
    /// how long an id is kept
    public nonisolated static let keptFor: TimeInterval = 60 * 24 * 3600
    /// the most ids kept; the oldest go first
    public nonisolated static let limit = 500

    private let entries = ObservedEntries<String, Bool>()
    private var dates: [String: Date]
    private let file: FileStore<[String: Date]>
    private let now: @Sendable () -> Date

    /// Creates the set with the ids kept in the file.
    ///
    /// - Parameters:
    ///   - file: the JSON file
    ///   - now: the clock, which dates each mark and prunes the old ones
    public init(file: FileStore<[String: Date]>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        dates = file.load() ?? [:]
        for id in dates.keys {
            entries[id] = true
        }
    }

    /// Returns whether the row was opened. Reading it observes this id only.
    ///
    /// - Parameter id: the entry's id
    public func isSeen(_ id: String) -> Bool {
        entries[id] ?? false
    }

    /// Notes that a row was opened.
    ///
    /// - Parameter id: the entry's id
    public func markSeen(_ id: String) {
        guard dates[id] == nil else {
            return
        }
        dates[id] = now()
        entries[id] = true
        prune()
        try? file.save(dates)
    }

    /// Forgets that a row was opened, for a row that comes back as new.
    ///
    /// - Parameter id: the entry's id
    public func markUnseen(_ id: String) {
        guard dates.removeValue(forKey: id) != nil else {
            return
        }
        entries[id] = nil
        try? file.save(dates)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.keptFor)
        var kept = dates.filter { $0.value > cutoff }
        if kept.count > Self.limit {
            kept = Dictionary(
                uniqueKeysWithValues: kept.sorted { $0.value > $1.value }.prefix(Self.limit).map { ($0.key, $0.value) })
        }
        for id in dates.keys where kept[id] == nil {
            entries[id] = nil
        }
        dates = kept
    }
}

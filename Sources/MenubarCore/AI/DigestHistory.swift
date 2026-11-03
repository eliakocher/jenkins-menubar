import Foundation

// MARK: - What changed since the last digest (AI-04)

/// The items of one digest as the next one compares them: each item's reference, what the row showed of it, and its
/// state. Kept in the preferences, never sent anywhere.
public struct DigestSnapshot: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var ref: String
        public var kind: String
        public var shortRef: String
        public var title: String
        public var state: String
        public var link: URL?

        public init(ref: String, kind: String, shortRef: String, title: String, state: String, link: URL? = nil) {
            self.ref = ref
            self.kind = kind
            self.shortRef = shortRef
            self.title = title
            self.state = state
            self.link = link
        }

        public var id: String { ref }
    }

    /// when the digest's facts were gathered
    public var gatheredAt: Date
    public var entries: [Entry]

    public init(gatheredAt: Date, entries: [Entry]) {
        self.gatheredAt = gatheredAt
        self.entries = entries
    }

    /// Returns the snapshot of a digest's facts; Claude's notes aren't items and stay out.
    public init(_ facts: DigestFacts) {
        gatheredAt = facts.gatheredAt
        entries = facts.items.filter { $0.kind != .note }.map {
            Entry(ref: $0.ref, kind: $0.kind.rawValue, shortRef: $0.shortRef, title: $0.title, state: $0.state.text, link: $0.link)
        }
    }
}

/// What changed since the digest before: the items it didn't have, those whose state is another, and those it had that
/// are gone, mostly merged, fixed or closed.
public struct DigestChanges: Codable, Hashable, Sendable {
    /// when the digest compared with was gathered; `nil` for a first digest, which marks nothing
    public var previousAt: Date?
    /// the references of the new items
    public var new: Set<String>
    /// the states the changed items had, by reference
    public var changed: [String: String]
    /// the items of the digest before that are gone
    public var cleared: [DigestSnapshot.Entry]

    public init(
        previousAt: Date? = nil, new: Set<String> = [], changed: [String: String] = [:], cleared: [DigestSnapshot.Entry] = []
    ) {
        self.previousAt = previousAt
        self.new = new
        self.changed = changed
        self.cleared = cleared
    }

    /// Compares a digest's facts with the digest before.
    ///
    /// - Parameters:
    ///   - previous: the digest before; `nil` marks nothing
    ///   - facts: the new digest's facts
    public init(since previous: DigestSnapshot?, to facts: DigestFacts) {
        guard let previous else {
            self.init()
            return
        }
        let before = Dictionary(previous.entries.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let current = facts.items.filter { $0.kind != .note }
        var new: Set<String> = []
        var changed: [String: String] = [:]
        for item in current {
            if let entry = before[item.ref] {
                if entry.state != item.state.text {
                    changed[item.ref] = entry.state
                }
            } else {
                new.insert(item.ref)
            }
        }
        let refs = Set(current.map(\.ref))
        self.init(
            previousAt: previous.gatheredAt, new: new, changed: changed,
            cleared: previous.entries.filter { !refs.contains($0.ref) })
    }

    /// what changed about an item; `nil` when nothing did
    public func change(of item: DigestItem) -> DigestReport.Change? {
        if new.contains(item.ref) {
            return .new
        }
        return changed[item.ref].map { .changed(from: $0) }
    }

    /// whether there is nothing to say: a first digest, or nothing changed
    public var isEmpty: Bool { new.isEmpty && changed.isEmpty && cleared.isEmpty }
}

/// The last two digests' snapshots, in the preferences (AI-04): a new digest compares with the last one; asking again
/// about the same facts (Ask Again With, Try Again) compares with the one before it, so the marks stay.
public struct DigestHistory: Codable, Hashable, Sendable {
    public var last: DigestSnapshot?
    public var beforeLast: DigestSnapshot?
    /// the digest the person last saw, by when its facts were gathered; `nil` when none was seen yet. The sidebar's dot on
    /// Digest shows while ``last`` is a newer one.
    public var seenAt: Date?

    public init(last: DigestSnapshot? = nil, beforeLast: DigestSnapshot? = nil, seenAt: Date? = nil) {
        self.last = last
        self.beforeLast = beforeLast
        self.seenAt = seenAt
    }

    /// whether a digest was written that the person hasn't seen yet
    public var hasUnread: Bool {
        guard let last else {
            return false
        }
        return seenAt.map { last.gatheredAt > $0 } ?? true
    }

    /// Marks the last digest as seen.
    public mutating func markSeen() {
        seenAt = last?.gatheredAt ?? seenAt
    }

    public static let defaultsKey = "ai.digestHistory"

    /// Records a digest's facts and returns what changed since the digest before.
    ///
    /// - Parameter facts: the facts that were sent
    /// - Returns: the changes
    public mutating func record(_ facts: DigestFacts) -> DigestChanges {
        if let last, abs(last.gatheredAt.timeIntervalSince(facts.gatheredAt)) < 0.001 {
            // The same facts again: the same comparison.
            return DigestChanges(since: beforeLast, to: facts)
        }
        beforeLast = last
        last = DigestSnapshot(facts)
        return DigestChanges(since: beforeLast, to: facts)
    }

    public static func load(from defaults: UserDefaults) -> DigestHistory {
        guard let data = defaults.data(forKey: defaultsKey),
            let history = try? JSONDecoder().decode(DigestHistory.self, from: data)
        else {
            return DigestHistory()
        }
        return history
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

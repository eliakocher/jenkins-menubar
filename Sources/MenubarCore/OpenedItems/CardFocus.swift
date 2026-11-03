import Foundation

/// A card of a detail page that a link or an Inbox entry can bring into view: the page scrolls to it and the card
/// pulses once, so the eye finds it.
public enum DetailCardID: String, Hashable, Sendable, CaseIterable {
    /// the Claude card of a build, merge request or work item: Claude's answer, or the chat
    case claude
    /// the comments: a merge request's or a work item's discussion
    case discussion
    /// a build's failed tests
    case failedTests = "failed-tests"
    /// a build's console log
    case consoleLog = "console-log"
}

/// A wish to bring one card of the next shown detail into view, which a detail takes once (``take(at:)``).
///
/// An Inbox entry for a Claude answer opens the item and wants its Claude card shown. The detail may be open already,
/// still loading, or not yet on screen at all (the window is closed), so the wish waits for the detail that has the
/// card and expires after ``lifetime``: a request whose item never appeared must not scroll an unrelated page later.
public struct CardFocus: Equatable, Sendable {
    /// One request. A new one has a new `id`, so asking for the same card twice scrolls twice.
    public struct Request: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var card: DetailCardID
        public var requestedAt: Date
    }

    /// how long a request waits for its detail, in seconds
    public static let lifetime: TimeInterval = 20

    /// the request nobody took yet
    public private(set) var pending: Request?

    public init() {}

    /// Asks for a card; a request that waits is replaced.
    ///
    /// - Parameters:
    ///   - card: the card to bring into view
    ///   - now: the time of the request
    public mutating func request(_ card: DetailCardID, at now: Date = .now) {
        pending = Request(card: card, requestedAt: now)
    }

    /// Takes the waiting request, which then is gone: a detail scrolls to it once.
    ///
    /// - Parameter now: the time of the taking
    /// - Returns: the card; `nil` when nothing waits or the request expired
    public mutating func take(at now: Date = .now) -> DetailCardID? {
        defer { pending = nil }
        guard let pending, now.timeIntervalSince(pending.requestedAt) <= Self.lifetime else {
            return nil
        }
        return pending.card
    }
}

extension InboxEventKind {
    /// the card of the item's page that opening an entry of this kind brings into view: Claude's for its answer, the
    /// discussion for a mention; `nil` for the kinds that show the page from the top
    public var focusCard: DetailCardID? {
        switch self {
        case .claudeAnswered: .claude
        case .mentioned: .discussion
        default: nil
        }
    }
}

extension InboxEntry {
    /// the card of the target's page to bring into view when the entry is opened, see ``InboxEventKind/focusCard``
    public var focusCard: DetailCardID? { kind.focusCard }
}

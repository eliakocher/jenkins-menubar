import Foundation
import Testing

@testable import MenubarCore

@Suite("CardFocus")
struct CardFocusTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("INBOX-07 a card request is taken once, by the first detail that asks")
    func takenOnce() {
        var focus = CardFocus()
        #expect(focus.take(at: Self.start) == nil)
        focus.request(.claude, at: Self.start)
        #expect(focus.pending?.card == .claude)
        #expect(focus.take(at: Self.start.addingTimeInterval(1)) == .claude)
        // A second detail, or the same one drawn again, finds nothing to do.
        #expect(focus.pending == nil)
        #expect(focus.take(at: Self.start.addingTimeInterval(1)) == nil)
    }

    @Test("INBOX-07 a request that waits for its detail expires, and a newer one replaces an older one")
    func expiresAndReplaces() {
        var focus = CardFocus()
        focus.request(.claude, at: Self.start)
        #expect(focus.take(at: Self.start.addingTimeInterval(CardFocus.lifetime + 1)) == nil)
        #expect(focus.pending == nil)

        focus.request(.claude, at: Self.start)
        let first = focus.pending?.id
        focus.request(.claude, at: Self.start.addingTimeInterval(2))
        // The same card asked twice is a new request, so a page that shows it scrolls again.
        #expect(focus.pending?.id != first)
        focus.request(.discussion, at: Self.start.addingTimeInterval(3))
        #expect(focus.take(at: Self.start.addingTimeInterval(4)) == .discussion)
    }

    @Test("INBOX-07 a Claude answer opens at the Claude card and a mention at the discussion; the others from the top")
    func cardsOfTheKinds() {
        for kind in InboxEventKind.allCases {
            switch kind {
            case .claudeAnswered: #expect(kind.focusCard == .claude)
            case .mentioned: #expect(kind.focusCard == .discussion)
            default: #expect(kind.focusCard == nil, "\(kind)")
            }
        }
        let answer = InboxEntry(
            event: .claudeAnswered(
                subjectKey: "mr:acme/web/app!12", useCase: "Summarize Discussion", failed: false, title: "Fix", reference: nil,
                excerpt: nil, url: URL(string: "https://gitlab.example.com/acme/web/app/-/merge_requests/12"),
                at: Self.start))
        #expect(answer.focusCard == .claude)
    }
}

import Foundation
import Testing

@testable import MenubarCore
@testable import MenubarUI

/// The butler on the Inbox's pop-up (INBOX-14): the build alert's butler, sad for a failure and happy for the rest, with the
/// kind's symbol in a badge.
@Suite("InboxEventButler")
@MainActor
struct InboxEventButlerTests {
    private static func event(_ kind: InboxEventKind, headline: String? = nil) -> InboxEvent {
        InboxEvent(
            id: "e|\(kind.rawValue)", kind: kind, source: .local, title: "Add a retry", occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            headlineText: headline)
    }

    @Test("INBOX-14 a failure gets the sad butler: failed pipeline and builds, changes requested, a Claude failure")
    func sadKinds() {
        for kind in [InboxEventKind.pipelineFailed, .buildFailed, .watchedBuildFailed, .changesRequested] {
            #expect(InboxEventView.Look.sad(for: Self.event(kind)), "\(kind)")
        }
        #expect(InboxEventView.Look.sad(for: Self.event(.claudeAnswered, headline: "Claude couldn't answer: Why Did It Fail?")))
    }

    @Test("INBOX-14 everything else gets the happy butler")
    func happyKinds() {
        for kind in [
            InboxEventKind.approved, .merged, .mentioned, .reviewRequested, .assigned, .reviewed, .otherTodo,
            .digestReady, .whatsNew, .buildSucceeded, .watchedBuildSucceeded, .myTodo,
        ] {
            #expect(!InboxEventView.Look.sad(for: Self.event(kind)), "\(kind)")
        }
        #expect(!InboxEventView.Look.sad(for: Self.event(.claudeAnswered, headline: "Claude answered: Why Did It Fail?")))
    }
}

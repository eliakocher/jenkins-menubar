import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("CommentThreadView")
struct CommentThreadViewTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func person(_ username: String) -> MergeRequest.Person {
        MergeRequest.Person(username: username, name: username.capitalized)
    }

    private static func note(_ id: Int, _ who: String?, hoursAgo: Double? = nil, _ body: String = "text") -> ThreadNote {
        ThreadNote(
            id: "\(id)", author: who.map(person), body: body, createdAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    @Test("MR-07 the reply line shows each replier once, the latest last, three at most")
    func repliers() {
        let replies = [
            Self.note(2, "a"), Self.note(3, "b"), Self.note(4, "a"), Self.note(5, "c"), Self.note(6, "d"), Self.note(7, "c"),
        ]
        let thread = CommentThread(id: "t", first: Self.note(1, "z"), replies: replies)
        #expect(ReplySummary(thread).repliers.map(\.username) == ["a", "d", "c"])
    }
}

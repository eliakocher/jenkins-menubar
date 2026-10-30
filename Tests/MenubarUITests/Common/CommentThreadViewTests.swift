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

    @Test(
        "MR-07 the reply line names the count, the last replier and its age",
        arguments: [
            ([note(2, "akim", hoursAgo: 3), note(3, "slee", hoursAgo: 2)], false, "2 replies · last by Slee, 2h ago"),
            ([note(2, "akim", hoursAgo: 2)], false, "1 reply · by Akim, 2h ago"),
            ([note(2, "akim")], false, "1 reply · by Akim"),
            ([note(2, nil, hoursAgo: 1)], false, "1 reply · by Someone, 1h ago"),
            ([note(2, "akim", hoursAgo: 2), note(3, "slee", hoursAgo: 0)], true, "2+ replies · last by Slee, just now"),
        ])
    func replyLine(replies: [ThreadNote], hasMore: Bool, expected: String) {
        let thread = CommentThread(id: "t", first: Self.note(1, "slee"), replies: replies, hasMoreReplies: hasMore)
        #expect(ReplySummary(thread).line(now: Self.now) == expected)
    }

    @Test("MR-07 the reply line shows each replier once, the latest last, three at most")
    func repliers() {
        let replies = [
            Self.note(2, "a"), Self.note(3, "b"), Self.note(4, "a"), Self.note(5, "c"), Self.note(6, "d"), Self.note(7, "c"),
        ]
        let thread = CommentThread(id: "t", first: Self.note(1, "z"), replies: replies)
        #expect(ReplySummary(thread).repliers.map(\.username) == ["a", "d", "c"])
    }

    @Test("MR-07 the resolved line gives the author and the place, else the first line of the text")
    func resolvedLine() {
        let onDiff = CommentThread(
            id: "t", first: Self.note(1, "slee"), location: "Sources/App.swift:42", isResolved: true)
        #expect(ResolvedLine(onDiff) == ResolvedLine(author: "Slee", place: "Sources/App.swift:42"))
        let plain = CommentThread(id: "u", first: Self.note(2, nil, "\n  Please rename it.\nIt is unclear."), isResolved: true)
        #expect(ResolvedLine(plain) == ResolvedLine(author: "Someone", place: "Please rename it."))
    }
}

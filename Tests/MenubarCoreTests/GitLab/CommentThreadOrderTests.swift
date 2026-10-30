import Foundation
import Testing

@testable import MenubarCore

@Suite("CommentThreadOrder")
struct CommentThreadOrderTests {
    private static func at(_ hours: Double?) -> Date? { hours.map { Date(timeIntervalSince1970: 1_800_000_000 + $0 * 3600) } }

    private static func thread(
        _ id: String, _ first: Double?, replies: [Double] = [], resolved: Bool = false
    ) -> CommentThread {
        CommentThread(
            id: id, first: ThreadNote(id: id + "n", author: nil, body: "x", createdAt: at(first)),
            replies: replies.enumerated().map { ThreadNote(id: id + "r\($0.offset)", author: nil, body: "y", createdAt: at($0.element)) },
            isResolved: resolved)
    }

    // a: 1h, replied at 9h; b: 3h; c: 5h (resolved); d: 7h (resolved); e: undated
    private static let threads = [
        thread("a", 1, replies: [9]), thread("b", 3), thread("c", 5, resolved: true), thread("d", 7, resolved: true),
        thread("e", nil),
    ]

    @Test(
        "MR-07 threads order by their last activity, open first or not",
        arguments: [
            (CommentThreadSort.oldestFirst, true, ["b", "a", "e", "c", "d"]),
            (CommentThreadSort.newestFirst, true, ["a", "b", "e", "d", "c"]),
            (CommentThreadSort.oldestFirst, false, ["b", "c", "d", "a", "e"]),
            (CommentThreadSort.newestFirst, false, ["a", "d", "c", "b", "e"]),
        ])
    func ordering(sort: CommentThreadSort, openFirst: Bool, expected: [String]) {
        let order = CommentThreadOrder(sort: sort, openFirst: openFirst)
        #expect(order.ordered(Self.threads).map(\.id) == expected)
    }

    @Test("MR-07 threads with the same activity keep GitLab's order, reversed for newest first")
    func ties() {
        let same = [Self.thread("x", 2), Self.thread("y", 2), Self.thread("z", 2)]
        #expect(CommentThreadOrder(sort: .oldestFirst).ordered(same).map(\.id) == ["x", "y", "z"])
        #expect(CommentThreadOrder(sort: .newestFirst).ordered(same).map(\.id) == ["z", "y", "x"])
    }
}

import Foundation

/// Which end of a discussion comes first, by each thread's last activity.
public enum CommentThreadSort: String, CaseIterable, Sendable {
    case oldestFirst
    case newestFirst

    public var title: String {
        switch self {
        case .oldestFirst: "Oldest First"
        case .newestFirst: "Newest First"
        }
    }
}

/// How a Discussion card orders its threads (MR-07, WIN-02): by last activity, oldest or newest first, with the open
/// threads before the resolved ones or not. The default, oldest first with open ones first, is the order GitLab sends
/// them in with the resolved ones moved behind.
public struct CommentThreadOrder: Equatable, Sendable {
    public var sort: CommentThreadSort
    public var openFirst: Bool

    public static let `default` = CommentThreadOrder(sort: .oldestFirst, openFirst: true)

    /// the `@AppStorage` keys the cards remember the choice under, the same in the merge request's and the work item's
    public static let sortKey = "discussionSort"
    public static let openFirstKey = "discussionOpenFirst"

    public init(sort: CommentThreadSort = .oldestFirst, openFirst: Bool = true) {
        self.sort = sort
        self.openFirst = openFirst
    }

    /// The time of the latest note of the thread (its replies included); `nil` when none of the notes has a date.
    public static func lastActivity(of thread: CommentThread) -> Date? {
        ([thread.first] + thread.replies).compactMap(\.createdAt).max()
    }

    /// Returns the threads in this order. Threads with the same activity keep GitLab's order (reversed for newest first,
    /// which GitLab sends oldest first), and threads without any date come last, in GitLab's order.
    public func ordered(_ threads: [CommentThread]) -> [CommentThread] {
        let entries = threads.enumerated().map { (index: $0.offset, thread: $0.element, date: Self.lastActivity(of: $0.element)) }
        let sorted = entries.sorted { lhs, rhs in
            if openFirst, lhs.thread.isResolved != rhs.thread.isResolved {
                return !lhs.thread.isResolved
            }
            switch (lhs.date, rhs.date) {
            case (nil, nil): return lhs.index < rhs.index
            case (nil, _): return false
            case (_, nil): return true
            case let (left?, right?):
                if left != right {
                    return sort == .oldestFirst ? left < right : left > right
                }
                return sort == .oldestFirst ? lhs.index < rhs.index : lhs.index > rhs.index
            }
        }
        return sorted.map(\.thread)
    }
}

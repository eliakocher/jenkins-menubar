import Foundation
import Observation

/// One comment of a thread: a merge request's review note or a work item's comment (MR-07, WIN-02).
public struct ThreadNote: Hashable, Sendable, Identifiable {
    public var id: String
    /// who wrote it; `nil` for a deleted user
    public var author: MergeRequest.Person?
    /// the Markdown as written
    public var body: String
    public var createdAt: Date?
    /// the note's page, which opens it in the browser
    public var url: URL?

    public init(id: String, author: MergeRequest.Person?, body: String, createdAt: Date? = nil, url: URL? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// A thread of comments: the first one and the replies to it, oldest first. The merge request and the work item detail
/// draw the same thing from it (MR-07, WIN-02).
public struct CommentThread: Hashable, Sendable, Identifiable {
    public var id: String
    public var first: ThreadNote
    public var replies: [ThreadNote]
    /// whether GitLab has more replies than were asked for
    public var hasMoreReplies: Bool
    /// the file, and the line when there is one, of a note on the diff: `src/App.swift:42`; `nil` for a plain comment
    public var location: String?
    /// whether the thread was resolved, which the thread view folds to one line
    public var isResolved: Bool

    public init(
        id: String, first: ThreadNote, replies: [ThreadNote] = [], hasMoreReplies: Bool = false, location: String? = nil,
        isResolved: Bool = false
    ) {
        self.id = id
        self.first = first
        self.replies = replies
        self.hasMoreReplies = hasMoreReplies
        self.location = location
        self.isResolved = isResolved
    }
}

// MARK: - Decoding

/// A GraphQL connection with its `nodes` and whether there is a next page. A node that doesn't decode is left out.
struct ConnectionPage<Node: Decodable>: Decodable {
    var nodes: [Node]
    var hasNextPage: Bool

    private enum Key: String, CodingKey {
        case pageInfo
    }

    private struct PageInfo: Decodable {
        var hasNextPage: Bool?
    }

    // The connection's `nodes` are read from the same object as `pageInfo`.
    init(from decoder: any Decoder) throws {
        let info = try decoder.container(keyedBy: Key.self).decodeIfPresent(PageInfo.self, forKey: .pageInfo)
        hasNextPage = info?.hasNextPage ?? false
        nodes = try Nodes<Node>(from: decoder).nodes
    }
}

/// The author of a note, as GitLab's `UserCore` answers.
struct NoteAuthorShape: Decodable {
    var username: String
    var name: String?

    var person: MergeRequest.Person { MergeRequest.Person(username: username, name: name ?? "") }
}

/// A note of a discussion, as the queries of the merge request and the work item ask for it.
struct NoteShape: Decodable {
    var id: String?
    var url: String?
    var body: String?
    var createdAt: Date?
    var system: Bool?
    var author: NoteAuthorShape?

    /// Returns the note, or `nil` for a system note ("changed the label…"), which the threads leave out.
    ///
    /// - Parameter base: the item's page, which a relative or missing `url` resolves against
    func note(base: URL) -> ThreadNote? {
        guard system != true else {
            return nil
        }
        return ThreadNote(
            id: id ?? UUID().uuidString, author: author?.person, body: body ?? "", createdAt: createdAt,
            url: Self.noteURL(url, id: id, base: base))
    }

    /// Returns the note's page. Without a `url`, the page of the item jumps to the note by its number.
    static func noteURL(_ url: String?, id: String?, base: URL) -> URL? {
        if let url, !url.isEmpty, let parsed = URL(string: url, relativeTo: base)?.absoluteURL,
            parsed.scheme == "http" || parsed.scheme == "https"
        {
            return parsed
        }
        guard let number = id.flatMap({ $0.split(separator: "/").last }), number.allSatisfy(\.isNumber), !number.isEmpty else {
            return nil
        }
        return URL(string: base.absoluteString + "#note_" + number)
    }
}

// MARK: - A work item's discussion

/// A work item's discussion: its comment threads, system notes left out (WIN-02).
public struct WorkItemDiscussion: Hashable, Sendable {
    public var threads: [CommentThread]
    /// whether GitLab has more discussions than were asked for
    public var hasMore: Bool

    public init(threads: [CommentThread] = [], hasMore: Bool = false) {
        self.threads = threads
        self.hasMore = hasMore
    }

    /// how many comments there are in all, replies included
    public var commentCount: Int { threads.reduce(0) { $0 + 1 + $1.replies.count } }
}

extension GitLabOperation where Value == WorkItemDiscussion {
    /// The comments of a work item, in one request: 50 discussions with 50 notes each, comments only (WIN-02).
    ///
    /// The query follows GitLab's GraphQL reference: `WorkItemWidgetNotes.discussions(filter: ONLY_COMMENTS)` leaves the
    /// system notes out on the server; `Note` has `url`, `createdAt`, `system` and `author`. It hasn't been run against a
    /// real GitLab by the author.
    ///
    /// - Parameter source: the work item
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    public static func discussion(of source: DescriptionSource) -> GitLabOperation? {
        guard source.kind == .workItem, let (path, iid) = source.pathAndIID else {
            return nil
        }
        let base = source.webURL
        return GitLabOperation(
            name: "WorkItemDiscussion",
            query: """
                query WorkItemDiscussion($path: ID!, $iid: String!) {
                  namespace(fullPath: $path) {
                    workItem(iid: $iid) {
                      widgets {
                        ... on WorkItemWidgetNotes {
                          discussions(first: 50, filter: ONLY_COMMENTS) {
                            pageInfo { hasNextPage }
                            nodes {
                              id
                              notes(first: 50) {
                                pageInfo { hasNextPage }
                                nodes { id url body createdAt system author { username name } }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                let namespace = try GraphQLAnswer<WorkItemDiscussionShape>.value(of: body).namespace
                guard let workItem = namespace?.workItem else {
                    throw DecodingError.valueNotFound(
                        WorkItemDiscussion.self, .init(codingPath: [], debugDescription: "no work item"))
                }
                // Every other widget answers as an empty object.
                let notes = workItem.widgets?.lazy.compactMap(\.discussions).first
                return WorkItemDiscussion(
                    threads: (notes?.nodes ?? []).compactMap { $0.thread(base: base) }.sorted {
                        ($0.first.createdAt ?? .distantPast) < ($1.first.createdAt ?? .distantPast)
                    },
                    hasMore: notes?.hasNextPage ?? false)
            })
    }
}

private struct WorkItemDiscussionShape: Decodable {
    var namespace: Namespace?

    struct Namespace: Decodable {
        var workItem: WorkItem?
    }

    struct WorkItem: Decodable {
        var widgets: [Widget]?
    }

    struct Widget: Decodable {
        var discussions: ConnectionPage<Discussion>?
    }

    struct Discussion: Decodable {
        var id: String
        var notes: ConnectionPage<NoteShape>?

        func thread(base: URL) -> CommentThread? {
            let notes = (notes?.nodes ?? []).compactMap { $0.note(base: base) }
            guard let first = notes.first else {
                return nil
            }
            return CommentThread(
                id: id, first: first, replies: Array(notes.dropFirst()), hasMoreReplies: self.notes?.hasNextPage ?? false)
        }
    }
}

// MARK: - The store

/// What the detail knows of a work item's discussion (WIN-02).
public struct ItemDiscussionState: Hashable, Sendable {
    /// as last loaded, maybe for an older update of the item; `nil` before an answer
    public var discussion: WorkItemDiscussion?
    /// whether ``discussion`` belongs to the item's last update
    public var isCurrent: Bool
    /// whether the last request failed
    public var failed: Bool

    public init(discussion: WorkItemDiscussion?, isCurrent: Bool, failed: Bool = false) {
        self.discussion = discussion
        self.isCurrent = isCurrent
        self.failed = failed
    }

    /// asked, with no answer yet
    public static let loading = ItemDiscussionState(discussion: nil, isCurrent: false)
    /// the request failed, and no older discussion is kept
    public static let failed = ItemDiscussionState(discussion: nil, isCurrent: false, failed: true)

    /// Returns the answer for the item's last update.
    public static func loaded(_ discussion: WorkItemDiscussion) -> ItemDiscussionState {
        ItemDiscussionState(discussion: discussion, isCurrent: true)
    }
}

/// The discussions of the work items the user selected, loaded one at a time when an item is selected, never with the
/// lists (WIN-02). Kept per item, in memory, for the item's last update, like ``DescriptionsStore``: selecting the item
/// again asks nothing until the list brings a newer `updatedAt`; after a failure the next selection asks again; while a
/// newer update loads or fails, the older discussion stays.
@Observable @MainActor
public final class ItemDiscussionsStore {
    private struct Entry {
        var discussion: WorkItemDiscussion?
        /// the item's `updatedAt` that `discussion` belongs to
        var loadedUpdatedAt: Date?
        var isLoading = false
        var failed = false
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what is known of an item's discussion.
    public func state(of source: DescriptionSource) -> ItemDiscussionState {
        guard let entry = entries[source.reference] else {
            return .loading
        }
        let isCurrent = entry.loadedUpdatedAt.map { $0 >= source.updatedAt } ?? false
        return ItemDiscussionState(
            discussion: entry.discussion, isCurrent: entry.discussion != nil && isCurrent, failed: entry.failed && !entry.isLoading)
    }

    /// Loads an item's discussion, when it is selected: unless it is loading already, or was loaded for the item's last
    /// update. Without a GitLab token or the team values it asks nothing and fails quietly.
    ///
    /// - Parameters:
    ///   - source: the selected work item
    ///   - force: loads again although the discussion belongs to the item's last update, as the window's Reload does
    public func load(_ source: DescriptionSource, force: Bool = false) async {
        let key = source.reference
        var entry = entries[key] ?? Entry()
        if entry.isLoading || (!force && state(of: source).isCurrent) {
            return
        }
        guard let operation = GitLabOperation.discussion(of: source) else {
            entry.failed = true
            entries[key] = entry
            return
        }
        entry.isLoading = true
        entry.failed = false
        entries[key] = entry
        // A task of its own, which a new selection doesn't cancel: the answer is kept for when the item is selected again.
        let services = services
        let discussion = await Task {
            try? await services.session().get().client.send(operation)
        }.value
        entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let discussion {
            entry.discussion = discussion
            entry.loadedUpdatedAt = source.updatedAt
        } else {
            entry.failed = true
        }
        entries[key] = entry
    }
}

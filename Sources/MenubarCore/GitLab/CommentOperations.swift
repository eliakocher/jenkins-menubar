import Foundation

// MARK: - What a comment goes to

/// What a write needs to know of the merge request or work item it goes to: its global id, which every note mutation
/// names, and for a merge request its `diffRefs` (CMT-01, CMT-03).
public struct CommentTarget: Hashable, Sendable {
    public var kind: DescriptionSource.Kind
    /// the global id, `gid://gitlab/MergeRequest/…` or `gid://gitlab/WorkItem/…`
    public var id: String
    /// the commits of the merge request's diff; `nil` for a work item
    public var refs: DiffRefs?

    public init(kind: DescriptionSource.Kind, id: String, refs: DiffRefs? = nil) {
        self.kind = kind
        self.id = id
        self.refs = refs
    }
}

/// A note GitLab accepted: the note as the threads show it, and the discussion it is in (CMT-01).
public struct PostedNote: Hashable, Sendable {
    public var note: ThreadNote
    /// the discussion's global id; for a new top-level comment, the discussion GitLab opened for it
    public var discussionID: String?

    public init(note: ThreadNote, discussionID: String?) {
        self.note = note
        self.discussionID = discussionID
    }

    /// the note as a thread of its own, for a new top-level comment
    public var thread: CommentThread { CommentThread(id: discussionID ?? note.id, first: note) }
}

/// An emoji reaction GitLab knows by name (CMT-06). The names are the emoji's short names, `thumbsup` for 👍.
public struct Reaction: Hashable, Sendable {
    /// GitLab's name, like `thumbsup`
    public var name: String
    public var symbol: String

    public init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    public static let thumbsUp = Reaction(name: "thumbsup", symbol: "👍")
    public static let thumbsDown = Reaction(name: "thumbsdown", symbol: "👎")
    public static let heart = Reaction(name: "heart", symbol: "❤️")
    public static let tada = Reaction(name: "tada", symbol: "🎉")
    public static let eyes = Reaction(name: "eyes", symbol: "👀")

    public static let common: [Reaction] = [.thumbsUp, .thumbsDown, .heart, .tada, .eyes]
}

// MARK: - The operations

extension GitLabOperation where Value == CommentTarget {
    /// Asks for the global id of a merge request or a work item, and a merge request's `diffRefs` (CMT-01).
    ///
    /// Fields from GitLab's GraphQL reference (inferred, not run against a GitLab by the author): `MergeRequest.id`,
    /// `MergeRequest.diffRefs { baseSha headSha startSha }`, `WorkItem.id`.
    ///
    /// - Parameter source: the merge request or work item
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func commentTarget(of source: DescriptionSource) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let variables = GraphQLValue.object([("path", .string(path)), ("iid", .string(iid))])
        switch source.kind {
        case .mergeRequest:
            return GitLabOperation(
                name: "CommentTargetMergeRequest",
                query: """
                    query CommentTargetMergeRequest($path: ID!, $iid: String!) {
                      project(fullPath: $path) { mergeRequest(iid: $iid) { id diffRefs { baseSha headSha startSha } } }
                    }
                    """,
                variables: variables,
                decode: { body in
                    guard let node = try GraphQLAnswer<MergeRequestTargetShape>.value(of: body).project?.mergeRequest else {
                        throw DecodingError.valueNotFound(
                            CommentTarget.self, .init(codingPath: [], debugDescription: "no merge request"))
                    }
                    let refs = node.diffRefs.flatMap { refs -> DiffRefs? in
                        guard let base = refs.baseSha, let head = refs.headSha, let start = refs.startSha else {
                            return nil
                        }
                        return DiffRefs(baseSha: base, headSha: head, startSha: start)
                    }
                    return CommentTarget(kind: .mergeRequest, id: node.id, refs: refs)
                })
        case .workItem:
            return GitLabOperation(
                name: "CommentTargetWorkItem",
                query: """
                    query CommentTargetWorkItem($path: ID!, $iid: String!) {
                      namespace(fullPath: $path) { workItem(iid: $iid) { id } }
                    }
                    """,
                variables: variables,
                decode: { body in
                    guard let node = try GraphQLAnswer<WorkItemTargetShape>.value(of: body).namespace?.workItem else {
                        throw DecodingError.valueNotFound(
                            CommentTarget.self, .init(codingPath: [], debugDescription: "no work item"))
                    }
                    return CommentTarget(kind: .workItem, id: node.id)
                })
        }
    }
}

private struct MergeRequestTargetShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: Node?
    }

    struct Node: Decodable {
        var id: String
        var diffRefs: Refs?
    }

    struct Refs: Decodable {
        var baseSha: String?
        var headSha: String?
        var startSha: String?
    }
}

private struct WorkItemTargetShape: Decodable {
    var namespace: Namespace?

    struct Namespace: Decodable {
        var workItem: Node?
    }

    struct Node: Decodable {
        var id: String
    }
}

/// What a note mutation answers with, and how its payload is checked.
private enum NotePayload {
    static let fields = "id url body createdAt author { username name } discussion { id }"

    struct Payload: Decodable {
        var errors: [String]?
        var note: NoteNode?
        var discussion: DiscussionShape?
        var awardEmoji: AwardShape?
    }

    struct NoteNode: Decodable {
        var id: String
        var url: String?
        var body: String?
        var createdAt: Date?
        var author: NoteAuthorShape?
        var discussion: DiscussionShape?
    }

    struct DiscussionShape: Decodable {
        var id: String
        var resolved: Bool?
    }

    struct AwardShape: Decodable {
        var name: String?
    }

    /// Returns the payload of a mutation, or throws GitLab's `errors`, or when the field is missing.
    static func payload(_ body: Data, field: String) throws -> Payload {
        guard let payload = try GraphQLAnswer<[String: Payload?]>.value(of: body)[field] ?? nil else {
            throw DecodingError.valueNotFound(Payload.self, .init(codingPath: [], debugDescription: "no \(field)"))
        }
        if let errors = payload.errors, !errors.isEmpty {
            throw GitLabError(.graphQLErrors(messages: errors))
        }
        return payload
    }

    static func posted(_ body: Data, field: String, base: URL) throws -> PostedNote {
        guard let note = try payload(body, field: field).note else {
            throw DecodingError.valueNotFound(NoteNode.self, .init(codingPath: [], debugDescription: "no note"))
        }
        return PostedNote(
            note: ThreadNote(
                id: note.id, author: note.author?.person, body: note.body ?? "", createdAt: note.createdAt,
                url: CommentNoteURL.url(note.url, id: note.id, base: base)),
            discussionID: note.discussion?.id)
    }
}

/// The page of a note GitLab just created.
enum CommentNoteURL {
    static func url(_ url: String?, id: String?, base: URL) -> URL? {
        NoteShape.noteURL(url, id: id, base: base)
    }
}

extension GitLabOperation where Value == PostedNote {
    /// Adds a comment: a reply to a discussion with `discussionId`, a new top-level comment without it. GraphQL's
    /// `createNote` with `CreateNoteInput`: `noteableId`, `body`, `discussionId`, `internal` (GitLab's reference,
    /// inferred, never sent to a real GitLab). A work item's global id is taken as `noteableId` too (inferred).
    ///
    /// - Parameters:
    ///   - target: the merge request or work item
    ///   - body: the Markdown
    ///   - discussionID: the discussion's global id to reply to; `nil` for a new thread
    ///   - base: the item's page, which the note's link resolves against
    static func createNote(target: CommentTarget, body: String, discussionID: String?, base: URL) -> GitLabOperation {
        var input: [(String, GraphQLValue)] = [("noteableId", .string(target.id)), ("body", .string(body))]
        if let discussionID {
            input.append(("discussionId", .string(discussionID)))
        }
        return GitLabOperation(
            name: "CommentCreateNote",
            query: """
                mutation CommentCreateNote($input: CreateNoteInput!) {
                  createNote(input: $input) { errors note { \(NotePayload.fields) } }
                }
                """,
            variables: .object([("input", .object(input))]),
            decode: { try NotePayload.posted($0, field: "createNote", base: base) })
    }

    /// Edits a note: `updateNote` with `UpdateNoteInput` `id` and `body` (inferred).
    ///
    /// - Parameters:
    ///   - id: the note's global id
    ///   - body: the new Markdown
    ///   - base: the item's page
    static func updateNote(id: String, body: String, base: URL) -> GitLabOperation {
        GitLabOperation(
            name: "CommentUpdateNote",
            query: """
                mutation CommentUpdateNote($input: UpdateNoteInput!) {
                  updateNote(input: $input) { errors note { \(NotePayload.fields) } }
                }
                """,
            variables: .object([("input", .object([("id", .string(id)), ("body", .string(body))]))]),
            decode: { try NotePayload.posted($0, field: "updateNote", base: base) })
    }

    /// Starts a thread on lines of a merge request's diff with one line: `createDiffNote` with `CreateDiffNoteInput`
    /// `noteableId`, `body` and `position` (`DiffPositionInput`, see ``DiffPosition/graphQLInput``; inferred). A
    /// comment on several lines goes by REST instead (``GitLabClient/addDiffThread(_:body:to:)``).
    ///
    /// - Parameters:
    ///   - target: the merge request
    ///   - position: the place on the diff, without a range
    ///   - body: the Markdown
    ///   - base: the merge request's page
    static func createDiffNote(target: CommentTarget, position: DiffPosition, body: String, base: URL) -> GitLabOperation {
        GitLabOperation(
            name: "CommentCreateDiffNote",
            query: """
                mutation CommentCreateDiffNote($input: CreateDiffNoteInput!) {
                  createDiffNote(input: $input) { errors note { \(NotePayload.fields) } }
                }
                """,
            variables: .object([
                ("input", .object([("noteableId", .string(target.id)), ("body", .string(body)), ("position", position.graphQLInput)]))
            ]),
            decode: { try NotePayload.posted($0, field: "createDiffNote", base: base) })
    }
}

extension GitLabOperation where Value == Bool {
    /// Deletes a note: `destroyNote` with `DestroyNoteInput` `id` (inferred). The value is `true` when GitLab reports no
    /// errors.
    ///
    /// - Parameter id: the note's global id
    static func destroyNote(id: String) -> GitLabOperation {
        GitLabOperation(
            name: "CommentDestroyNote",
            query: """
                mutation CommentDestroyNote($input: DestroyNoteInput!) {
                  destroyNote(input: $input) { errors }
                }
                """,
            variables: .object([("input", .object([("id", .string(id))]))]),
            decode: { body in
                _ = try NotePayload.payload(body, field: "destroyNote")
                return true
            })
    }

    /// Resolves or unresolves a thread: `discussionToggleResolve` with `DiscussionToggleResolveInput` `id` and `resolve`
    /// (inferred). The value is whether the discussion is resolved afterwards.
    ///
    /// - Parameters:
    ///   - discussionID: the discussion's global id
    ///   - resolve: `true` to resolve, `false` to unresolve
    static func toggleResolve(discussionID: String, resolve: Bool) -> GitLabOperation {
        GitLabOperation(
            name: "CommentToggleResolve",
            query: """
                mutation CommentToggleResolve($input: DiscussionToggleResolveInput!) {
                  discussionToggleResolve(input: $input) { errors discussion { id resolved } }
                }
                """,
            variables: .object([("input", .object([("id", .string(discussionID)), ("resolve", .bool(resolve))]))]),
            decode: { body in
                try NotePayload.payload(body, field: "discussionToggleResolve").discussion?.resolved ?? resolve
            })
    }

    /// Adds my emoji reaction to a note or a merge request: `awardEmojiAdd` with `AwardEmojiAddInput` `awardableId`
    /// and `name` (inferred). GitLab answers an error when I reacted with it already.
    ///
    /// - Parameters:
    ///   - awardableID: the global id of the note, the merge request or the work item
    ///   - reaction: the emoji
    static func awardEmoji(to awardableID: String, _ reaction: Reaction) -> GitLabOperation {
        emoji("awardEmojiAdd", "AwardEmojiAddInput", awardableID, reaction)
    }

    /// Takes my emoji reaction back: `awardEmojiRemove` with `AwardEmojiRemoveInput` (inferred).
    ///
    /// - Parameters:
    ///   - awardableID: the global id of the note, the merge request or the work item
    ///   - reaction: the emoji
    static func removeEmoji(from awardableID: String, _ reaction: Reaction) -> GitLabOperation {
        emoji("awardEmojiRemove", "AwardEmojiRemoveInput", awardableID, reaction)
    }

    private static func emoji(_ field: String, _ input: String, _ id: String, _ reaction: Reaction) -> GitLabOperation {
        let name = "Comment" + field.prefix(1).uppercased() + field.dropFirst()
        return GitLabOperation(
            name: name,
            query: """
                mutation \(name)($input: \(input)!) {
                  \(field)(input: $input) { errors }
                }
                """,
            variables: .object([("input", .object([("awardableId", .string(id)), ("name", .string(reaction.name))]))]),
            decode: { body in
                _ = try NotePayload.payload(body, field: field)
                return true
            })
    }
}

// MARK: - The client's writes

extension GitLabClient {
    /// Asks for the ids a write needs of a merge request or work item.
    ///
    /// - Parameter source: the merge request or work item
    /// - Returns: its global id, and a merge request's `diffRefs`
    /// - Throws: ``GitLabError``
    public func commentTarget(of source: DescriptionSource) async throws -> CommentTarget {
        guard let operation = GitLabOperation<CommentTarget>.commentTarget(of: source) else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        return try await send(operation)
    }

    /// Replies to a discussion, or adds a new top-level comment, on the user's click (CMT-01).
    ///
    /// - Parameters:
    ///   - body: the Markdown
    ///   - target: the merge request or work item
    ///   - source: the same item, for the note's link
    ///   - discussionID: the discussion to reply to; `nil` for a new thread
    /// - Returns: the note GitLab created
    /// - Throws: ``GitLabError``
    public func postComment(
        _ body: String, to target: CommentTarget, of source: DescriptionSource, replyingTo discussionID: String? = nil
    ) async throws -> PostedNote {
        try await send(.createNote(target: target, body: body, discussionID: discussionID, base: source.webURL))
    }

    /// Edits a note of mine (CMT-02).
    ///
    /// - Parameters:
    ///   - id: the note's global id
    ///   - body: the new Markdown
    ///   - source: the item, for the note's link
    /// - Throws: ``GitLabError``
    public func editNote(_ id: String, body: String, of source: DescriptionSource) async throws -> PostedNote {
        try await send(.updateNote(id: id, body: body, base: source.webURL))
    }

    /// Deletes a note of mine (CMT-02).
    ///
    /// - Parameter id: the note's global id
    /// - Throws: ``GitLabError``
    public func deleteNote(_ id: String) async throws {
        _ = try await send(GitLabOperation<Bool>.destroyNote(id: id))
    }

    /// Resolves or unresolves a thread (CMT-04).
    ///
    /// - Parameters:
    ///   - discussionID: the discussion's global id
    ///   - resolved: the state to set
    /// - Returns: whether GitLab says the thread is resolved
    /// - Throws: ``GitLabError``
    @discardableResult
    public func setResolved(_ discussionID: String, to resolved: Bool) async throws -> Bool {
        try await send(.toggleResolve(discussionID: discussionID, resolve: resolved))
    }

    /// Adds or takes back my reaction (CMT-06).
    ///
    /// - Parameters:
    ///   - reaction: the emoji
    ///   - awardableID: the global id of the note or item
    ///   - present: `true` to add it, `false` to remove it
    /// - Throws: ``GitLabError``
    public func react(_ reaction: Reaction, on awardableID: String, present: Bool) async throws {
        if present {
            _ = try await send(GitLabOperation<Bool>.awardEmoji(to: awardableID, reaction))
        } else {
            _ = try await send(GitLabOperation<Bool>.removeEmoji(from: awardableID, reaction))
        }
    }

    /// Starts a thread on the diff, on the user's click (CMT-03): a single line by GraphQL, several lines by REST (see
    /// ``addDiffThread(_:body:to:)``).
    ///
    /// - Parameters:
    ///   - body: the Markdown
    ///   - position: the place on the diff, from ``DiffPositionBuilder``
    ///   - source: the merge request
    ///   - target: its ids, from ``commentTarget(of:)``
    /// - Returns: the new thread's first note
    /// - Throws: ``GitLabError``
    public func postDiffComment(
        _ body: String, at position: DiffPosition, of source: DescriptionSource, target: CommentTarget
    ) async throws -> PostedNote {
        if position.range != nil {
            return try await addDiffThread(position, body: body, to: source)
        }
        return try await send(.createDiffNote(target: target, position: position, body: body, base: source.webURL))
    }
}

import Foundation
import Observation

// MARK: - What the store sends with

/// The writes the comment store makes, which ``GitLabClient`` does; a fake stands in for it in the tests (CMT-01).
public protocol CommentSending: Sendable {
    func commentTarget(of source: DescriptionSource) async throws -> CommentTarget
    func postComment(_ body: String, to target: CommentTarget, of source: DescriptionSource, replyingTo discussionID: String?) async throws
        -> PostedNote
    func editNote(_ id: String, body: String, of source: DescriptionSource) async throws -> PostedNote
    func deleteNote(_ id: String) async throws
    func setResolved(_ discussionID: String, to resolved: Bool) async throws -> Bool
    func react(_ reaction: Reaction, on awardableID: String, present: Bool) async throws
    func postDiffComment(_ body: String, at position: DiffPosition, of source: DescriptionSource, target: CommentTarget) async throws
        -> PostedNote
}

extension GitLabClient: CommentSending {}

/// Sends with the client of the moment: a session per write, so a token changed in Settings is used at once, and the
/// requests are logged by the recorder (CMT-01). Without a token or the team values every write fails with the setup
/// message.
public struct ServicesCommentSender: CommentSending {
    private let services: GitLabServices

    public init(services: GitLabServices) {
        self.services = services
    }

    private func client() async throws -> GitLabClient {
        try await services.session().get().client
    }

    public func commentTarget(of source: DescriptionSource) async throws -> CommentTarget {
        try await client().commentTarget(of: source)
    }

    public func postComment(
        _ body: String, to target: CommentTarget, of source: DescriptionSource, replyingTo discussionID: String?
    ) async throws -> PostedNote {
        try await client().postComment(body, to: target, of: source, replyingTo: discussionID)
    }

    public func editNote(_ id: String, body: String, of source: DescriptionSource) async throws -> PostedNote {
        try await client().editNote(id, body: body, of: source)
    }

    public func deleteNote(_ id: String) async throws {
        try await client().deleteNote(id)
    }

    public func setResolved(_ discussionID: String, to resolved: Bool) async throws -> Bool {
        try await client().setResolved(discussionID, to: resolved)
    }

    public func react(_ reaction: Reaction, on awardableID: String, present: Bool) async throws {
        try await client().react(reaction, on: awardableID, present: present)
    }

    public func postDiffComment(
        _ body: String, at position: DiffPosition, of source: DescriptionSource, target: CommentTarget
    ) async throws -> PostedNote {
        try await client().postDiffComment(body, at: position, of: source, target: target)
    }
}

// MARK: - The store

/// A note the user wrote that GitLab may not have yet: shown at once, then confirmed or marked failed (CMT-01).
public struct PendingNote: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// the request is out
        case sending
        /// GitLab refused or didn't answer; the text is kept for Try Again or Discard
        case failed(String)
        /// GitLab took it: the note with its real ids, shown until the next load brings it
        case sent(PostedNote)
    }

    /// the local id, `local-…`, which the note has until GitLab gives it one
    public var id: String
    /// the discussion it replies to; `nil` for a new thread
    public var discussionID: String?
    public var body: String
    public var createdAt: Date
    /// where a new thread on the diff goes; `nil` for a plain reply or comment
    public var position: DiffPosition?
    public var status: Status

    /// whether the note is on the Mac only
    public var isLocal: Bool {
        if case .sent = status { false } else { true }
    }
}

/// How a write ended.
public enum CommentOutcome: Hashable, Sendable {
    case done
    /// not sent: the rule that refused it, in words for the user
    case refused(String)
    /// sent and failed, and rolled back: GitLab's or the network's problem
    case failed(String)
}

/// Writes to the discussions with the optimistic UI of Task 7.09: each change is applied at once on top of the loaded
/// threads (``apply(to:of:)``), then confirmed when GitLab accepts it, or rolled back with the problem when it doesn't
/// (CMT-01 … CMT-06). Every write is a method the user's click calls, and nothing in the store writes by itself.
///
/// The loaded threads stay the truth: after a reload, ``reconcile(_:of:)`` drops what the answer already shows.
@Observable @MainActor
public final class CommentStore {
    /// what is applied on top of one item's loaded threads
    private struct Overlay {
        var pending: [PendingNote] = []
        var edits: [String: Edit] = [:]
        /// the notes deleted, confirmed or not
        var deleted: [String: Bool] = [:]
        var resolved: [String: Edit.Flag] = [:]
    }

    private struct Edit {
        var body: String
        var isConfirmed: Bool

        struct Flag {
            var value: Bool
            var isConfirmed: Bool
        }
    }

    private var overlays: [String: Overlay] = [:]
    private var drafts: [String: String] = [:]
    private var reactions: [String: Set<String>] = [:]
    @ObservationIgnored private var targets: [String: CommentTarget] = [:]
    @ObservationIgnored private let sender: any CommentSending
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeID: @Sendable () -> String

    /// my username, compared without case; `nil` until it is known, and then nothing counts as mine
    public var me: String?
    /// the problem of the last write that failed or was refused, for a banner; the caller clears it
    public var lastError: String?

    /// - Parameters:
    ///   - sender: what sends the writes
    ///   - me: my GitLab username
    ///   - now: the current time, for a pending note's date
    ///   - makeID: makes the unique part of a local id
    public init(
        sender: any CommentSending, me: String?, now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.sender = sender
        self.me = me
        self.now = now
        self.makeID = makeID
    }

    // MARK: Reading

    /// Whether a note is mine, so that I may edit or delete it. A note of a deleted user, or any note while my username
    /// is unknown, isn't (CMT-02).
    public func isMine(_ note: ThreadNote) -> Bool {
        guard let me, let author = note.author?.username else {
            return false
        }
        return author.caseInsensitiveCompare(me) == .orderedSame && !note.id.hasPrefix(Self.localPrefix)
    }

    /// Returns the loaded threads with the changes not yet loaded applied: my pending replies and comments, edited
    /// texts, deleted notes and resolve states. A thread whose first note was deleted continues with its first reply,
    /// and is gone without one.
    ///
    /// - Parameters:
    ///   - threads: the threads as GitLab sent them
    ///   - source: the merge request or work item
    public func apply(to threads: [CommentThread], of source: DescriptionSource) -> [CommentThread] {
        guard let overlay = overlays[source.reference] else {
            return threads
        }
        let known = Set(threads.flatMap { [$0.id, $0.first.id] + $0.replies.map(\.id) })
        var result: [CommentThread] = []
        for var thread in threads {
            var notes = [thread.first] + thread.replies
            for pending in overlay.pending where pending.discussionID == thread.id {
                if let note = Self.note(of: pending, me: me), !known.contains(note.id) {
                    notes.append(note)
                }
            }
            notes = notes.filter { overlay.deleted[$0.id] == nil }.map { note in
                var note = note
                if let edit = overlay.edits[note.id] {
                    note.body = edit.body
                }
                return note
            }
            guard let first = notes.first else {
                continue
            }
            thread.first = first
            thread.replies = Array(notes.dropFirst())
            if let resolved = overlay.resolved[thread.id] {
                thread.isResolved = resolved.value
            }
            result.append(thread)
        }
        for pending in overlay.pending where pending.discussionID == nil {
            if case .sent(let posted) = pending.status, known.contains(posted.discussionID ?? posted.note.id) {
                continue
            }
            if let note = Self.note(of: pending, me: me) {
                var thread = CommentThread(id: Self.threadID(of: pending), first: note)
                if let position = pending.position {
                    let file = position.newPath
                    thread.location = (position.newLine ?? position.oldLine).map { "\(file):\($0)" } ?? file
                }
                result.append(thread)
            }
        }
        return result
    }

    /// Returns the notes the user wrote that aren't confirmed yet, for the item: to dim them and offer Try Again.
    public func pending(of source: DescriptionSource) -> [PendingNote] {
        overlays[source.reference]?.pending ?? []
    }

    /// Returns what became of a note on screen, by its id, which may be a local one.
    public func pendingNote(_ id: String, of source: DescriptionSource) -> PendingNote? {
        overlays[source.reference]?.pending.first { $0.id == id || Self.threadID(of: $0) == id }
    }

    /// Drops what a loaded answer already shows: a confirmed note that is in it, a confirmed edit, delete or resolve
    /// that it reflects. Call it after each load of the item's threads.
    ///
    /// - Parameters:
    ///   - threads: the threads as GitLab sent them
    ///   - source: the merge request or work item
    public func reconcile(_ threads: [CommentThread], of source: DescriptionSource) {
        guard var overlay = overlays[source.reference] else {
            return
        }
        let notes = Dictionary(
            threads.flatMap { ([$0.first] + $0.replies).map { note in (note.id, note) } }, uniquingKeysWith: { first, _ in first })
        let resolved = Dictionary(threads.map { ($0.id, $0.isResolved) }, uniquingKeysWith: { first, _ in first })
        overlay.pending.removeAll { pending in
            if case .sent(let posted) = pending.status {
                return notes[posted.note.id] != nil
            }
            return false
        }
        overlay.edits = overlay.edits.filter { id, edit in !(edit.isConfirmed && (notes[id].map { $0.body == edit.body } ?? true)) }
        overlay.deleted = overlay.deleted.filter { id, confirmed in !(confirmed && notes[id] == nil) }
        overlay.resolved = overlay.resolved.filter { id, flag in !(flag.isConfirmed && resolved[id].map { $0 == flag.value } ?? true) }
        overlays[source.reference] = overlay
    }

    // MARK: Drafts

    /// Returns the unsent reply of a thread, or of the new comment box when `thread` is `nil`. It stays while the user
    /// looks at other items (CMT-08); in memory only.
    public func draft(for thread: String?, in source: DescriptionSource) -> String {
        drafts[Self.draftKey(thread, source)] ?? ""
    }

    /// Keeps the text of a reply box as the user types. Empty text forgets the draft.
    public func setDraft(_ text: String, for thread: String?, in source: DescriptionSource) {
        let key = Self.draftKey(thread, source)
        if text.isEmpty {
            drafts[key] = nil
        } else {
            drafts[key] = text
        }
    }

    /// whether any thread of the item has an unsent draft, for a dot in the list
    public func hasDraft(in source: DescriptionSource) -> Bool {
        drafts.keys.contains { $0.hasPrefix(source.reference + "\u{1F}") }
    }

    // MARK: Writing

    /// Replies to a thread, or adds a new top-level comment, on the user's click (CMT-01). The note shows at once as
    /// pending and the draft is cleared; on failure the note stays with its problem for ``retry(_:in:)`` or
    /// ``discard(_:in:)``.
    ///
    /// - Parameters:
    ///   - body: the Markdown
    ///   - thread: the thread's id to reply to; `nil` for a new comment
    ///   - source: the merge request or work item
    /// - Returns: `.done`, `.refused` for an empty text, `.failed` with the problem
    @discardableResult
    public func send(_ body: String, to thread: String?, in source: DescriptionSource) async -> CommentOutcome {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("Write something first.")
        }
        let pending = PendingNote(
            id: Self.localPrefix + makeID(), discussionID: thread, body: body, createdAt: now(), position: nil, status: .sending)
        add(pending, to: source)
        setDraft("", for: thread, in: source)
        return await deliver(pending.id, in: source)
    }

    /// Starts a thread on lines of the diff, on the user's click (CMT-03). The position comes from
    /// ``DiffPositionBuilder`` with the refs of ``target(of:)``.
    ///
    /// - Parameters:
    ///   - body: the Markdown
    ///   - position: the place on the diff
    ///   - source: the merge request
    @discardableResult
    public func sendDiffComment(_ body: String, at position: DiffPosition, in source: DescriptionSource) async -> CommentOutcome {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("Write something first.")
        }
        let pending = PendingNote(
            id: Self.localPrefix + makeID(), discussionID: nil, body: body, createdAt: now(), position: position, status: .sending)
        add(pending, to: source)
        return await deliver(pending.id, in: source)
    }

    /// Sends a failed note again.
    ///
    /// - Parameters:
    ///   - id: the pending note's local id
    ///   - source: the merge request or work item
    @discardableResult
    public func retry(_ id: String, in source: DescriptionSource) async -> CommentOutcome {
        guard let pending = pendingNote(id, of: source), case .failed = pending.status else {
            return .refused("Nothing to send again.")
        }
        update(pending.id, in: source) { $0.status = .sending }
        return await deliver(pending.id, in: source)
    }

    /// Drops a failed note and puts its text back in the reply box, unless the box has new text.
    ///
    /// - Parameters:
    ///   - id: the pending note's local id
    ///   - source: the merge request or work item
    public func discard(_ id: String, in source: DescriptionSource) {
        guard let pending = pendingNote(id, of: source), case .failed = pending.status else {
            return
        }
        overlays[source.reference]?.pending.removeAll { $0.id == pending.id }
        if pending.position == nil, draft(for: pending.discussionID, in: source).isEmpty {
            setDraft(pending.body, for: pending.discussionID, in: source)
        }
    }

    /// Changes the text of a note of mine, on the user's click (CMT-02). Only my own: another's is refused without a
    /// request, and so is a note that isn't on GitLab yet.
    ///
    /// - Parameters:
    ///   - note: the note
    ///   - body: the new Markdown
    ///   - source: the merge request or work item
    @discardableResult
    public func edit(_ note: ThreadNote, to body: String, in source: DescriptionSource) async -> CommentOutcome {
        guard isMine(note) else {
            return refuse("You can only edit your own comments.")
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return refuse("A comment can't be empty. Delete it instead.")
        }
        let key = source.reference
        let before = overlays[key]?.edits[note.id]
        overlays[key, default: Overlay()].edits[note.id] = Edit(body: body, isConfirmed: false)
        do {
            let posted = try await sender.editNote(note.id, body: body, of: source)
            overlays[key]?.edits[note.id] = Edit(body: posted.note.body.isEmpty ? body : posted.note.body, isConfirmed: true)
            return .done
        } catch {
            overlays[key]?.edits[note.id] = before
            return fail(error)
        }
    }

    /// Deletes a note of mine, on the user's click (CMT-02). The caller confirms first. The note leaves the threads at
    /// once and comes back when GitLab refuses.
    ///
    /// - Parameters:
    ///   - note: the note
    ///   - source: the merge request or work item
    @discardableResult
    public func delete(_ note: ThreadNote, in source: DescriptionSource) async -> CommentOutcome {
        guard isMine(note) else {
            return refuse("You can only delete your own comments.")
        }
        let key = source.reference
        overlays[key, default: Overlay()].deleted[note.id] = false
        do {
            try await sender.deleteNote(note.id)
            overlays[key]?.deleted[note.id] = true
            return .done
        } catch {
            overlays[key]?.deleted[note.id] = nil
            return fail(error)
        }
    }

    /// Resolves or unresolves a thread, on the user's click (CMT-04); the thread shows its new state at once.
    ///
    /// - Parameters:
    ///   - thread: the thread's id
    ///   - resolved: the state to set
    ///   - source: the merge request
    @discardableResult
    public func setResolved(_ thread: String, to resolved: Bool, in source: DescriptionSource) async -> CommentOutcome {
        let key = source.reference
        let before = overlays[key]?.resolved[thread]
        overlays[key, default: Overlay()].resolved[thread] = .init(value: resolved, isConfirmed: false)
        do {
            let state = try await sender.setResolved(thread, to: resolved)
            overlays[key]?.resolved[thread] = .init(value: state, isConfirmed: true)
            return .done
        } catch {
            overlays[key]?.resolved[thread] = before
            return fail(error)
        }
    }

    /// Returns whether I reacted to a note or an item with an emoji, as far as this session knows: GitLab's loaded
    /// threads don't carry reactions.
    public func hasReacted(_ reaction: Reaction, to awardableID: String) -> Bool {
        reactions[awardableID]?.contains(reaction.name) ?? false
    }

    /// Adds or takes back my reaction, on the user's click (CMT-06); it shows at once and rolls back on failure.
    ///
    /// - Parameters:
    ///   - reaction: the emoji
    ///   - awardableID: the global id of the note or item
    ///   - present: `true` to add it, `false` to take it back
    @discardableResult
    public func react(_ reaction: Reaction, on awardableID: String, present: Bool) async -> CommentOutcome {
        let before = reactions[awardableID] ?? []
        var after = before
        if present { after.insert(reaction.name) } else { after.remove(reaction.name) }
        reactions[awardableID] = after
        do {
            try await sender.react(reaction, on: awardableID, present: present)
            return .done
        } catch {
            reactions[awardableID] = before
            return fail(error)
        }
    }

    /// Returns what a write to the item needs: its global id and a merge request's `diffRefs`, asked once and kept
    /// until ``forgetTarget(of:)``. The `diffRefs` change with every push, so ask again after a reload of the merge
    /// request.
    ///
    /// - Parameter source: the merge request or work item
    /// - Returns: the target, or `nil` with ``lastError`` set
    public func target(of source: DescriptionSource) async -> CommentTarget? {
        if let kept = targets[source.reference] {
            return kept
        }
        do {
            let target = try await sender.commentTarget(of: source)
            targets[source.reference] = target
            return target
        } catch {
            _ = fail(error)
            return nil
        }
    }

    /// Forgets the kept ids of an item, after a push changed its `diffRefs`.
    public func forgetTarget(of source: DescriptionSource) {
        targets[source.reference] = nil
    }

    // MARK: Internals

    static let localPrefix = "local-"

    private func add(_ pending: PendingNote, to source: DescriptionSource) {
        overlays[source.reference, default: Overlay()].pending.append(pending)
    }

    private func update(_ id: String, in source: DescriptionSource, _ change: (inout PendingNote) -> Void) {
        guard let index = overlays[source.reference]?.pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&overlays[source.reference]!.pending[index])
    }

    private func deliver(_ id: String, in source: DescriptionSource) async -> CommentOutcome {
        guard let pending = pendingNote(id, of: source), let target = await target(of: source) else {
            let message = lastError ?? "The comment couldn't be sent."
            update(id, in: source) { $0.status = .failed(message) }
            return .failed(message)
        }
        do {
            let posted: PostedNote
            if let position = pending.position {
                posted = try await sender.postDiffComment(pending.body, at: position, of: source, target: target)
            } else {
                posted = try await sender.postComment(pending.body, to: target, of: source, replyingTo: pending.discussionID)
            }
            update(id, in: source) { $0.status = .sent(posted) }
            return .done
        } catch {
            let message = Self.message(of: error)
            update(id, in: source) { $0.status = .failed(message) }
            lastError = message
            return .failed(message)
        }
    }

    private func refuse(_ message: String) -> CommentOutcome {
        lastError = message
        return .refused(message)
    }

    private func fail(_ error: any Error) -> CommentOutcome {
        let message = Self.message(of: error)
        lastError = message
        return .failed(message)
    }

    private static func message(of error: any Error) -> String {
        (error as? GitLabError)?.description ?? error.localizedDescription
    }

    private static func draftKey(_ thread: String?, _ source: DescriptionSource) -> String {
        source.reference + "\u{1F}" + (thread ?? "")
    }

    /// the id a pending note's thread has: GitLab's once it is sent, else the local one
    private static func threadID(of pending: PendingNote) -> String {
        if case .sent(let posted) = pending.status {
            return posted.discussionID ?? posted.note.id
        }
        return pending.id
    }

    private static func note(of pending: PendingNote, me: String?) -> ThreadNote? {
        if case .sent(let posted) = pending.status {
            return posted.note
        }
        return ThreadNote(
            id: pending.id, author: me.map { MergeRequest.Person(username: $0, name: "") }, body: pending.body,
            createdAt: pending.createdAt)
    }
}

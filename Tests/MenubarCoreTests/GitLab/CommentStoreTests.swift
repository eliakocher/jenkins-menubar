import Foundation
import Testing

@testable import MenubarCore

/// The comment store: changes applied at once, confirmed or rolled back, my own notes only, drafts per thread
/// (CMT-01, CMT-02, CMT-04, CMT-06, CMT-08).
@Suite("Comment store")
@MainActor
struct CommentStoreTests {
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/16")!,
        updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private nonisolated static let other = DescriptionSource(
        kind: .workItem, reference: "group/project#31", webURL: URL(string: "https://gitlab.example.com/group/project/-/issues/31")!,
        updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private nonisolated static let jane = MergeRequest.Person(username: "jdoe", name: "Jane Doe")
    private nonisolated static let sam = MergeRequest.Person(username: "slee", name: "Sam Lee")

    private nonisolated static let mine = ThreadNote(id: "gid://gitlab/Note/1", author: jane, body: "My first")
    private nonisolated static let theirs = ThreadNote(id: "gid://gitlab/Note/2", author: sam, body: "Their reply")
    private nonisolated static let thread = CommentThread(id: "gid://gitlab/Discussion/a", first: mine, replies: [theirs])

    /// A sender that answers as told and waits at a gate when asked, so a test can look at the state in between.
    private final class FakeSender: CommentSending, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var failure: GitLabError?
        var gate: Gate?
        var posted = PostedNote(
            note: ThreadNote(id: "gid://gitlab/Note/50", author: CommentStoreTests.jane, body: "sent"), discussionID: "gid://gitlab/Discussion/a")

        var calls: [String] { lock.withLock { _calls } }

        private func enter(_ call: String) async throws {
            lock.withLock { _calls.append(call) }
            if let gate {
                await gate.wait()
            }
            if let failure {
                throw failure
            }
        }

        func commentTarget(of source: DescriptionSource) async throws -> CommentTarget {
            try await enter("target")
            return CommentTarget(kind: source.kind, id: "gid://gitlab/MergeRequest/1")
        }

        func postComment(_ body: String, to target: CommentTarget, of source: DescriptionSource, replyingTo discussionID: String?) async throws -> PostedNote {
            try await enter("post \(body) \(discussionID ?? "-")")
            var note = posted
            note.note.body = body
            return note
        }

        func editNote(_ id: String, body: String, of source: DescriptionSource) async throws -> PostedNote {
            try await enter("edit \(id)")
            return PostedNote(note: ThreadNote(id: id, author: CommentStoreTests.jane, body: body), discussionID: nil)
        }

        func deleteNote(_ id: String) async throws { try await enter("delete \(id)") }

        func setResolved(_ discussionID: String, to resolved: Bool) async throws -> Bool {
            try await enter("resolve \(resolved)")
            return resolved
        }

        func react(_ reaction: Reaction, on awardableID: String, present: Bool) async throws {
            try await enter("react \(reaction.name) \(present)")
        }

        func postDiffComment(_ body: String, at position: DiffPosition, of source: DescriptionSource, target: CommentTarget) async throws -> PostedNote {
            try await enter("diff \(body)")
            return PostedNote(note: ThreadNote(id: "gid://gitlab/Note/60", author: CommentStoreTests.jane, body: body), discussionID: "gid://gitlab/Discussion/d")
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private static func store(_ sender: FakeSender, me: String? = "jdoe") -> CommentStore {
        let counter = Counter()
        return CommentStore(sender: sender, me: me, now: { Date(timeIntervalSinceReferenceDate: 800_000_100) }, makeID: { "id\(counter.next())" })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    /// lets the tasks of the main actor run until a condition holds
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - Reply

    @Test("CMT-01 a reply shows at once as a note of mine, then GitLab's note replaces it, and a reload drops the pending one")
    func optimisticReply() async throws {
        let sender = FakeSender()
        let gate = Gate()
        sender.gate = gate
        let store = Self.store(sender)
        store.setDraft("Sure", for: Self.thread.id, in: Self.source)

        let task = Task { await store.send("Sure", to: Self.thread.id, in: Self.source) }
        await settle { sender.calls.contains("target") }

        // Not answered yet: the reply is there, local, and the draft box is empty.
        let during = store.apply(to: [Self.thread], of: Self.source)
        #expect(during[0].replies.map(\.body) == ["Their reply", "Sure"])
        #expect(during[0].replies.last?.id.hasPrefix("local-") == true && during[0].replies.last?.author?.username == "jdoe")
        #expect(store.pending(of: Self.source).first?.status == .sending)
        #expect(store.draft(for: Self.thread.id, in: Self.source) == "")

        await gate.open()
        #expect(await task.value == .done)

        let after = store.apply(to: [Self.thread], of: Self.source)
        #expect(after[0].replies.last?.id == "gid://gitlab/Note/50" && store.pending(of: Self.source).first?.isLocal == false)
        #expect(sender.calls == ["target", "post Sure gid://gitlab/Discussion/a"])

        // The reload brings the note: it shows once, and the pending one is gone.
        let loaded = CommentThread(id: Self.thread.id, first: Self.mine, replies: [Self.theirs, ThreadNote(id: "gid://gitlab/Note/50", author: Self.jane, body: "Sure")])
        #expect(store.apply(to: [loaded], of: Self.source)[0].replies.count == 2)
        store.reconcile([loaded], of: Self.source)
        #expect(store.pending(of: Self.source).isEmpty)
    }

    @Test("CMT-01 a failed reply stays with GitLab's message for Try Again, which sends it; Discard gives the text back to the box")
    func rollbackOfReply() async throws {
        let sender = FakeSender()
        sender.failure = GitLabError(.graphQLErrors(messages: ["Body is too long"]))
        let store = Self.store(sender)

        let outcome = await store.send("Long text", to: Self.thread.id, in: Self.source)

        #expect(outcome == .failed("Body is too long") && store.lastError == "Body is too long")
        let failed = try #require(store.pending(of: Self.source).first)
        #expect(failed.status == .failed("Body is too long"))
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].replies.last?.body == "Long text")

        sender.failure = nil
        #expect(await store.retry(failed.id, in: Self.source) == .done)
        #expect(store.pending(of: Self.source).first?.isLocal == false)

        sender.failure = GitLabError(.unreachable(.gitLab))
        await store.send("Again", to: Self.thread.id, in: Self.source)
        let second = try #require(store.pending(of: Self.source).last)
        store.discard(second.id, in: Self.source)
        #expect(store.draft(for: Self.thread.id, in: Self.source) == "Again")
        #expect(store.pending(of: Self.source).count == 1)
    }

    @Test("CMT-01 a new comment becomes a thread of its own; an empty text sends nothing")
    func newComment() async {
        let sender = FakeSender()
        sender.posted = PostedNote(note: ThreadNote(id: "gid://gitlab/Note/70", author: Self.jane, body: "x"), discussionID: "gid://gitlab/Discussion/n")
        let store = Self.store(sender)

        let empty = await store.send("  \n", to: nil, in: Self.source)
        let outcome = await store.send("Top level", to: nil, in: Self.source)

        #expect(empty == .refused("Write something first.") && outcome == .done)
        let threads = store.apply(to: [Self.thread], of: Self.source)
        #expect(threads.map(\.id) == [Self.thread.id, "gid://gitlab/Discussion/n"] && threads[1].first.body == "Top level")
        #expect(sender.calls == ["target", "post Top level -"])
        // Another item shows none of it.
        #expect(store.apply(to: [Self.thread], of: Self.other) == [Self.thread])
    }

    @Test("CMT-03 a comment on the diff shows as a thread with its file and line, and goes through the diff write")
    func diffComment() async {
        let sender = FakeSender()
        let store = Self.store(sender)
        let position = DiffPosition(refs: .init(baseSha: "b", headSha: "h", startSha: "s"), oldPath: "src/App.swift", newPath: "src/App.swift", oldLine: nil, newLine: 12)

        let outcome = await store.sendDiffComment("Why this?", at: position, in: Self.source)

        #expect(outcome == .done && sender.calls == ["target", "diff Why this?"])
        let threads = store.apply(to: [], of: Self.source)
        #expect(threads.first?.location == "src/App.swift:12" && threads.first?.id == "gid://gitlab/Discussion/d")
    }

    // MARK: - Mine only

    @Test("CMT-02 edit and delete are for my own notes: another's note and a note not on GitLab yet are refused without a request")
    func authorCheck() async {
        let sender = FakeSender()
        let store = Self.store(sender)
        await store.send("Local", to: Self.thread.id, in: Self.source)
        let local = ThreadNote(id: "local-id1", author: Self.jane, body: "Local")

        #expect(store.isMine(Self.mine) && !store.isMine(Self.theirs) && !store.isMine(local))
        #expect(!Self.store(sender, me: nil).isMine(Self.mine) && Self.store(sender, me: "JDOE").isMine(Self.mine))
        #expect(!store.isMine(ThreadNote(id: "x", author: nil, body: "deleted user")))
        let calls = sender.calls.count

        #expect(await store.edit(Self.theirs, to: "Changed", in: Self.source) == .refused("You can only edit your own comments."))
        #expect(await store.delete(Self.theirs, in: Self.source) == .refused("You can only delete your own comments."))
        #expect(await store.edit(local, to: "Changed", in: Self.source) != .done)
        #expect(await store.edit(Self.mine, to: "  ", in: Self.source) == .refused("A comment can't be empty. Delete it instead."))
        #expect(sender.calls.count == calls)
    }

    @Test("CMT-02 an edit shows at once and stays on success; on failure the old text is back, with the problem")
    func edit() async {
        let sender = FakeSender()
        let gate = Gate()
        sender.gate = gate
        let store = Self.store(sender)

        let task = Task { await store.edit(Self.mine, to: "Edited", in: Self.source) }
        await settle { !sender.calls.isEmpty }
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].first.body == "Edited")
        await gate.open()
        #expect(await task.value == .done)
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].first.body == "Edited")

        // The reload shows the edit: the overlay goes.
        let loaded = CommentThread(id: Self.thread.id, first: ThreadNote(id: Self.mine.id, author: Self.jane, body: "Edited"), replies: [Self.theirs])
        store.reconcile([loaded], of: Self.source)
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].first.body == "My first")

        sender.failure = GitLabError(.httpStatus(.gitLab, status: 500))
        let outcome = await store.edit(Self.mine, to: "Never", in: Self.source)
        #expect(outcome == .failed(GitLabError(.httpStatus(.gitLab, status: 500)).description))
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].first.body == "My first")
    }

    @Test("CMT-02 a deleted note leaves the thread at once and comes back on failure; deleting the first note promotes the first reply")
    func delete() async {
        let sender = FakeSender()
        let store = Self.store(sender)

        sender.failure = GitLabError(.unreachable(.gitLab))
        #expect(await store.delete(Self.mine, in: Self.source) == .failed(GitLabError(.unreachable(.gitLab)).description))
        #expect(store.apply(to: [Self.thread], of: Self.source) == [Self.thread])

        sender.failure = nil
        #expect(await store.delete(Self.mine, in: Self.source) == .done)
        let promoted = store.apply(to: [Self.thread], of: Self.source)
        #expect(promoted.count == 1 && promoted[0].first == Self.theirs && promoted[0].replies.isEmpty)

        let alone = CommentThread(id: "gid://gitlab/Discussion/solo", first: ThreadNote(id: "gid://gitlab/Note/9", author: Self.jane, body: "Solo"))
        _ = await store.delete(alone.first, in: Self.source)
        #expect(store.apply(to: [alone], of: Self.source).isEmpty)
        // The reload without the notes drops the overlay.
        store.reconcile([], of: Self.source)
        #expect(store.apply(to: [Self.thread], of: Self.source) == [Self.thread])
    }

    // MARK: - Resolve and reactions

    @Test("CMT-04 resolving shows at once and is undone on failure")
    func resolve() async {
        let sender = FakeSender()
        let store = Self.store(sender)

        #expect(await store.setResolved(Self.thread.id, to: true, in: Self.source) == .done)
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].isResolved)

        sender.failure = GitLabError(.httpStatus(.gitLab, status: 403))
        #expect(await store.setResolved(Self.thread.id, to: false, in: Self.source) != .done)
        // Back to the confirmed state, not to the loaded one.
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].isResolved)

        let loaded = CommentThread(id: Self.thread.id, first: Self.mine, replies: [Self.theirs], isResolved: true)
        store.reconcile([loaded], of: Self.source)
        #expect(store.apply(to: [Self.thread], of: Self.source)[0].isResolved == false)
    }

    @Test("CMT-06 a reaction shows at once and rolls back on failure")
    func reaction() async {
        let sender = FakeSender()
        let store = Self.store(sender)
        let id = "gid://gitlab/Note/2"

        #expect(await store.react(.thumbsUp, on: id, present: true) == .done)
        #expect(store.hasReacted(.thumbsUp, to: id) && !store.hasReacted(.heart, to: id))

        sender.failure = GitLabError(.unreachable(.gitLab))
        #expect(await store.react(.thumbsUp, on: id, present: false) != .done)
        #expect(store.hasReacted(.thumbsUp, to: id))
        #expect(sender.calls == ["react thumbsup true", "react thumbsup false"])
    }

    // MARK: - Drafts and targets

    @Test("CMT-08 an unsent reply is kept per thread and per item while the user looks at others, and forgotten when emptied")
    func drafts() {
        let store = Self.store(FakeSender())

        store.setDraft("Half a reply", for: Self.thread.id, in: Self.source)
        store.setDraft("New comment", for: nil, in: Self.source)
        store.setDraft("Other item", for: nil, in: Self.other)

        #expect(store.draft(for: Self.thread.id, in: Self.source) == "Half a reply")
        #expect(store.draft(for: nil, in: Self.source) == "New comment" && store.draft(for: nil, in: Self.other) == "Other item")
        #expect(store.draft(for: "gid://gitlab/Discussion/zzz", in: Self.source) == "")
        #expect(store.hasDraft(in: Self.source))
        store.setDraft("", for: Self.thread.id, in: Self.source)
        store.setDraft("", for: nil, in: Self.source)
        #expect(!store.hasDraft(in: Self.source) && store.hasDraft(in: Self.other))
    }

    @Test("CMT-01 the item's ids are asked once for all its writes, and again after they are forgotten")
    func targetIsKept() async {
        let sender = FakeSender()
        let store = Self.store(sender)

        await store.send("One", to: nil, in: Self.source)
        await store.send("Two", to: nil, in: Self.source)
        store.forgetTarget(of: Self.source)
        _ = await store.target(of: Self.source)

        #expect(sender.calls.filter { $0 == "target" }.count == 2)
    }
}

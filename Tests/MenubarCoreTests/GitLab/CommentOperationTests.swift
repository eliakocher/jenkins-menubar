import Foundation
import Testing

@testable import MenubarCore

/// The write operations of comments: reply, new comment, edit, delete, resolve, reactions, diff comments and review
/// drafts (CMT-01 to CMT-06). The names of mutations and fields are from GitLab's reference, never run against one.
@Suite("Comment operations")
struct CommentOperationTests {
    private static let gitLab = URL(string: "https://gitlab.example.com")!
    private static let token = "glpat-secret-token"
    private static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let mergeRequest = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)
    private static let workItem = DescriptionSource(
        kind: .workItem, reference: "group/project#31", webURL: gitLab.appending(path: "group/project/-/issues/31"), updatedAt: updatedAt)
    private static let target = CommentTarget(kind: .mergeRequest, id: "gid://gitlab/MergeRequest/4242")
    private static let refs = DiffRefs(baseSha: "base", headSha: "head", startSha: "start")

    private static func client(_ stub: StubTransport) -> GitLabClient {
        GitLabClient(transport: stub, gitLab: gitLab, token: token)
    }

    /// the request body as a dictionary, and the check that the token is only in the header
    private static func body(_ request: HTTPRequest?) throws -> [String: Any] {
        let request = try #require(request)
        #expect(request.headers["Authorization"] == "Bearer \(token)")
        #expect(request.url.absoluteString.contains(token) == false)
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains(token) == false)
        return try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private static func input(_ request: HTTPRequest?) throws -> [String: Any] {
        let variables = try #require(try body(request)["variables"] as? [String: Any])
        return try #require(variables["input"] as? [String: Any])
    }

    private static func query(_ request: HTTPRequest?) throws -> String {
        try #require(try body(request)["query"] as? String)
    }

    // MARK: - Targets

    @Test("CMT-01 the ids of a merge request come with its diffRefs; a work item's with its id only")
    func targets() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentTargetMergeRequest", body: try FixtureFiles.string("GitLab/comment-target-merge-request.json"))
        stub.answer(operation: "CommentTargetWorkItem", body: #"{"data":{"namespace":{"workItem":{"id":"gid://gitlab/WorkItem/77"}}}}"#)

        let mr = try await Self.client(stub).commentTarget(of: Self.mergeRequest)
        let item = try await Self.client(stub).commentTarget(of: Self.workItem)

        #expect(mr.id == "gid://gitlab/MergeRequest/4242" && mr.kind == .mergeRequest)
        #expect(mr.refs == DiffRefs(baseSha: String(repeating: "1", count: 40), headSha: String(repeating: "2", count: 40), startSha: String(repeating: "3", count: 40)))
        #expect(item.id == "gid://gitlab/WorkItem/77" && item.refs == nil)
        let variables = try #require(try Self.body(stub.requests(operation: "CommentTargetMergeRequest").first)["variables"] as? [String: String])
        #expect(variables == ["path": "group/project", "iid": "16"])
    }

    // MARK: - Notes

    @Test("CMT-01 a reply names the discussion and the item; a new comment names no discussion; the note comes back with its ids")
    func createNote() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentCreateNote", body: try FixtureFiles.string("GitLab/comment-note-created.json"))
        let client = Self.client(stub)

        let reply = try await client.postComment("Looks good, one question.", to: Self.target, of: Self.mergeRequest, replyingTo: "gid://gitlab/Discussion/5f1c0a")
        _ = try await client.postComment("Top level @slee", to: Self.target, of: Self.mergeRequest)

        #expect(reply.note.id == "gid://gitlab/Note/9001" && reply.discussionID == "gid://gitlab/Discussion/5f1c0a")
        #expect(reply.note.author?.username == "jdoe" && reply.note.body == "Looks good, one question.")
        #expect(reply.note.url?.absoluteString == "https://gitlab.example.com/group/project/-/merge_requests/16#note_9001")
        let requests = stub.requests(operation: "CommentCreateNote")
        let first = try Self.input(requests[0])
        #expect(first["noteableId"] as? String == "gid://gitlab/MergeRequest/4242")
        #expect(first["body"] as? String == "Looks good, one question." && first["discussionId"] as? String == "gid://gitlab/Discussion/5f1c0a")
        #expect(try Self.query(requests[0]).contains("createNote(input: $input)"))
        let second = try Self.input(requests[1])
        #expect(second["discussionId"] == nil && second["body"] as? String == "Top level @slee")
    }

    @Test("CMT-02 edit sends the note's id and the new text; delete sends the id and is true without errors")
    func editAndDelete() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentUpdateNote", body: try FixtureFiles.string("GitLab/comment-note-created.json").replacingOccurrences(of: "createNote", with: "updateNote"))
        stub.answer(operation: "CommentDestroyNote", body: #"{"data":{"destroyNote":{"errors":[]}}}"#)
        let client = Self.client(stub)

        let edited = try await client.editNote("gid://gitlab/Note/9001", body: "New text", of: Self.mergeRequest)
        try await client.deleteNote("gid://gitlab/Note/9001")

        #expect(edited.note.id == "gid://gitlab/Note/9001")
        let update = try Self.input(stub.requests(operation: "CommentUpdateNote").first)
        #expect(update["id"] as? String == "gid://gitlab/Note/9001" && update["body"] as? String == "New text")
        let destroy = try Self.input(stub.requests(operation: "CommentDestroyNote").first)
        #expect(destroy["id"] as? String == "gid://gitlab/Note/9001")
    }

    @Test("CMT-04 resolve and unresolve send the discussion and the wish; the answer says the state")
    func resolve() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentToggleResolve", body: #"{"data":{"discussionToggleResolve":{"errors":[],"discussion":{"id":"gid://gitlab/Discussion/5f1c0a","resolved":true}}}}"#)
        let client = Self.client(stub)

        let resolved = try await client.setResolved("gid://gitlab/Discussion/5f1c0a", to: true)
        try await client.setResolved("gid://gitlab/Discussion/5f1c0a", to: false)

        #expect(resolved)
        let requests = stub.requests(operation: "CommentToggleResolve")
        let on = try Self.input(requests[0])
        let off = try Self.input(requests[1])
        #expect(on["id"] as? String == "gid://gitlab/Discussion/5f1c0a" && on["resolve"] as? Bool == true)
        #expect(off["resolve"] as? Bool == false)
    }

    @Test("CMT-06 a reaction is added or taken back by its short name", arguments: [true, false])
    func reaction(add: Bool) async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentAwardEmojiAdd", body: #"{"data":{"awardEmojiAdd":{"errors":[]}}}"#)
        stub.answer(operation: "CommentAwardEmojiRemove", body: #"{"data":{"awardEmojiRemove":{"errors":[]}}}"#)

        try await Self.client(stub).react(.thumbsUp, on: "gid://gitlab/Note/9001", present: add)

        let request = try #require(stub.requests(operation: add ? "CommentAwardEmojiAdd" : "CommentAwardEmojiRemove").first)
        let input = try Self.input(request)
        #expect(input["awardableId"] as? String == "gid://gitlab/Note/9001" && input["name"] as? String == "thumbsup")
        #expect(try Self.query(request).contains(add ? "awardEmojiAdd(input: $input)" : "awardEmojiRemove(input: $input)"))
        #expect(stub.requests.count == 1)
    }

    @Test("CMT-01 an answer with errors, or with a null payload, is a failure with GitLab's words")
    func errors() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentCreateNote", body: #"{"data":{"createNote":{"errors":["Body can't be blank"],"note":null}}}"#)
        stub.answer(operation: "CommentDestroyNote", body: #"{"data":{"destroyNote":null},"errors":[{"message":"The resource that you are attempting to access does not exist or you don't have permission to perform this action"}]}"#)
        let client = Self.client(stub)

        await #expect(throws: GitLabError(.graphQLErrors(messages: ["Body can't be blank"]))) {
            try await client.postComment("", to: Self.target, of: Self.mergeRequest)
        }
        await #expect(throws: GitLabError.self) { try await client.deleteNote("gid://gitlab/Note/1") }
    }

    // MARK: - The diff

    @Test("CMT-03 a comment on one line goes by createDiffNote with the position's shas, paths and the line that exists")
    func diffNote() async throws {
        let stub = StubTransport()
        stub.answer(operation: "CommentCreateDiffNote", body: try FixtureFiles.string("GitLab/comment-note-created.json").replacingOccurrences(of: "createNote", with: "createDiffNote"))
        let added = DiffPosition(refs: Self.refs, oldPath: "src/Old.swift", newPath: "src/New.swift", oldLine: nil, newLine: 12)
        let context = DiffPosition(refs: Self.refs, oldPath: "a", newPath: "a", oldLine: 3, newLine: 4)

        let posted = try await Self.client(stub).postDiffComment("Why?", at: added, of: Self.mergeRequest, target: Self.target)
        _ = try await Self.client(stub).postDiffComment("Why?", at: context, of: Self.mergeRequest, target: Self.target)

        #expect(posted.note.id == "gid://gitlab/Note/9001")
        let requests = stub.requests(operation: "CommentCreateDiffNote")
        let first = try Self.input(requests[0])
        #expect(first["noteableId"] as? String == "gid://gitlab/MergeRequest/4242" && first["body"] as? String == "Why?")
        let position = try #require(first["position"] as? [String: Any])
        #expect(position["baseSha"] as? String == "base" && position["headSha"] as? String == "head" && position["startSha"] as? String == "start")
        #expect(position["paths"] as? [String: String] == ["oldPath": "src/Old.swift", "newPath": "src/New.swift"])
        #expect(position["newLine"] as? Int == 12 && position["oldLine"] == nil)
        let both = try #require(try Self.input(requests[1])["position"] as? [String: Any])
        #expect(both["oldLine"] as? Int == 3 && both["newLine"] as? Int == 4)
    }

    @Test("CMT-03 a comment on several lines goes by REST with the line range; GraphQL has none")
    func rangeByREST() async throws {
        let stub = StubTransport()
        stub.answer("POST", path: "/api/v4/projects/group%2Fproject/merge_requests/16/discussions", status: 201, body: """
            {"id":"abc123","notes":[{"id":555,"body":"Range","created_at":"2026-11-02T10:15:30.123Z","author":{"username":"jdoe","name":"Jane Doe"}}]}
            """)
        let range = DiffPosition.LineRange(
            start: .init(lineCode: "aa_11_11", side: nil, oldLine: 11, newLine: 11), end: .init(lineCode: "aa_13_13", side: .new, oldLine: nil, newLine: 13))
        let position = DiffPosition(refs: Self.refs, oldPath: "a", newPath: "a", oldLine: nil, newLine: 13, range: range)

        let posted = try await Self.client(stub).postDiffComment("Range", at: position, of: Self.mergeRequest, target: Self.target)

        #expect(posted.note.id == "gid://gitlab/Note/555" && posted.discussionID == "gid://gitlab/Discussion/abc123")
        #expect(stub.requests(operation: "CommentCreateDiffNote").isEmpty)
        let request = try #require(stub.requests(path: "/api/v4/projects/group%2Fproject/merge_requests/16/discussions").first)
        let json = try Self.body(request)
        #expect(json["body"] as? String == "Range")
        let sent = try #require(json["position"] as? [String: Any])
        #expect(sent["position_type"] as? String == "text" && sent["new_line"] as? Int == 13 && sent["old_line"] == nil)
        #expect(sent["base_sha"] as? String == "base" && sent["old_path"] as? String == "a")
        let lines = try #require(sent["line_range"] as? [String: [String: Any]])
        #expect(lines["start"]?["line_code"] as? String == "aa_11_11" && lines["start"]?["type"] == nil && lines["start"]?["old_line"] as? Int == 11)
        #expect(lines["end"]?["type"] as? String == "new" && lines["end"]?["new_line"] as? Int == 13)
    }

    // MARK: - Drafts

    @Test("CMT-05 a draft reply, a draft on a line, the list, an edit, a delete and Submit Review use the REST draft notes")
    func drafts() async throws {
        let base = "/api/v4/projects/group%2Fproject/merge_requests/16/draft_notes"
        let stub = StubTransport()
        stub.answer("POST", path: base, status: 201, body: #"{"id":7,"note":"Reply","in_reply_to_discussion_id":"5f1c0a"}"#)
        stub.answer("GET", path: base, body: """
            [{"id":7,"note":"Reply","in_reply_to_discussion_id":"5f1c0a"},
             {"id":8,"note":"On a line","position":{"new_path":"src/App.swift","new_line":12}}]
            """)
        stub.answer("PUT", path: base + "/7", body: #"{"id":7}"#)
        stub.answer("DELETE", path: base + "/7", status: 204)
        stub.answer("POST", path: base + "/bulk_publish", status: 204)
        let client = Self.client(stub)
        let position = DiffPosition(refs: Self.refs, oldPath: "a", newPath: "a", oldLine: nil, newLine: 12)

        let reply = try await client.addDraft("Reply", to: Self.mergeRequest, replyingTo: "gid://gitlab/Discussion/5f1c0a", resolving: true)
        _ = try await client.addDraft("On a line", to: Self.mergeRequest, at: position)
        let list = try await client.draftNotes(of: Self.mergeRequest)
        try await client.editDraft(7, body: "Changed", of: Self.mergeRequest)
        try await client.deleteDraft(7, of: Self.mergeRequest)
        try await client.publishDrafts(of: Self.mergeRequest)

        #expect(reply == DraftNote(id: 7, body: "Reply", discussionID: "gid://gitlab/Discussion/5f1c0a"))
        #expect(list.map(\.id) == [7, 8] && list[1].location == "src/App.swift:12")
        let posts = stub.requests(path: base).filter { $0.method == "POST" }
        let replyBody = try Self.body(posts[0])
        #expect(replyBody["note"] as? String == "Reply" && replyBody["in_reply_to_discussion_id"] as? String == "5f1c0a")
        #expect(replyBody["resolve_discussion"] as? Bool == true && replyBody["position"] == nil)
        #expect((try Self.body(posts[1])["position"] as? [String: Any])?["new_line"] as? Int == 12)
        #expect(try Self.body(stub.requests(path: base + "/7").first { $0.method == "PUT" })["note"] as? String == "Changed")
        #expect(stub.requests(path: base + "/bulk_publish").count == 1)
        // The requests are named for the logs, without variables: a comment's text isn't logged.
        #expect(stub.requests.allSatisfy { $0.graphQL?.variables == "{}" })
    }

    @Test("CMT-05 REST refusals: GitLab's own words for a rejected position, a rejected token, the status otherwise")
    func restRefusals() async throws {
        let base = "/api/v4/projects/group%2Fproject/merge_requests/16/draft_notes"
        let stub = StubTransport()
        stub.answer("POST", path: base, status: 400, body: #"{"message":{"position":["is invalid"]}}"#)
        stub.answer("POST", path: base + "/bulk_publish", status: 401)
        stub.answer("GET", path: base, status: 500)
        let client = Self.client(stub)

        await #expect(throws: GitLabError(.graphQLErrors(messages: ["position is invalid"]))) {
            try await client.addDraft("x", to: Self.mergeRequest)
        }
        await #expect(throws: GitLabError(.rejectedToken(.gitLab))) { try await client.publishDrafts(of: Self.mergeRequest) }
        await #expect(throws: GitLabError(.httpStatus(.gitLab, status: 500))) { try await client.draftNotes(of: Self.mergeRequest) }
    }
}

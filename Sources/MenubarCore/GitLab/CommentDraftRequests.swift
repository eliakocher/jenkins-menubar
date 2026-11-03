import Foundation

// MARK: - A review draft

/// A draft note of the user's review of a merge request: private until "Submit Review" publishes all of them (CMT-05).
public struct DraftNote: Hashable, Sendable, Identifiable {
    /// the draft's id (REST gives a number)
    public var id: Int
    public var body: String
    /// the discussion's global id when the draft is a reply
    public var discussionID: String?
    /// the file and the line of a draft on the diff, like `src/App.swift:42`
    public var location: String?

    public init(id: Int, body: String, discussionID: String? = nil, location: String? = nil) {
        self.id = id
        self.body = body
        self.discussionID = discussionID
        self.location = location
    }
}

/// GitLab's global ids and the hashes and numbers REST names the same things by.
enum GitLabID {
    /// `abc` for `gid://gitlab/Discussion/abc`; text that isn't a global id stays as it is
    static func last(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    static func discussion(_ hash: String) -> String { "gid://gitlab/Discussion/\(hash)" }

    static func note(_ number: Int) -> String { "gid://gitlab/Note/\(number)" }
}

// MARK: - REST

extension GitLabClient {
    /// Starts a thread on lines of the diff by REST: `POST /projects/:id/merge_requests/:iid/discussions` with `body`
    /// and `position`, `line_range` included (GitLab's documentation, inferred, never sent to a real GitLab). GraphQL's
    /// `createDiffNote` has no line range, which is why this is the way for a comment on several lines.
    ///
    /// - Parameters:
    ///   - position: the place on the diff
    ///   - body: the Markdown
    ///   - source: the merge request
    /// - Returns: the new thread's first note, its ids as global ids
    /// - Throws: ``GitLabError``
    public func addDiffThread(_ position: DiffPosition, body: String, to source: DescriptionSource) async throws -> PostedNote {
        let response = try await rest(
            "POST", "discussions", of: source, operation: "CommentCreateDiffThread",
            body: .object([("body", .string(body)), ("position", position.restPosition)]))
        guard let discussion = try? Self.decoder.decode(RESTDiscussion.self, from: response.body), let note = discussion.notes.first else {
            throw GitLabError(.httpStatus(.gitLab, status: 502))
        }
        let id = GitLabID.note(note.id)
        return PostedNote(
            note: ThreadNote(
                id: id, author: note.author.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") },
                body: note.body ?? body, createdAt: note.createdAt, url: NoteShape.noteURL(nil, id: id, base: source.webURL)),
            discussionID: GitLabID.discussion(discussion.id))
    }

    /// Adds a draft note to my review: `POST …/draft_notes` with `note`, and `in_reply_to_discussion_id` for a reply,
    /// `position` for a line of the diff, `resolve_discussion` (GitLab's documentation, inferred). Nobody sees it until
    /// ``publishDrafts(of:)``. GraphQL isn't used: no draft note mutation was found in GitLab's reference.
    ///
    /// - Parameters:
    ///   - body: the Markdown
    ///   - source: the merge request
    ///   - discussionID: the discussion to reply to, as a global id; `nil` for a new thread or a general note
    ///   - position: the place on the diff for a new thread on a line
    ///   - resolve: whether publishing the reply resolves the thread
    /// - Returns: the draft
    /// - Throws: ``GitLabError``
    public func addDraft(
        _ body: String, to source: DescriptionSource, replyingTo discussionID: String? = nil, at position: DiffPosition? = nil,
        resolving resolve: Bool = false
    ) async throws -> DraftNote {
        var fields: [(String, GraphQLValue)] = [("note", .string(body))]
        if let discussionID {
            fields.append(("in_reply_to_discussion_id", .string(GitLabID.last(discussionID))))
            if resolve {
                fields.append(("resolve_discussion", .bool(true)))
            }
        }
        if let position {
            fields.append(("position", position.restPosition))
        }
        let response = try await rest("POST", "draft_notes", of: source, operation: "DraftNoteCreate", body: .object(fields))
        guard let draft = try? Self.decoder.decode(RESTDraft.self, from: response.body) else {
            throw GitLabError(.httpStatus(.gitLab, status: 502))
        }
        return draft.draft
    }

    /// Lists my drafts of a merge request: `GET …/draft_notes`.
    ///
    /// - Parameter source: the merge request
    /// - Throws: ``GitLabError``
    public func draftNotes(of source: DescriptionSource) async throws -> [DraftNote] {
        let response = try await rest("GET", "draft_notes", of: source, operation: "DraftNotes", body: nil)
        guard let drafts = try? Self.decoder.decode([RESTDraft].self, from: response.body) else {
            throw GitLabError(.httpStatus(.gitLab, status: 502))
        }
        return drafts.map(\.draft)
    }

    /// Changes a draft's text: `PUT …/draft_notes/:id` with `note`.
    ///
    /// - Parameters:
    ///   - id: the draft's id
    ///   - body: the new Markdown
    ///   - source: the merge request
    /// - Throws: ``GitLabError``
    public func editDraft(_ id: Int, body: String, of source: DescriptionSource) async throws {
        _ = try await rest("PUT", "draft_notes/\(id)", of: source, operation: "DraftNoteUpdate", body: .object([("note", .string(body))]))
    }

    /// Deletes a draft: `DELETE …/draft_notes/:id`.
    ///
    /// - Parameters:
    ///   - id: the draft's id
    ///   - source: the merge request
    /// - Throws: ``GitLabError``
    public func deleteDraft(_ id: Int, of source: DescriptionSource) async throws {
        _ = try await rest("DELETE", "draft_notes/\(id)", of: source, operation: "DraftNoteDelete", body: nil)
    }

    /// Publishes all my drafts, which is "Submit Review": `POST …/draft_notes/bulk_publish` (GitLab's documentation,
    /// inferred). The user's click and nothing else sends it.
    ///
    /// - Parameter source: the merge request
    /// - Throws: ``GitLabError``
    public func publishDrafts(of source: DescriptionSource) async throws {
        _ = try await rest("POST", "draft_notes/bulk_publish", of: source, operation: "DraftNotesPublish", body: nil)
    }

    /// `<gitlab>/api/v4/projects/<path>/merge_requests/<iid>/<tail>`, the path one segment with its slashes encoded
    private func mergeRequestURL(_ tail: String, of source: DescriptionSource) throws -> URL {
        guard let (path, iid) = source.pathAndIID, var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false) else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let project = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        components.percentEncodedPath += "/projects/\(project)/merge_requests/\(iid)/\(tail)"
        guard let url = components.url else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        return url
    }

    /// Sends one REST request. The token is in the header only; the logs get the operation's name and no variables, so
    /// a comment's text isn't in them.
    private func rest(
        _ method: String, _ tail: String, of source: DescriptionSource, operation: String, body: GraphQLValue?
    ) async throws -> HTTPResponse {
        let url = try mergeRequestURL(tail, of: source)
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(
                    method: method, url: url, headers: headers, body: body.map { Data($0.json.utf8) }, timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: operation, variables: "{}")))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        guard (200..<300).contains(response.status) else {
            throw GitLabError(Self.restProblem(response))
        }
        return response
    }

    /// The problem of a refused REST request: a rejected token, or GitLab's own words for a 400, 409 or 422
    /// (`{"message": "…"}` or `{"error": "…"}`), else the status.
    static func restProblem(_ response: HTTPResponse) -> Problem {
        switch response.status {
        case 401: return .rejectedToken(.gitLab)
        case 403 where response.header("WWW-Authenticate")?.contains("insufficient_scope") == true: return .missingScope
        case 400, 403, 409, 422:
            if let text = restMessage(response.body) {
                return .graphQLErrors(messages: [text])
            }
        default: break
        }
        return .httpStatus(.gitLab, status: response.status)
    }

    private static func restMessage(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        for key in ["message", "error"] {
            if let text = object[key] as? String, !text.isEmpty {
                return text
            }
            // A validation answer: {"message": {"position": ["is invalid"]}}
            if let fields = object[key] as? [String: Any], !fields.isEmpty {
                return fields.keys.sorted().map { name in
                    let reasons = (fields[name] as? [String])?.joined(separator: ", ") ?? "\(fields[name] ?? "")"
                    return "\(name) \(reasons)"
                }.joined(separator: "; ")
            }
        }
        return nil
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle().parse(text))
                ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
        }
        return decoder
    }
}

// MARK: - REST shapes

private struct RESTDiscussion: Decodable {
    var id: String
    var notes: [Note]

    struct Note: Decodable {
        var id: Int
        var body: String?
        var createdAt: Date?
        var author: Author?

        private enum CodingKeys: String, CodingKey {
            case id, body
            case createdAt = "created_at"
            case author
        }
    }

    struct Author: Decodable {
        var username: String
        var name: String?
    }
}

private struct RESTDraft: Decodable {
    var id: Int
    var note: String?
    var discussionId: String?
    var position: Position?

    struct Position: Decodable {
        var newPath: String?
        var oldPath: String?
        var newLine: Int?
        var oldLine: Int?

        private enum CodingKeys: String, CodingKey {
            case newPath = "new_path"
            case oldPath = "old_path"
            case newLine = "new_line"
            case oldLine = "old_line"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, note, position
        case discussionId = "in_reply_to_discussion_id"
    }

    var draft: DraftNote {
        var location: String?
        if let position, let file = position.newPath ?? position.oldPath {
            location = (position.newLine ?? position.oldLine).map { "\(file):\($0)" } ?? file
        }
        return DraftNote(id: id, body: note ?? "", discussionID: discussionId.map(GitLabID.discussion), location: location)
    }
}

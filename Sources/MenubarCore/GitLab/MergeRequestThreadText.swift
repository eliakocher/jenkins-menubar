import Foundation

extension GitLabOperation where Value == [DiscussionThread] {
    /// A merge request's resolvable threads with all their notes, for "Summarize Discussion" (AI-03): 100 discussions,
    /// 50 notes each, system notes left out. Asked only on the user's click, apart from the details (MR-07), which read
    /// only each thread's first note.
    ///
    /// The query follows GitLab's GraphQL reference (`discussions`, `notes`, `system`, `position`), as the details query.
    ///
    /// - Parameter source: the merge request
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func threadText(of source: DescriptionSource) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        return GitLabOperation(
            name: "MergeRequestThreadText",
            query: """
                query MergeRequestThreadText($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequest(iid: $iid) {
                      discussions(first: 100) {
                        nodes {
                          resolvable
                          resolved
                          notes(first: 50) {
                            nodes { body system author { username name } position { filePath newPath oldPath newLine oldLine } }
                          }
                        }
                      }
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                guard let mergeRequest = try GraphQLAnswer<ThreadTextShape>.value(of: body).project?.mergeRequest else {
                    throw DecodingError.valueNotFound(
                        [DiscussionThread].self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return mergeRequest.threads
            })
    }
}

/// The shape of the answer.
struct ThreadTextShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequest: MergeRequestNode?
    }

    struct MergeRequestNode: Decodable {
        var discussions: Nodes<Discussion>?

        /// the resolvable threads with their notes; plain comments and system notes are left out
        var threads: [DiscussionThread] {
            (discussions?.nodes ?? []).filter { $0.resolvable == true }.compactMap { discussion in
                let notes = (discussion.notes?.nodes ?? []).filter { $0.system != true }
                guard let first = notes.first else {
                    return nil
                }
                var location: String?
                if let position = first.position, let file = position.filePath ?? position.newPath ?? position.oldPath,
                   !file.isEmpty {
                    location = (position.newLine ?? position.oldLine).map { "\(file):\($0)" } ?? file
                }
                return DiscussionThread(
                    resolved: discussion.resolved == true, location: location,
                    notes: notes.map { note in
                        DiscussionThread.Note(
                            author: note.author.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") },
                            body: note.body ?? "")
                    })
            }
        }
    }

    struct Discussion: Decodable {
        var resolvable: Bool?
        var resolved: Bool?
        var notes: Nodes<Note>?
    }

    struct Note: Decodable {
        var body: String?
        var system: Bool?
        var author: User?
        var position: Position?
    }

    struct User: Decodable {
        var username: String
        var name: String?
    }

    struct Position: Decodable {
        var filePath: String?
        var newPath: String?
        var oldPath: String?
        var newLine: Int?
        var oldLine: Int?
    }
}

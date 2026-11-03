import Foundation

// GitLab's To-Do List, which the Inbox is (Task 7.03, INBOX-01).
//
// Names from GitLab's schema source and docs, not yet from an answer of the user's GitLab (inferred):
// - `currentUser.todos(state: [TodoStateEnum!], isSnoozed: Boolean, first:)`, a countable connection; without
//   `isSnoozed`, the pending list leaves the snoozed to-dos out (`TodosFinder`, verified in source).
// - `Todo { id action targetType state body createdAt snoozedUntil author project targetEntity }`, `targetEntity` a
//   `Todoable` (`webUrl`, `name`); `target` is its older, deprecated twin (17.4).
// - `todoMarkDone`, `todoRestore`, `todosMarkAllDone`: input `{id: TodoID!}` (all done: `{}`), payload `errors` and
//   `todo` (`todos`).
// - `todoSnooze(input: {id: TodoID!, snoozeUntil: Time!})` and `todoUnSnooze(input: {id})`, experiments since 17.4
//   (docs). Without them the Inbox snoozes on the Mac (``InboxStore``).

/// How much of the to-do schema the GitLab answers: the full level since 17.4 (snooze, `targetEntity`), the basic
/// one before. The Inbox learns it from the first answer.
public enum TodoQueryLevel: String, Codable, Hashable, Sendable {
    /// `isSnoozed`, `snoozedUntil`, `targetEntity`
    case full
    /// `target`, no snooze
    case basic
}

/// The answer of ``GitLabOperation/inboxTodos(level:)``.
public struct InboxTodoList: Codable, Hashable, Sendable {
    /// my GitLab username, as the answer names it
    public var username: String
    /// the pending to-dos that aren't snoozed, 100 at most, in GitLab's order (newest first)
    public var pending: [InboxTodo]
    /// how many pending to-dos GitLab has, which can be more than ``pending`` holds
    public var pendingCount: Int
    /// the snoozed to-dos, 100 at most; always empty at the basic level
    public var snoozed: [InboxTodo]

    public init(username: String, pending: [InboxTodo], pendingCount: Int? = nil, snoozed: [InboxTodo] = []) {
        self.username = username
        self.pending = pending
        self.pendingCount = pendingCount ?? pending.count
        self.snoozed = snoozed
    }
}

extension GitLabOperation where Value == InboxTodoList {
    /// My pending and snoozed to-dos (INBOX-01). A 200 without `currentUser` is a rejected token (MR-05).
    ///
    /// - Parameter level: how much of the schema to ask for
    /// - Returns: the operation
    public static func inboxTodos(level: TodoQueryLevel = .full) -> GitLabOperation {
        let snoozed = level == .full ? "\n    snoozed: todos(state: [pending], isSnoozed: true, first: 100) { count nodes { ...todo } }" : ""
        return GitLabOperation(
            name: "InboxTodos",
            query: TodoShape.fragment(level) + """

                query InboxTodos {
                  currentUser {
                    username
                    pending: todos(state: [pending], first: 100) { count nodes { ...todo } }\(snoozed)
                  }
                }
                """,
            decode: { body in
                let answer = try GraphQLAnswer<InboxTodosShape>.decode(body)
                guard let user = answer.data?.currentUser else {
                    throw TodoPayloadShape.refusal(answer.errors)
                }
                return InboxTodoList(
                    username: user.username, pending: user.pending.nodes.compactMap(\.todo), pendingCount: user.pending.count,
                    snoozed: user.snoozed?.nodes.compactMap(\.todo) ?? [])
            },
            failure: { status, errors in
                if (200..<300).contains(status) {
                    return errors.isEmpty ? .rejectedToken(.gitLab) : .graphQLErrors(messages: errors)
                }
                return .httpStatus(.gitLab, status: status)
            })
    }
}

extension GitLabOperation where Value == [InboxTodo] {
    /// My done to-dos, the 50 newest, for the Inbox's Done list (INBOX-01). Asked only while it shows.
    ///
    /// - Parameter level: how much of the schema to ask for
    /// - Returns: the operation
    public static func doneTodos(level: TodoQueryLevel = .full) -> GitLabOperation {
        GitLabOperation(
            name: "InboxDoneTodos",
            query: TodoShape.fragment(level) + """

                query InboxDoneTodos {
                  currentUser { done: todos(state: [done], first: 50) { nodes { ...todo } } }
                }
                """,
            decode: { body in
                let answer = try GraphQLAnswer<DoneTodosShape>.decode(body)
                guard let user = answer.data?.currentUser else {
                    throw TodoPayloadShape.refusal(answer.errors)
                }
                return user.done.nodes.compactMap(\.todo)
            })
    }
}

extension GitLabOperation where Value == Void {
    /// Marks a to-do done in GitLab (INBOX-03).
    ///
    /// - Parameter id: the to-do's global id
    public static func todoMarkDone(id: String) -> GitLabOperation {
        todoMutation("TodoMarkDone", field: "todoMarkDone", id: id)
    }

    /// Makes a done to-do pending again in GitLab (INBOX-03).
    ///
    /// - Parameter id: the to-do's global id
    public static func todoRestore(id: String) -> GitLabOperation {
        todoMutation("TodoRestore", field: "todoRestore", id: id)
    }

    /// Snoozes a to-do in GitLab until a time (INBOX-04). A GitLab before 17.4 doesn't know it: the answer's error
    /// names `todoSnooze`.
    ///
    /// - Parameters:
    ///   - id: the to-do's global id
    ///   - until: when it wakes
    public static func todoSnooze(id: String, until: Date) -> GitLabOperation {
        let time = until.formatted(Date.ISO8601FormatStyle())
        return GitLabOperation(
            name: "TodoSnooze",
            query: """
                mutation TodoSnooze($id: TodoID!, $until: Time!) {
                  todoSnooze(input: {id: $id, snoozeUntil: $until}) { errors todo { id snoozedUntil } }
                }
                """,
            variables: .object([("id", .string(id)), ("until", .string(time))]),
            decode: { body in try TodoPayloadShape.check(body, field: "todoSnooze") })
    }

    /// Wakes a snoozed to-do in GitLab (INBOX-04).
    ///
    /// - Parameter id: the to-do's global id
    public static func todoUnSnooze(id: String) -> GitLabOperation {
        todoMutation("TodoUnSnooze", field: "todoUnSnooze", id: id, fields: "id snoozedUntil")
    }

    private static func todoMutation(_ name: String, field: String, id: String, fields: String = "id state") -> GitLabOperation {
        GitLabOperation(
            name: name,
            query: """
                mutation \(name)($id: TodoID!) {
                  \(field)(input: {id: $id}) { errors todo { \(fields) } }
                }
                """,
            variables: .object([("id", .string(id))]),
            decode: { body in try TodoPayloadShape.check(body, field: field) })
    }
}

extension GitLabOperation where Value == [String] {
    /// Marks all my pending to-dos done in GitLab (INBOX-03); the snoozed ones stay (inferred from `TodosFinder`,
    /// which leaves them out of the pending ones).
    ///
    /// - Returns: the operation, whose value is the ids GitLab marked done
    public static var todosMarkAllDone: GitLabOperation {
        GitLabOperation(
            name: "TodosMarkAllDone",
            query: """
                mutation TodosMarkAllDone {
                  todosMarkAllDone(input: {}) { errors todos { id } }
                }
                """,
            decode: { body in
                let payload = try TodoPayloadShape.payload(body, field: "todosMarkAllDone")
                return payload.todos?.map(\.id) ?? []
            })
    }
}

extension GitLabError {
    /// Whether GitLab refused a to-do field or argument it doesn't have, like `isSnoozed` before 17.4: the Inbox asks
    /// at the basic level then.
    var namesMissingTodoField: Bool {
        guard case .graphQLErrors(let messages) = problem else {
            return false
        }
        return messages.contains { message in
            ["isSnoozed", "snoozedUntil", "targetEntity"].contains { message.contains($0) }
        }
    }

    /// Whether GitLab doesn't know the snooze mutations: the Inbox snoozes on the Mac then.
    var namesMissingSnooze: Bool {
        guard case .graphQLErrors(let messages) = problem else {
            return false
        }
        return messages.contains { $0.contains("todoSnooze") || $0.contains("todoUnSnooze") }
    }
}

// MARK: - Decoding

/// One to-do as GitLab sends it.
struct TodoShape: Decodable {
    var id: String
    var action: String
    var targetType: String
    var state: String?
    var body: String?
    var createdAt: Date
    var snoozedUntil: Date?
    var author: Person?
    var project: Project?
    var targetEntity: Target?
    var target: Target?

    struct Person: Decodable {
        var username: String
        var name: String?
    }

    struct Project: Decodable {
        var fullPath: String
    }

    struct Target: Decodable {
        var webUrl: String?
        var name: String?
        var iid: String?
        var reference: String?
    }

    /// The fields of a to-do, as a fragment named `todo`.
    static func fragment(_ level: TodoQueryLevel) -> String {
        let target = level == .full ? "targetEntity" : "target"
        let snooze = level == .full ? "\n  snoozedUntil" : ""
        return """
            fragment todo on Todo {
              id
              action
              targetType
              state
              body
              createdAt\(snooze)
              author { username name }
              project { fullPath }
              \(target) {
                webUrl
                name
                ... on MergeRequest { iid reference(full: true) }
                ... on Issue { iid reference(full: true) }
                ... on WorkItem { iid reference(full: true) }
              }
            }
            """
    }

    /// the to-do; `nil` for one without an id
    var todo: InboxTodo? {
        guard !id.isEmpty else {
            return nil
        }
        let target = targetEntity ?? target
        let body = body ?? ""
        return InboxTodo(
            id: id, action: .init(rawValue: action), targetKind: .init(rawValue: targetType),
            state: state.flatMap(InboxTodo.State.init(rawValue:)) ?? .pending,
            title: target?.name ?? (body.isEmpty ? "Untitled" : body), body: body,
            targetURL: target?.webUrl.flatMap { URL(string: $0) }, reference: target?.reference,
            iid: target?.iid.flatMap { Int($0) }, projectPath: project?.fullPath,
            author: author.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") }, createdAt: createdAt,
            snoozedUntil: snoozedUntil)
    }
}

private struct InboxTodosShape: Decodable {
    var currentUser: User?

    struct User: Decodable {
        var username: String
        var pending: List
        var snoozed: List?
    }

    struct List: Decodable {
        var count: Int
        var nodes: [TodoShape]

        private enum Key: String, CodingKey {
            case count, nodes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            count = (try? container.decode(Int.self, forKey: .count)) ?? 0
            nodes = try Nodes<TodoShape>(from: decoder).nodes
            if count < nodes.count {
                count = nodes.count
            }
        }
    }
}

private struct DoneTodosShape: Decodable {
    var currentUser: User?

    struct User: Decodable {
        var done: Nodes<TodoShape>
    }
}

/// The payload of a to-do mutation: `{errors, todo}` or `{errors, todos}`.
private struct TodoPayloadShape: Decodable {
    var errors: [String]?
    var todos: [Todo]?

    struct Todo: Decodable {
        var id: String
    }

    static func payload(_ body: Data, field: String) throws -> TodoPayloadShape {
        let answer = try GraphQLAnswer<[String: TodoPayloadShape?]>.decode(body)
        guard let payload = answer.data?[field] ?? nil else {
            if let errors = answer.errors, !errors.isEmpty {
                throw GitLabError(.graphQLErrors(messages: errors.map(\.message)))
            }
            throw DecodingError.valueNotFound(TodoPayloadShape.self, .init(codingPath: [], debugDescription: "no \(field)"))
        }
        if let errors = payload.errors, !errors.isEmpty {
            throw GitLabError(.graphQLErrors(messages: errors))
        }
        return payload
    }

    /// The error of an answer without the signed-in user: GitLab's errors when it sent some, like an unknown field of
    /// an older GitLab, otherwise a rejected token (MR-05).
    static func refusal<Shape>(_ errors: [GraphQLAnswer<Shape>.Message]?) -> GitLabError {
        guard let errors, !errors.isEmpty else {
            return GitLabError(.rejectedToken(.gitLab))
        }
        return GitLabError(.graphQLErrors(messages: errors.map(\.message)))
    }

    static func check(_ body: Data, field: String) throws {
        _ = try payload(body, field: field)
    }
}

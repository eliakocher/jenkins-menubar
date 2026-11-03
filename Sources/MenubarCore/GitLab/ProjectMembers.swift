import Foundation
import Observation

/// A member of a project, for the @-mention autocomplete of the comment box (CMT-07).
public struct ProjectMember: Codable, Hashable, Sendable, Identifiable {
    public var username: String
    public var name: String
    /// whether the account is active; a blocked or deactivated user isn't offered
    public var isActive: Bool

    public init(username: String, name: String, isActive: Bool = true) {
        self.username = username
        self.name = name
        self.isActive = isActive
    }

    public var id: String { username }
}

/// One page of a project's members.
struct ProjectMembersPage: Sendable {
    var members: [ProjectMember]
    /// the cursor of the next page; `nil` on the last
    var next: String?
}

extension GitLabOperation where Value == ProjectMembersPage {
    /// A page of a project's members, 100 at a time, with the groups' members it inherits (CMT-07).
    ///
    /// `Project.projectMembers(first:after:)` with `ProjectMember.user { username name state }` is from GitLab's
    /// GraphQL reference (inferred, never run against a GitLab by the author); without `relations` it lists the direct
    /// and the inherited members.
    ///
    /// - Parameters:
    ///   - project: the project's full path
    ///   - after: the cursor of the page before
    static func projectMembers(project: String, after: String? = nil) -> GitLabOperation {
        GitLabOperation(
            name: "ProjectMembers",
            query: """
                query ProjectMembers($path: ID!, $after: String) {
                  project(fullPath: $path) {
                    projectMembers(first: 100, after: $after) {
                      pageInfo { hasNextPage endCursor }
                      nodes { user { username name state } }
                    }
                  }
                }
                """,
            variables: .object([("path", .string(project)), ("after", after.map { .string($0) } ?? .null)]),
            decode: { body in
                guard let connection = try GraphQLAnswer<MembersShape>.value(of: body).project?.projectMembers else {
                    throw DecodingError.valueNotFound(
                        ProjectMembersPage.self, .init(codingPath: [], debugDescription: "no project"))
                }
                let members = connection.nodes.nodes.compactMap { node -> ProjectMember? in
                    guard let user = node.user else {
                        return nil
                    }
                    return ProjectMember(
                        username: user.username, name: user.name ?? "", isActive: user.state == nil || user.state?.lowercased() == "active")
                }
                return ProjectMembersPage(members: members, next: connection.pageInfo?.hasNextPage == true ? connection.pageInfo?.endCursor : nil)
            })
    }
}

private struct MembersShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var projectMembers: Connection?
    }

    struct Connection: Decodable {
        var pageInfo: PageInfo?
        var nodes: Nodes<Member>

        private enum Key: String, CodingKey {
            case pageInfo
        }

        init(from decoder: any Decoder) throws {
            pageInfo = try decoder.container(keyedBy: Key.self).decodeIfPresent(PageInfo.self, forKey: .pageInfo)
            nodes = try Nodes(from: decoder)
        }
    }

    struct PageInfo: Decodable {
        var hasNextPage: Bool?
        var endCursor: String?
    }

    struct Member: Decodable {
        var user: User?
    }

    struct User: Decodable {
        var username: String
        var name: String?
        var state: String?
    }
}

extension GitLabClient {
    /// The most pages of members one load reads: 500 members, which is more than a project's comment box offers.
    static let memberPages = 5

    /// Reads a project's members, page after page up to ``memberPages``.
    ///
    /// - Parameter project: the project's full path
    /// - Returns: the members in GitLab's order
    /// - Throws: ``GitLabError``
    public func projectMembers(of project: String) async throws -> [ProjectMember] {
        var members: [ProjectMember] = []
        var cursor: String?
        for _ in 0..<Self.memberPages {
            let page = try await send(.projectMembers(project: project, after: cursor))
            members += page.members
            guard let next = page.next else {
                break
            }
            cursor = next
        }
        return members
    }
}

// MARK: - Matching

/// Finds the members a typed `@…` names, and finishes the mention (CMT-07).
public enum MentionMatcher {
    /// An `@` with the letters after it, at the cursor.
    public struct Trigger: Hashable, Sendable {
        /// the text after the `@`, maybe empty
        public var query: String
        /// the `@` and the query, which the chosen member replaces
        public var range: Range<String.Index>

        public init(query: String, range: Range<String.Index>) {
            self.query = query
            self.range = range
        }
    }

    /// Returns the mention being typed at the cursor: an `@` that starts the text or follows a space, a bracket or a
    /// quote (not a letter: `jane@example.com` is no mention), and the username characters after it.
    ///
    /// - Parameters:
    ///   - text: the comment
    ///   - cursor: the insertion point
    /// - Returns: the trigger, or `nil` when the cursor isn't in a mention
    public static func trigger(in text: String, cursor: String.Index) -> Trigger? {
        var index = cursor
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "@" {
                if previous > text.startIndex {
                    let before = text[text.index(before: previous)]
                    guard !(before.isLetter || before.isNumber || before == "." || before == "_" || before == "-" || before == "@") else {
                        return nil
                    }
                }
                return Trigger(query: String(text[index..<cursor]), range: previous..<cursor)
            }
            guard isUsernameCharacter(character) else {
                return nil
            }
            index = previous
        }
        return nil
    }

    /// Finishes a mention: the trigger's `@…` becomes `@username ` and the cursor goes behind it.
    ///
    /// - Parameters:
    ///   - member: the chosen member
    ///   - trigger: the mention being typed
    ///   - text: the comment
    /// - Returns: the new text and where the cursor goes, as an offset in characters
    public static func complete(_ member: ProjectMember, replacing trigger: Trigger, in text: String) -> (text: String, cursor: Int) {
        let mention = "@\(member.username) "
        var result = text
        result.replaceSubrange(trigger.range, with: mention)
        let start = text.distance(from: text.startIndex, to: trigger.range.lowerBound)
        return (result, start + mention.count)
    }

    /// Returns the members that fit what was typed, best first: a username that starts with it, then a name that starts
    /// with it, then a name with a word that does. Case and accents don't count. Inactive users, bots and `ghost` are
    /// left out; without anything typed the first ones by username come back.
    ///
    /// - Parameters:
    ///   - query: the text after the `@`
    ///   - members: the project's members
    ///   - limit: the most to return
    public static func matches(_ query: String, in members: [ProjectMember], limit: Int = 8) -> [ProjectMember] {
        let needle = fold(query)
        let ranked: [(rank: Int, member: ProjectMember)] = members.compactMap { member in
            guard member.isActive, !isBot(member.username) else {
                return nil
            }
            guard !needle.isEmpty else {
                return (0, member)
            }
            let username = fold(member.username)
            let name = fold(member.name)
            if username.hasPrefix(needle) {
                return (0, member)
            }
            if name.hasPrefix(needle) {
                return (1, member)
            }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) {
                return (2, member)
            }
            return nil
        }
        return ranked.sorted { ($0.rank, $0.member.username) < ($1.rank, $1.member.username) }.prefix(limit).map(\.member)
    }

    private static func isUsernameCharacter(_ character: Character) -> Bool {
        (character.isASCII && (character.isLetter || character.isNumber)) || character == "." || character == "_" || character == "-"
    }

    private static func isBot(_ username: String) -> Bool {
        let name = username.lowercased()
        return name == "ghost" || name.hasSuffix("-bot") || name.hasSuffix("_bot") || (name.contains("_bot_") && name.hasPrefix("project_"))
            || (name.contains("_bot_") && name.hasPrefix("group_"))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - The store

/// The members of the projects the user comments in, for the autocomplete: asked once, kept in memory and on disk for a
/// day (Task 7.06's policy for what rarely changes), asked again after that (CMT-07).
@Observable @MainActor
public final class ProjectMembersStore {
    /// how long the members stay as they are: 24 hours
    public static let lifetime: TimeInterval = 24 * 3600
    private static let kind = DetailKind<[ProjectMember]>("projectMembers")

    @ObservationIgnored private var members: [String: (list: [ProjectMember], loadedAt: Date)] = [:]
    @ObservationIgnored private var loading: [String: Task<[ProjectMember]?, Never>] = [:]
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns the members known now, without asking anything: from memory, else from the disk.
    ///
    /// - Parameter project: the project's full path
    public func known(of project: String) -> [ProjectMember] {
        if let held = members[project] {
            return held.list
        }
        guard let entry = services.details?.load(Self.kind, key: project) else {
            return []
        }
        members[project] = (entry.value, entry.savedAt)
        return entry.value
    }

    /// Returns a project's members: the kept ones while they are younger than ``lifetime``, else GitLab's. Several
    /// calls at once ask once. A failed request leaves the older members, or none.
    ///
    /// - Parameter project: the project's full path
    public func load(_ project: String) async -> [ProjectMember] {
        let current = known(of: project)
        if let loadedAt = members[project]?.loadedAt, services.now().timeIntervalSince(loadedAt) < Self.lifetime {
            return current
        }
        if let running = loading[project] {
            return await running.value ?? current
        }
        let services = services
        let task = Task<[ProjectMember]?, Never> {
            guard let client = try? await services.session().get().client else {
                return nil
            }
            return try? await client.projectMembers(of: project)
        }
        loading[project] = task
        let loaded = await task.value
        loading[project] = nil
        guard let loaded else {
            return current
        }
        members[project] = (loaded, services.now())
        services.details?.save(loaded, updatedAt: nil, as: Self.kind, key: project)
        return loaded
    }
}

import Foundation

/// The rules of the window's "In GitLab" search (WIN-07): what a search text asks for, where GitLab is asked, and how the
/// answer is put in order. Pure, so the tests and the store share them.
public enum GitLabSearchRules {
    /// the fewest characters of a text that is searched for
    public static let minimumCharacters = 3
    /// how long the search waits after the last keystroke
    public static let pause: Duration = .milliseconds(400)
    /// how long an answer is reused for the same text
    public static let cachedFor: TimeInterval = 300
    /// how many results are shown
    public static let limit = 20

    /// What a search text asks for.
    public enum Intent: Hashable, Sendable {
        /// nothing: the text is empty or too short
        case none
        /// one item by its reference or link: a direct hit, found without asking GitLab
        case reference(LinkRoute)
        /// the text, to find in titles
        case text(String)
    }

    /// Reads a search text.
    ///
    /// - A link, `!123`, `#123` or `group/project!123` is one item (``OpenByLink``), whatever the section.
    /// - Any other text of at least ``minimumCharacters`` is searched for.
    ///
    /// - Parameters:
    ///   - text: what is in the search field
    ///   - projects: the team's projects, whose GitLab instances a link must be on
    ///   - defaultProject: the project of `!123` and `#123`
    /// - Returns: what to do
    public static func intent(for text: String, projects: [Project], defaultProject: String) -> Intent {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .success(let route) = OpenByLink.parse(text, projects: projects, defaultProject: defaultProject) {
            return .reference(route)
        }
        return text.count >= minimumCharacters ? .text(text) : .none
    }

    /// Returns where GitLab is asked: the groups of the projects (the path without its last part, with their subgroups)
    /// and the slot group, and the projects themselves, which covers a project in a personal namespace.
    ///
    /// - Parameter projects: the team's projects
    /// - Returns: the group paths and the project paths, each once and in the order of the projects; both empty without a
    ///   GitLab project in Team
    public static func scopes(of projects: [Project]) -> (groups: [String], projects: [String]) {
        var groups: [String] = []
        var paths: [String] = []
        func add(_ path: String, to list: inout [String]) {
            let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if !path.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                list.append(path)
            }
        }
        for project in projects {
            let path = project.team.gitLabProject.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !path.isEmpty else { continue }
            add(path, to: &paths)
            if let slash = path.lastIndex(of: "/") {
                add(String(path[..<slash]), to: &groups)
            }
            add(project.team.slotGroup, to: &groups)
        }
        return (groups, paths)
    }

    /// Puts the hits in order and keeps the best: open ones first, then the most recently updated, each item once.
    ///
    /// - Parameters:
    ///   - hits: the hits of all scopes
    ///   - limit: how many to keep
    /// - Returns: the hits
    public static func ordered(_ hits: [GitLabSearchHit], limit: Int = limit) -> [GitLabSearchHit] {
        var seen = Set<String>()
        let unique = hits.filter { seen.insert($0.id).inserted }
        return Array(
            unique.sorted { ($0.isOpen ? 0 : 1, $1.updatedAt) < ($1.isOpen ? 0 : 1, $0.updatedAt) }.prefix(limit))
    }

    /// Leaves out the hits that the list shows already.
    ///
    /// - Parameters:
    ///   - hits: the hits
    ///   - shown: the references of the rows the list shows, like `group/project!12`, in any case
    /// - Returns: the hits that are not in the list
    public static func leavingOut(shown: some Sequence<String>, from hits: [GitLabSearchHit]) -> [GitLabSearchHit] {
        let shown = Set(shown.map { $0.lowercased() })
        return hits.filter { !shown.contains($0.id) }
    }
}

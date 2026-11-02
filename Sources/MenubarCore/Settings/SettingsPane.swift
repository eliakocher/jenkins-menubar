import Foundation

/// The panes of the Settings window's sidebar, in their order (SET-02), as System Settings groups them: the app's own
/// look and behavior, the connection and the team's values, the sections' settings, and Advanced last.
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case general
    case notifications
    case appearance
    case accounts
    case projects
    /// the team's shared values: labels, the slot schedule, squads, and the team file
    case team
    case pipelines
    case workItems
    /// the folders of the local checkouts, the Open in IDE command and the terminal (WS-01)
    case workspaces
    case claude
    case advanced

    /// the pane Work Items' filters live in, under its name before the redesign
    public static let gitLab = SettingsPane.workItems
    /// the pane the checkouts' folders live in, under its name before the redesign
    public static let repositories = SettingsPane.workspaces
    /// the pane the check interval and the hide rules live in, under its name before the redesign
    public static let jenkins = SettingsPane.pipelines

    /// The sidebar's groups, in their order, each a short list of panes.
    public static let groups: [[SettingsPane]] = [
        [.general, .notifications, .appearance],
        [.accounts, .projects, .team],
        [.pipelines, .workItems, .workspaces, .claude],
        [.advanced],
    ]

    /// the sidebar's and the window's title
    public var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .accounts: "Accounts"
        case .projects: "Projects"
        case .team: "Team"
        case .pipelines: "Pipelines"
        case .workItems: "Work Items"
        case .workspaces: "Workspaces"
        case .claude: "Claude"
        case .advanced: "Advanced"
        }
    }

    /// what the pane holds, in a few words, for the search: titles of its settings and the words people may type
    public var keywords: [String] {
        switch self {
        case .general:
            ["login", "start", "menu bar", "icon", "shortcut", "hotkey", "links", "browser", "copied link", "paste",
             "easter eggs", "butler"]
        case .notifications:
            ["alert", "banner", "stage", "sound", "notification", "slot", "code freeze", "warning", "preview", "mute",
             "muted"]
        case .appearance:
            ["width", "content width", "text size", "reading size", "font", "diff", "side by side", "inline",
             "comments", "sort", "folders", "folded", "layout"]
        case .accounts:
            ["token", "keychain", "sign in", "signed in", "jenkins", "gitlab", "url", "server", "user", "check"]
        case .projects:
            ["project", "jenkins job", "job url", "gitlab project", "add project", "remove project"]
        case .team:
            ["team file", "import", "export", "label", "committed", "in progress", "status", "type", "prefix",
             "slot", "release", "code freeze", "early access", "weekday", "squad", "capacity", "planning", "group",
             "cascade", "shared", "teams", "members", "work days", "blocked", "size", "priority", "commitment", "due"]
        case .pipelines:
            ["jenkins", "check every", "interval", "hide", "successful", "failed", "merged", "builds"]
        case .workItems:
            ["filters", "labels", "assigned", "scope", "type", "state", "sort", "limit", "must have"]
        case .workspaces:
            ["repositories", "folders", "checkouts", "ide", "editor", "terminal", "base branch"]
        case .claude:
            ["ai", "model", "effort", "opus", "sonnet", "haiku", "digest", "mcp", "claude.md", "setup"]
        case .advanced:
            ["cache", "data age", "gitlab data", "welcome", "back up", "backup", "export my settings", "reset"]
        }
    }

    /// Returns whether the pane matches what was typed in the sidebar's search: its title or one of its keywords
    /// contains every word, ignoring case and diacritics.
    ///
    /// - Parameter query: the search text; empty matches every pane
    /// - Returns: whether the sidebar lists the pane
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Returns the pane of a name: a case's raw value in any case, or a name from before the redesign (`jenkins`,
    /// `gitLab`, `repositories`), as the stored last pane and older `menubar-monitor://settings/<pane>` links have it.
    ///
    /// - Parameter name: the name
    /// - Returns: the pane, or nil for a name no pane ever had
    public init?(name: String) {
        let lowercased = name.lowercased()
        if let pane = Self.allCases.first(where: { $0.rawValue.lowercased() == lowercased }) {
            self = pane
            return
        }
        switch lowercased {
        case "jenkins": self = .pipelines
        case "gitlab": self = .workItems
        case "repositories": self = .workspaces
        default: return nil
        }
    }

    /// Returns the pane a problem row or link opens: Accounts for a token or the GitLab URL, Projects for the Jenkins
    /// job and the GitLab project.
    ///
    /// - Parameter problem: the problem of the row
    /// - Returns: the pane, or nil when no setting fixes the problem
    public static func pane(for problem: Problem) -> SettingsPane? {
        switch problem {
        case .noToken, .rejectedToken, .missingScope: .accounts
        case .teamValuesMissing, .unknownJob: .projects
        // A server that fails, and any case added later, is nothing a setting fixes.
        default: nil
        }
    }
}

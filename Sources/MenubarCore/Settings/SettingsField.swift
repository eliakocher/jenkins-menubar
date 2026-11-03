import Foundation

/// A single setting a link, a button or the Settings search can open Settings at: the pane it lives in, the title its
/// row says, and the words people may type for it. The views mark the rows with `settingsAnchor(_:)`.
public enum SettingsField: String, CaseIterable, Hashable, Sendable {
    // General
    case openAtLogin
    case linkRouting
    // Shortcuts
    case shortcut
    case sidebarShortcut
    case resetShortcuts
    // Menu Bar
    case showInMenuBar
    case menuBarIcon
    case menuBarParts
    case menuPaneRows
    case menuPaneWidth
    // Notifications
    case buildAlerts
    case mutedJobs
    case slotWarning
    case inboxNotifications
    case coffeeBreak
    case inboxGroupOrder
    // Appearance
    case appearance
    case contentWidth
    case textSize
    case diffLayout
    case discussions
    case sidebarOrder
    // Accounts
    case gitLabURL
    case gitLabToken
    case jenkinsToken
    case accountCheck
    // Projects
    case projects
    case jenkinsJob
    // Team
    case teamFile
    case labels
    case slotSchedule
    case slotPlanning
    case squads
    // Pipelines
    case checkInterval
    case hideBuilds
    // Work Items
    case workItemFilters
    case workItemLabels
    case workItemRowLabels
    // Workspaces
    case repositoryFolders
    case ideCommand
    case terminal
    // Claude
    case claude
    case claudeModel
    case claudeSetup
    case morningDigest
    // Advanced
    case gitLabDataAge
    case backup
    case welcome

    /// the pane the field lives in
    public var pane: SettingsPane {
        switch self {
        case .openAtLogin, .linkRouting: .general
        case .shortcut, .sidebarShortcut, .resetShortcuts: .shortcuts
        case .showInMenuBar, .menuBarIcon, .menuBarParts, .menuPaneRows, .menuPaneWidth: .menuBar
        case .buildAlerts, .mutedJobs, .slotWarning, .inboxNotifications, .coffeeBreak, .inboxGroupOrder: .notifications
        case .appearance, .contentWidth, .textSize, .diffLayout, .discussions, .sidebarOrder: .appearance
        case .gitLabURL, .gitLabToken, .jenkinsToken, .accountCheck: .accounts
        case .projects, .jenkinsJob: .projects
        case .teamFile, .labels, .slotSchedule, .slotPlanning, .squads: .team
        case .checkInterval, .hideBuilds: .pipelines
        case .workItemFilters, .workItemLabels, .workItemRowLabels: .workItems
        case .repositoryFolders, .ideCommand, .terminal: .workspaces
        case .claude, .claudeModel, .claudeSetup, .morningDigest: .claude
        case .gitLabDataAge, .backup, .welcome: .advanced
        }
    }

    /// the title the field's row says, as the search lists it and the gear button's help names it
    public var title: String {
        switch self {
        case .openAtLogin: "Open at login"
        case .showInMenuBar: "Show in menu bar"
        case .menuBarIcon: "Menu bar icon"
        case .menuBarParts: "What the menu bar shows"
        case .menuPaneRows: "Rows of the menu"
        case .menuPaneWidth: "Menu width"
        case .shortcut: "Open MegaMonitor (anywhere)"
        case .sidebarShortcut: "Toggle Sidebar shortcut"
        case .resetShortcuts: "Reset all shortcuts"
        case .linkRouting: "Open GitLab and Jenkins links in MegaMonitor"
        case .buildAlerts: "Build alerts and previews"
        case .mutedJobs: "Which builds alert"
        case .slotWarning: "Warn before a code freeze"
        case .inboxNotifications: "What lands in the Inbox"
        case .coffeeBreak: "Coffee break"
        case .inboxGroupOrder: "Order of the Inbox groups"
        case .appearance: "Appearance"
        case .contentWidth: "Content width"
        case .textSize: "Text size"
        case .diffLayout: "Code changes layout"
        case .discussions: "Discussions order"
        case .sidebarOrder: "Order of the sidebar"
        case .gitLabURL: "GitLab server"
        case .gitLabToken: "GitLab token"
        case .jenkinsToken: "Jenkins token"
        case .accountCheck: "Check accounts"
        case .projects: "Watched projects"
        case .jenkinsJob: "Jenkins job"
        case .teamFile: "Team file"
        case .labels: "Labels"
        case .slotSchedule: "Slot schedule"
        case .slotPlanning: "Slot planning"
        case .squads: "Squads"
        case .checkInterval: "Check Jenkins every"
        case .hideBuilds: "Hide finished builds"
        case .workItemFilters: "Work item filters"
        case .workItemLabels: "Work item labels"
        case .workItemRowLabels: "Labels on rows"
        case .repositoryFolders: "Repository folders"
        case .ideCommand: "Open in IDE"
        case .terminal: "Terminal"
        case .claude: "Use Claude"
        case .claudeModel: "Default model"
        case .claudeSetup: "Use my Claude Code setup"
        case .morningDigest: "Morning digest"
        case .gitLabDataAge: "Reload GitLab data older than"
        case .backup: "Back up my settings"
        case .welcome: "Show the welcome flow again"
        }
    }

    /// the words people may type for the field, besides its title
    public var keywords: [String] {
        switch self {
        case .openAtLogin: ["login", "start", "startup", "launch", "boot"]
        case .showInMenuBar: ["menu bar", "hide", "status item", "icon"]
        case .menuBarIcon: ["menu bar", "icon", "butler", "color", "colour", "monochrome", "style"]
        case .menuBarParts: ["counts", "running", "failed", "unstable", "successful", "passed", "problem", "inbox", "dot", "red dot", "badge", "number", "review", "merge requests", "slot", "freeze", "countdown", "order", "drag", "zero"]
        case .menuPaneRows: ["pane", "menu", "rows", "flyout", "order", "drag", "pipelines", "inbox", "merge requests", "work items", "entries"]
        case .menuPaneWidth: ["width", "compact", "regular", "wide", "pane", "menu"]
        case .shortcut: ["hotkey", "keyboard", "global", "shortcut", "key", "anywhere", "open window"]
        case .sidebarShortcut: ["sidebar", "toggle", "keyboard", "shortcut", "⌘S", "cmd s", "show sidebar", "hide sidebar", "key"]
        case .resetShortcuts: ["reset", "default", "defaults", "restore", "keyboard", "shortcuts", "keys", "rebind"]
        case .linkRouting: ["links", "browser", "route", "gitlab", "jenkins", "hold option"]
        case .buildAlerts: ["alert", "banner", "window", "notification", "sound", "stage", "preview"]
        case .mutedJobs: ["mute", "muted", "quiet", "my builds", "watched builds", "job", "notify"]
        case .slotWarning: ["slot", "code freeze", "warning", "committed", "merge request"]
        case .inboxNotifications: ["inbox", "badge", "dot", "menu bar", "mention", "assigned", "review", "approved", "merged", "digest", "claude", "answer", "failed build", "when a build finishes", "alert window", "finished build", "to-do", "todo", "unread", "only my projects", "notification", "delivery", "big panel", "panel", "desktop notification", "banner", "popup"]
        case .coffeeBreak: ["coffee", "break", "haiku", "daily", "08:59", "joke", "fun", "time", "reminder", "inbox"]
        case .inboxGroupOrder: ["inbox", "order", "groups", "reorder", "drag", "move", "my to-dos", "coffee", "claude", "mentions", "builds", "reset"]
        case .appearance: ["dark mode", "light mode", "dark", "light", "automatic", "system", "theme", "night", "colors", "colours"]
        case .contentWidth: ["width", "wide", "narrow", "cards", "window"]
        case .textSize: ["reading size", "font", "bigger", "smaller", "descriptions", "comments"]
        case .diffLayout: ["diff", "side by side", "inline", "layout", "folders", "folded"]
        case .discussions: ["comments", "sort", "threads", "open first", "order"]
        case .sidebarOrder: ["sidebar", "sections", "tabs", "order", "reorder", "drag", "move", "pipelines", "merge requests", "digest", "reset"]
        case .gitLabURL: ["url", "server", "host", "gitlab", "address"]
        case .gitLabToken: ["token", "keychain", "api", "scope", "sign in", "gitlab", "password"]
        case .jenkinsToken: ["token", "keychain", "api", "sign in", "jenkins", "user", "password"]
        case .accountCheck: ["check", "signed in", "who", "account", "verify", "token"]
        case .projects: ["project", "add project", "remove project", "list", "watch"]
        case .jenkinsJob: ["job", "job url", "jenkins", "gitlab project", "path"]
        case .teamFile: ["import", "export", "share", "team", "file", "json"]
        case .labels: ["label", "committed", "in progress", "status", "type", "prefix", "colors"]
        case .slotSchedule: ["slot", "release", "weekday", "code freeze", "early access", "schedule", "day"]
        case .slotPlanning: ["slot", "planning", "cascade", "capacity", "group"]
        case .squads: ["squad", "team", "capacity", "members"]
        case .checkInterval: ["interval", "check every", "poll", "jenkins", "refresh", "seconds", "minutes"]
        case .hideBuilds: ["hide", "successful", "failed", "merged", "finished", "builds"]
        case .workItemFilters: ["filters", "assigned", "scope", "type", "state", "sort", "limit", "must have"]
        case .workItemLabels: ["labels", "label", "filter", "must have", "pills"]
        case .workItemRowLabels: ["labels", "label", "hide", "hidden", "scoped", "scope", "prefix", "value only", "rows", "pills"]
        case .repositoryFolders: ["repositories", "folders", "checkouts", "base branch", "local", "clone"]
        case .ideCommand: ["ide", "editor", "command", "open in ide", "intellij", "vs code"]
        case .terminal: ["terminal", "iterm", "shell", "console", "default terminal"]
        case .claude: ["ai", "claude code", "enable", "switch", "explain"]
        case .claudeModel: ["model", "effort", "opus", "sonnet", "haiku", "thinking"]
        case .claudeSetup: ["setup", "skills", "plugins", "mcp", "claude.md", "servers", "tokens"]
        case .morningDigest: ["digest", "morning", "summary", "notification", "time"]
        case .gitLabDataAge: ["cache", "data age", "reload", "gitlab data", "stale", "check now"]
        case .backup: ["back up", "backup", "export", "import", "settings", "reset", "restore"]
        case .welcome: ["welcome", "onboarding", "intro", "first run", "setup"]
        }
    }

    /// Returns whether the field matches what was typed in the sidebar's search: its title or one of its
    /// keywords contains every word, ignoring case and diacritics.
    ///
    /// - Parameter query: the search text; empty matches every field
    /// - Returns: whether the sidebar lists the field under its pane
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The fields of a pane, in their order on the pane.
    ///
    /// - Parameter pane: the pane
    /// - Returns: the pane's fields
    public static func fields(of pane: SettingsPane) -> [SettingsField] {
        allCases.filter { $0.pane == pane }
    }
}

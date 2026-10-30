import Foundation

/// What the import from jenkins-menubar did, for the welcome flow and the log (IMP-01 to IMP-03). It never holds a
/// token: only where each one came from.
public struct LegacyImportReport: Codable, Hashable, Sendable {
    /// when the import ran
    public var date: Date
    /// the old tool's folder; nil when none was found
    public var oldFolder: URL?
    /// how the folder was found
    public var foundBy: OldFolderSource?
    /// whether there was any sign of jenkins-menubar: its folder, its caches, or a token in its keychain service
    public var oldToolFound: Bool
    /// what happened to each token, in the order of ``TokenAccount``
    public var tokens: [TokenImport]
    /// whether `config/settings` was read into the preferences
    public var importedSettings: Bool
    /// whether `config/team.conf` became the project's team values
    public var importedTeam: Bool
    /// the watched jobs added
    public var watchedJobs: Int
    /// the hidden builds added
    public var hiddenBuilds: Int
    /// what didn't move, as the welcome flow lists it (IMP-03)
    public var notMoved: [NotMoved]

    public init(
        date: Date, oldFolder: URL? = nil, foundBy: OldFolderSource? = nil, oldToolFound: Bool = false,
        tokens: [TokenImport] = [], importedSettings: Bool = false, importedTeam: Bool = false, watchedJobs: Int = 0,
        hiddenBuilds: Int = 0, notMoved: [NotMoved] = []
    ) {
        self.date = date
        self.oldFolder = oldFolder
        self.foundBy = foundBy
        self.oldToolFound = oldToolFound
        self.tokens = tokens
        self.importedSettings = importedSettings
        self.importedTeam = importedTeam
        self.watchedJobs = watchedJobs
        self.hiddenBuilds = hiddenBuilds
        self.notMoved = notMoved
    }

    /// Returns what happened to a token.
    ///
    /// - Parameter account: the token's account
    /// - Returns: the outcome; nil when the import didn't look for it
    public func token(_ account: TokenAccount) -> TokenOutcome? {
        tokens.first { $0.account == account }?.outcome
    }

    /// whether the import moved a token, the settings, the team values, a watched job or a hidden build
    public var somethingMoved: Bool {
        importedSettings || importedTeam || watchedJobs > 0 || hiddenBuilds > 0
            || tokens.contains { if case .imported = $0.outcome { true } else { false } }
    }

    /// the line the log keeps: "Imported from jenkins-menubar: …", or "Nothing to import from jenkins-menubar"
    public var summary: String {
        var parts: [String] = []
        for token in tokens {
            if case .imported(let source) = token.outcome {
                parts.append("the \(token.account.displayName) token from \(source.displayName)")
            }
        }
        if importedSettings {
            parts.append("the settings")
        }
        if importedTeam {
            parts.append("the team values")
        }
        if watchedJobs > 0 {
            parts.append(watchedJobs == 1 ? "1 watched job" : "\(watchedJobs) watched jobs")
        }
        if hiddenBuilds > 0 {
            parts.append(hiddenBuilds == 1 ? "1 hidden build" : "\(hiddenBuilds) hidden builds")
        }
        guard !parts.isEmpty else {
            return oldToolFound ? "Imported nothing from jenkins-menubar" : "Nothing to import from jenkins-menubar"
        }
        return "Imported from jenkins-menubar: " + parts.joined(separator: ", ")
    }

    /// the log entry's detail: the folder, and what didn't move, short enough for the log's 500 characters; nil when
    /// there is neither
    public var detail: String? {
        var sentences: [String] = []
        if let oldFolder, let foundBy {
            sentences.append("Folder \(oldFolder.path(percentEncoded: false)), found \(foundBy.displayName).")
        }
        if !notMoved.isEmpty {
            sentences.append("Not moved: " + notMoved.map(\.logLabel).joined(separator: ", ") + ".")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// How the old tool's folder was found, in the order the import looks (Task 6.3).
public enum OldFolderSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// the checkout the app was built from
    case storedCheckout
    /// the plugin in SwiftBar's plugin folder
    case swiftBarPlugin
    /// the `~/bin/jenkins-watch` link
    case watchLink
    /// the folder the user chose in the welcome flow
    case chosen

    /// how the log says it: "found <displayName>"
    public var displayName: String {
        switch self {
        case .storedCheckout: "as the app's checkout"
        case .swiftBarPlugin: "through SwiftBar's plugin"
        case .watchLink: "through ~/bin/jenkins-watch"
        case .chosen: "where it was chosen"
        }
    }
}

/// What happened to one token.
public struct TokenImport: Codable, Hashable, Sendable {
    public var account: TokenAccount
    public var outcome: TokenOutcome

    public init(account: TokenAccount, outcome: TokenOutcome) {
        self.account = account
        self.outcome = outcome
    }
}

/// What the import did with a token (ACC-02).
public enum TokenOutcome: Codable, Hashable, Sendable {
    /// stored under menubar-monitor; it was found here
    case imported(LegacyToken.Source)
    /// MegaMonitor already had one, which was kept
    case kept
    /// none was found (``LegacyToken/Source/missing``), or `~/.zshrc` computes it (``LegacyToken/Source/zshrcComputed``)
    case notFound(LegacyToken.Source)
    /// found, but not stored: the token was refused (ACC-03) or the keychain didn't take it
    case notStored(LegacyToken.Source, reason: String)
}

/// Something the import didn't move, which the welcome flow lists (IMP-03). The messages are proposed copy.
public enum NotMoved: Codable, Hashable, Sendable {
    /// macOS keeps the notification permission and style per app
    case notificationSettings
    case windowPositions
    /// the label memory and the caches start empty
    case labelMemoryAndCaches
    /// a token came from a keychain item that `security` may not have made, and macOS asks once for access to those
    case keychainAccess
    /// the old tool left traces, but its folder wasn't found: the welcome flow asks for it
    case oldFolder
    /// the old folder has no `config/settings`
    case settings
    /// the old folder's `config/team.conf` is missing or empty
    case teamValues
    /// a token that wasn't found or stored
    case token(TokenAccount, TokenOutcome)
    /// a value that couldn't be saved, with the reason
    case notSaved(what: String, reason: String)

    /// the item in the log's detail
    var logLabel: String {
        switch self {
        case .notificationSettings: "notification settings"
        case .windowPositions: "window positions"
        case .labelMemoryAndCaches: "label memory and caches"
        case .keychainAccess: "keychain access"
        case .oldFolder: "the old folder"
        case .settings: "config/settings"
        case .teamValues: "config/team.conf"
        case .token(let account, .notFound(let source)): "the \(account.displayName) token (\(source.displayName))"
        case .token(let account, .notStored(_, let reason)): "the \(account.displayName) token (\(reason))"
        case .token(let account, _): "the \(account.displayName) token"
        case .notSaved(let what, let reason): "\(what) (\(reason))"
        }
    }

    /// whether something went wrong, rather than wasn't there; the log entry is a warning then
    var isFailure: Bool {
        switch self {
        case .notSaved, .token(_, .notStored): true
        default: false
        }
    }

    /// the line the welcome flow shows
    public var message: String {
        switch self {
        case .notificationSettings:
            "Notification permission and style: macOS keeps them per app, so allow notifications again"
        case .windowPositions:
            "Window positions"
        case .labelMemoryAndCaches:
            "The remembered labels and the caches: they fill again with the first checks"
        case .keychainAccess:
            "Keychain items made outside the security tool: macOS asks once before they can be read"
        case .oldFolder:
            "The jenkins-menubar folder was not found: choose it to import its settings and team values"
        case .settings:
            "Settings: the old folder has no config/settings, so the defaults apply"
        case .teamValues:
            "Team values: the old folder's config/team.conf is missing or empty"
        case .token(let account, .notFound(.zshrcComputed)):
            "The \(account.displayName) token: ~/.zshrc computes it, which the app cannot run: paste it here"
        case .token(let account, .notStored(let source, let reason)):
            "The \(account.displayName) token from \(source.displayName) was not stored: \(reason)"
        case .token(let account, _):
            "The \(account.displayName) token: none was found"
        case .notSaved(let what, let reason):
            "\(what) could not be saved: \(reason)"
        }
    }
}

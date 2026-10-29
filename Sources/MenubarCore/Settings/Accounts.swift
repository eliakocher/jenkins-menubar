import Foundation

/// What the account check found for one server: who is signed in, or what is wrong (ACC-04).
public struct AccountStatus: Hashable, Sendable {
    /// whether the server took the token
    public var ok: Bool
    /// "Signed in as jdoe", "No token yet", or the problem's text
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }

    /// "No token yet"
    public static let noToken = AccountStatus(ok: false, message: "No token yet")
    /// "Set the Jenkins job in Team first"
    public static let noJenkinsJob = AccountStatus(ok: false, message: "Set the Jenkins job in Team first")
    /// "Set the GitLab URL in Team first"
    public static let noGitLabURL = AccountStatus(ok: false, message: "Set the GitLab URL in Team first")

    /// "Signed in as <user>"
    public static func signedIn(as user: String) -> AccountStatus {
        signedIn(as: user, readOnly: false)
    }

    /// "Signed in as <user>", and for a GitLab token that can only read, why Re-request Review won't work (MR-09)
    public static func signedIn(as user: String, readOnly: Bool) -> AccountStatus {
        AccountStatus(
            ok: true,
            message: readOnly
                ? "Signed in as \(user). The token can only read: re-requesting a review needs the api scope"
                : "Signed in as \(user)")
    }
}

/// A link that creates a token (ACC-05).
public struct TokenLink: Hashable, Sendable {
    /// the link's text, like "Get a token: your user page → Security"
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    /// Returns the link that creates a token for an account, or nil while the team value it needs is missing.
    ///
    /// - Jenkins: "Get a token: your user page → Security", `<Jenkins root>/me/`, where the root is the job URL before
    ///   its first `/job/`.
    /// - GitLab: "Create a token with the api scope", the new token page with the name and scope filled in.
    ///
    /// - Parameters:
    ///   - account: the token's account
    ///   - team: the saved team values
    /// - Returns: the link
    public static func create(_ account: TokenAccount, team: TeamValues) -> TokenLink? {
        switch account {
        case .jenkins:
            guard team.jenkinsJob != nil else { return nil }
            let job = team.normalized().jenkinsJobURL
            // The old plugin's `${JOB_ROOT%%/job/*}`: everything before the first `/job/`.
            let root = job.range(of: "/job/").map { String(job[..<$0.lowerBound]) } ?? job
            return URL(string: root + "/me/").map { TokenLink(title: "Get a token: your user page → Security", url: $0) }
        case .gitlab:
            guard let gitLab = team.gitLab else { return nil }
            return TokenLink(title: "Create a token with the api scope", url: GitLabLinks.newToken(gitLab: gitLab))
        }
    }
}

/// Where a token comes from, as Accounts shows it (ACC-02, ACC-06).
public enum TokenSource: Hashable, Sendable {
    /// in the keychain; where the import found it, nil when it was entered in Settings
    case keychain(importedFrom: LegacyToken.Source?)
    /// not stored; what the import found instead, like an export that `~/.zshrc` computes
    case missing(LegacyToken.Source?)

    /// whether a token is stored
    public var isStored: Bool {
        if case .keychain = self { true } else { false }
    }

    /// "Keychain", "Keychain, imported from ~/.zshrc", "Keychain, imported from jenkins-menubar", "Missing", or why a
    /// computed export can't be used (`docs/design/settings-accounts.md`)
    public var text: String {
        switch self {
        case .keychain(nil): "Keychain"
        // The old tool's name alone: "keychain (jenkins-menubar)" would say keychain twice.
        case .keychain(.oldKeychain?): "Keychain, imported from jenkins-menubar"
        case .keychain(let source?): "Keychain, imported from \(source.displayName)"
        case .missing(.zshrcComputed): "~/.zshrc computes it, which the app cannot run: paste it here"
        case .missing: "Missing"
        }
    }
}

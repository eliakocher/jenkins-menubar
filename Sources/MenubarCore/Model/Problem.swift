import Foundation

/// Something that keeps the app from checking Jenkins or loading GitLab, shown as a red row and logged once when it
/// starts and once when resolved (LOG-01).
///
/// Two problems are the same when they are equal, so a problem whose text doesn't change is logged once. The messages
/// are the copy of `docs/FEATURES.md`.
public enum Problem: Codable, Hashable, Sendable, CustomStringConvertible {
    /// no token in the keychain; no request is made (JERR-01, MR-04)
    case noToken(Server)
    /// HTTP 401 or 403, or a GitLab answer without `currentUser` (JERR-02, MR-05)
    case rejectedToken(Server)
    /// GitLab refused the token for its scope (`insufficient_scope`), which needs `api` (MR-05)
    case missingScope
    /// HTTP 404 for the job list: the job URL in Team is wrong (JERR-03)
    case unknownJob
    /// HTTP 404 for one job: Jenkins dropped it, as for a merged MR. Its build leaves the list, without a problem row
    /// (JERR-04, WATCH-05).
    case gone
    /// no connection, an unknown host, or a timeout that makes the server unreachable (JERR-05, MR-05, NET-01)
    case unreachable(Server)
    /// the job list took longer than its time limit; the last list is kept (JERR-06)
    case slow
    /// another HTTP status (JERR-08, MR-05)
    case httpStatus(Server, status: Int)
    /// a GraphQL answer with errors, in GitLab's order (MR-05)
    case graphQLErrors(messages: [String])
    /// the WorkItems request got another HTTP status, or an answer without work items, and no GraphQL error (MR-05)
    case workItemsFailed(status: Int)
    /// the Jenkins job URL, the GitLab URL or the project is missing; no request is made (TEAM-03)
    case teamValuesMissing
    /// a 2xx answer from Jenkins that isn't the JSON asked for, like the sign-in page of a proxy (JERR-08)
    case notJSON
    /// the Mac has no network path: no check and no GitLab load runs until it is back (OD-05)
    case offline

    /// The server a problem comes from.
    public enum Server: String, Codable, Hashable, Sendable, CaseIterable {
        case jenkins
        case gitLab
    }

    /// the server the problem comes from; `nil` for missing team values and for being offline, which keep both from
    /// being asked
    public var server: Server? {
        switch self {
        case .noToken(let server), .rejectedToken(let server), .unreachable(let server), .httpStatus(let server, _):
            server
        case .unknownJob, .gone, .slow, .notJSON: .jenkins
        case .missingScope, .graphQLErrors, .workItemsFailed: .gitLab
        case .teamValuesMissing, .offline: nil
        }
    }

    /// whether the status icon shows the problem marker for it: Jenkins problems and missing team values do, GitLab
    /// problems don't (PIPE-05)
    public var marksStatusIcon: Bool {
        server != .gitLab
    }

    /// the text of the red row and of the log entry
    public var message: String {
        switch self {
        case .noToken(.jenkins): "No Jenkins token: add it in Settings → Accounts"
        case .noToken(.gitLab): "Needs a GitLab token with the api scope"
        case .rejectedToken(.jenkins): "Jenkins rejected the token"
        case .rejectedToken(.gitLab): "GitLab rejected the token (expired, or without the api scope?)"
        case .missingScope: "GitLab rejected the token: it needs the api scope"
        case .unknownJob: "Jenkins does not know the job: check the job URL in Team"
        case .gone: "Jenkins no longer has the job"
        case .unreachable(.jenkins): "Jenkins unreachable (VPN?)"
        case .unreachable(.gitLab): "GitLab unreachable"
        case .slow: "The list of MR jobs took too long: the builds of the last list are checked"
        case .httpStatus(.jenkins, let status): "Jenkins answered with HTTP \(status)"
        case .httpStatus(.gitLab, let status): "GitLab answered with HTTP \(status)"
        case .graphQLErrors(let messages): messages.first ?? "GitLab answered with an error"
        case .workItemsFailed(let status): "Work items request failed (HTTP \(status))"
        case .teamValuesMissing: "Fill in the team settings: your Jenkins job and GitLab project"
        case .notJSON: "Jenkins sent an answer that isn't JSON (a login page?)"
        case .offline: "Offline: checks resume when the network is back"
        }
    }

    public var description: String { message }
}

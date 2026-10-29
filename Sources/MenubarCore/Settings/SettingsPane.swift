import Foundation

/// The panes of the Settings scene, in their order (SET-02).
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case general
    case jenkins
    case gitLab
    /// the folders of the local checkouts and the Open in IDE command (WS-01)
    case repositories
    case team
    case accounts

    /// "General", "Jenkins", "GitLab", "Repositories", "Projects" or "Accounts"; ``team`` is Projects since there can
    /// be several (plan Phase 13), and keeps its name in the `settings/team` link
    public var title: String {
        switch self {
        case .general: "General"
        case .jenkins: "Jenkins"
        case .gitLab: "GitLab"
        case .repositories: "Repositories"
        case .team: "Projects"
        case .accounts: "Accounts"
        }
    }

    /// Returns the pane a problem row or link opens: Accounts for a token, Team for the team values or an unknown job.
    /// Filters… and a gone filter label open ``gitLab`` directly.
    ///
    /// - Parameter problem: the problem of the row
    /// - Returns: the pane, or nil when no setting fixes the problem
    public static func pane(for problem: Problem) -> SettingsPane? {
        switch problem {
        case .noToken, .rejectedToken, .missingScope: .accounts
        case .teamValuesMissing, .unknownJob: .team
        // A server that fails, and any case added later, is nothing a setting fixes.
        default: nil
        }
    }
}

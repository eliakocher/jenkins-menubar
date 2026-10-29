#if DEBUG
import Foundation
import MenubarCore

/// The fake data of the Settings panes (`docs/design/settings-*.md`, States): the team values of `team.example.json`,
/// `jdoe`, and GitLab's label colors of the work items' fixtures.
extension Fixtures {
    // MARK: - GitLab

    /// GitLab's colors of the labels the GitLab pane shows
    var settingsLabelColors: [String: String] {
        [
            "priority::high": "#D9534F", "priority::low": "#5CB85C", "workflow::committed": "#428BCA",
            "workflow::in-progress": "#6699CC", "workflow::gone": "#428BCA", "team::web::frontend": "#5CB85C",
            "team::web::backend": "#5CB85C", "frontend": "#F0AD4E", "design": "#330066", "docs": "#FFFFFF",
            "wontfix": "#000000", "type::bug": "#D9534F", "type::feature": "#428BCA", "release": "#6699CC",
            "team::platform::a-very-long-label-name-for-the-search-index-rework": "#6699CC",
            "workflow::waiting-for-the-review-of-the-search-index-rework": "#428BCA",
            "a-very-long-label-without-a-scope-for-the-search-index-rework": "#F0AD4E",
            "release::a-label-value-of-about-ninety-characters-that-is-wider-than-the-row-left-of-add-label": "#428BCA",
        ]
    }

    /// the labels the picker knows without a search: remembered and filter labels
    var settingsKnownLabels: [String] {
        ["design", "docs", "frontend", "needs-review", "priority::high", "priority::low", "team::web::frontend",
         "wontfix", "workflow::committed", "workflow::in-progress"].sorted()
    }

    /// The preferences with work item filters.
    func settingsPreferences(_ filters: WorkItemFilters) -> Preferences {
        var preferences = Preferences()
        preferences.workItems = filters
        return preferences
    }

    /// A label search's answer, with the colors of the fixtures.
    func settingsSearch(_ labels: [String], problem: String? = nil) -> LabelSearchResult {
        LabelSearchResult(
            labels: labels.sorted(), colors: settingsLabelColors.filter { labels.contains($0.key) }, found: [],
            problem: problem)
    }

    // MARK: - Accounts

    /// Accounts' values with both tokens stored, entered here, and no check yet
    var settingsAccounts: AccountsFormModel {
        AccountsFormModel(
            jenkinsSource: .keychain(importedFrom: nil), gitLabSource: .keychain(importedFrom: nil),
            jenkinsLink: TokenLink.create(.jenkins, team: team), gitLabLink: TokenLink.create(.gitlab, team: team))
    }

    /// both signed in
    var settingsSignedIn: [TokenAccount: AccountStatus] {
        [.jenkins: .signedIn(as: me), .gitlab: .signedIn(as: me)]
    }
}
#endif

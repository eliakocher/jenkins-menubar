import Foundation

/// The links into GitLab's web pages (MR-04, WI-07).
public enum GitLabLinks {
    /// Returns "All merge requests in GitLab": `<gitlab>/dashboard/merge_requests` (WI-07).
    ///
    /// - Parameter gitLab: the GitLab instance
    /// - Returns: the link
    public static func mergeRequests(gitLab: URL) -> URL {
        gitLab.appending(path: "dashboard/merge_requests")
    }

    /// Returns "All work items in GitLab": the dashboard's issues, assigned to me or created by me, in the state of
    /// the filters; the plain dashboard before my username is known (WI-07).
    ///
    /// - Parameters:
    ///   - gitLab: the GitLab instance
    ///   - filters: the work item filters
    ///   - me: my GitLab username; `nil` before GitLab answered
    /// - Returns: the link
    public static func workItems(gitLab: URL, filters: WorkItemFilters, me: String?) -> URL {
        let dashboard = gitLab.appending(path: "dashboard/issues")
        guard let me, !me.isEmpty else { return dashboard }
        return dashboard.appending(queryItems: [
            URLQueryItem(name: filters.scope == .authored ? "author_username" : "assignee_username", value: me),
            URLQueryItem(name: "state", value: filters.state.rawValue),
        ])
    }

    /// Returns the page that creates a GitLab token named MegaMonitor with the `api` scope (MR-04, MR-09).
    ///
    /// - Parameter gitLab: the GitLab instance
    /// - Returns: the link
    public static func newToken(gitLab: URL) -> URL {
        gitLab.appending(path: "-/user_settings/personal_access_tokens").appending(queryItems: [
            URLQueryItem(name: "name", value: AppIdentity.displayName),
            URLQueryItem(name: "scopes", value: "api"),
        ])
    }
}

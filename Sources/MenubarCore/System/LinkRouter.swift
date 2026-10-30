import Foundation

/// Where a web link goes while MegaMonitor is the Mac's default browser (APP-09): a place in the app's window, or
/// back to the browser the user had.
public enum LinkRoute: Hashable, Sendable {
    /// a build of a project's Jenkins job, as in `<job URL>/job/MR-12/45/console`; `job` is as in Jenkins URLs, still
    /// URL-encoded
    case jenkinsBuild(project: ProjectID, job: String, number: Int)
    /// a job, as in `<job URL>/job/MR-12/`
    case jenkinsJob(project: ProjectID, job: String)
    /// a GitLab merge request, by the project's full path and its iid
    case mergeRequest(gitLabProject: String, iid: Int)
    /// a GitLab issue or work item, by the project's full path and its iid
    case workItem(gitLabProject: String, iid: Int)
    /// a GitLab pipeline, which the app has no page for
    case pipeline(gitLabProject: String, id: Int)
    /// anything else: the real browser, at once
    case browser

    /// the kind's name for the log, which never holds the link
    public var kind: String {
        switch self {
        case .jenkinsBuild: "jenkins build"
        case .jenkinsJob: "jenkins job"
        case .mergeRequest: "merge request"
        case .workItem: "work item"
        case .pipeline: "pipeline"
        case .browser: "browser"
        }
    }
}

/// Sorts a web link by the configured Jenkins jobs and GitLab instance (APP-09). It reads only the link and the
/// projects' values: no network, no state, so a link that isn't ours is passed on at once.
///
/// - A Jenkins link is one under a project's Jenkins job URL: `<job URL>/job/<job>` is a job, with a number after it a
///   build; whatever follows the number (`/console`, `/testReport`) and any query or anchor is ignored.
/// - A GitLab link is one on the project's GitLab instance with `/-/merge_requests/<iid>`, `/-/issues/<iid>`,
///   `/-/work_items/<iid>` or `/-/pipelines/<id>` after any project path, so a merge request of another project of the
///   same instance is a merge request too: the app decides whether it can show it. The old form without `/-/` counts
///   too.
/// - Hosts compare in lowercase, a `%20` and a space alike; a scheme other than `http` and `https` never matches.
public struct LinkRouter: Sendable {
    private struct Server: Sendable {
        var host: String
        var port: Int?
        var path: [String]
    }

    private let jenkins: [(project: ProjectID, server: Server)]
    private let gitLabs: [Server]

    /// - Parameter projects: the projects, whose Jenkins job URLs and GitLab URLs the links are read against
    public init(projects: [Project]) {
        jenkins = projects.compactMap { project in
            Self.server(of: project.team.jenkinsJob).map { (project.id, $0) }
        }
        gitLabs = projects.compactMap { Self.server(of: $0.team.gitLab) }
    }

    /// Sorts a link.
    ///
    /// - Parameter url: the link that was opened
    /// - Returns: its place in the app, or ``LinkRoute/browser``
    public func route(_ url: URL) -> LinkRoute {
        guard let link = Self.server(of: url) else {
            return .browser
        }
        for entry in jenkins where entry.server.host == link.host && entry.server.port == link.port {
            if let route = jenkinsRoute(entry.project, root: entry.server.path, link: link.path) {
                return route
            }
        }
        for server in gitLabs where server.host == link.host && server.port == link.port {
            if let route = Self.gitLabRoute(root: server.path, link: link.path) {
                return route
            }
        }
        return .browser
    }

    // MARK: - Jenkins

    private func jenkinsRoute(_ project: ProjectID, root: [String], link: [String]) -> LinkRoute? {
        guard link.count >= root.count + 2, Self.segmentsMatch(root, Array(link.prefix(root.count))),
            Self.decoded(link[root.count]) == "job"
        else {
            return nil
        }
        let job = link[root.count + 1]
        guard !job.isEmpty else {
            return nil
        }
        let rest = link.dropFirst(root.count + 2)
        if let first = rest.first, first.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(first), number > 0 {
            return .jenkinsBuild(project: project, job: job, number: number)
        }
        return .jenkinsJob(project: project, job: job)
    }

    // MARK: - GitLab

    private static func gitLabRoute(root: [String], link: [String]) -> LinkRoute? {
        guard link.count > root.count, segmentsMatch(root, Array(link.prefix(root.count))) else {
            return nil
        }
        let rest = Array(link.dropFirst(root.count)).map(decoded)
        // `group/project/-/merge_requests/12/diffs`, or the old `group/project/merge_requests/12`.
        let marker: Int
        let path: ArraySlice<String>
        if let dash = rest.firstIndex(of: "-") {
            marker = dash + 1
            path = rest.prefix(dash)
        } else if let old = rest.firstIndex(where: { ["merge_requests", "issues"].contains($0) }) {
            marker = old
            path = rest.prefix(old)
        } else {
            return nil
        }
        guard path.count >= 2, path.first != "groups", marker + 1 < rest.count,
            rest[marker + 1].allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(rest[marker + 1])
        else {
            return nil
        }
        let project = path.joined(separator: "/")
        switch rest[marker] {
        case "merge_requests": return .mergeRequest(gitLabProject: project, iid: number)
        case "issues", "work_items": return .workItem(gitLabProject: project, iid: number)
        case "pipelines" where rest.contains("-"): return .pipeline(gitLabProject: project, id: number)
        default: return nil
        }
    }

    // MARK: - Reading URLs

    private static func server(of url: URL?) -> Server? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        let path = components.percentEncodedPath.split(separator: "/").map { String($0).replacingOccurrences(of: " ", with: "%20") }
        return Server(host: host, port: components.port, path: path)
    }

    /// whether two paths name the same places: `%20` and a space alike, the case of the letters ignored
    private static func segmentsMatch(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { decoded($0).lowercased() == decoded($1).lowercased() }
    }

    /// one level of percent-decoding, so a job's `%252F` stays `%2F`
    private static func decoded(_ segment: String) -> String {
        segment.removingPercentEncoding ?? segment
    }
}

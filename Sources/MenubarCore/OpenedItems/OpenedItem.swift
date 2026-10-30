import Foundation

/// A merge request, work item or Jenkins build that isn't in my lists and that I opened anyway, kept like a tab in the
/// main window's sidebar under "Opened" (WIN-06). It holds only the reference and the title: the item itself loads again
/// from GitLab or Jenkins.
public struct OpenedItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case mergeRequest
        case workItem
        /// a Jenkins build: ``project`` is the Team project's id, ``job`` the job and ``iid`` the build number
        case build
    }

    public var kind: Kind
    /// the project's full path, like `group/project`; for a build, the id of the Team project whose Jenkins it is
    public var project: String
    /// the number in the project; for a build, its number in the job
    public var iid: Int
    /// a build's job as in Jenkins URLs, still URL-encoded; `nil` for a merge request or work item
    public var job: String?
    /// the item's page in GitLab or Jenkins, for Open in GitLab, Open Build in Jenkins and Copy Link
    public var webURL: URL
    /// the title, once the item loaded; `nil` before
    public var title: String?
    /// when it was opened, or opened again
    public var openedAt: Date
    /// when it was last shown, which the seven days of expiry count from
    public var lastViewedAt: Date
    /// a pinned item stays until it is closed
    public var isPinned: Bool

    public init(
        kind: Kind, project: String, iid: Int, webURL: URL, title: String? = nil, openedAt: Date, lastViewedAt: Date? = nil,
        isPinned: Bool = false, job: String? = nil
    ) {
        self.kind = kind
        self.project = project
        self.iid = iid
        self.job = job
        self.webURL = webURL
        self.title = title
        self.openedAt = openedAt
        self.lastViewedAt = lastViewedAt ?? openedAt
        self.isPinned = isPinned
    }

    /// the full reference, like `group/project!12` for a merge request, `group/project#12` for a work item or `!12 #7` for
    /// build 7 of the job `MR-12`
    public var reference: String {
        switch kind {
        case .build: "\(Build.label(forJob: job ?? "")) #\(String(iid))"
        case .mergeRequest: "\(project)!\(String(iid))"
        case .workItem: "\(project)#\(String(iid))"
        }
    }

    /// the reference in lowercase, so the same item opened by two spellings of its path is one
    public var id: String { Self.id(kind: kind, project: project, iid: iid, job: job) }

    /// Returns the id of an item.
    ///
    /// - Parameters:
    ///   - kind: merge request, work item or build
    ///   - project: the project's full path; a build's Team project id
    ///   - iid: the number in the project; a build's number
    ///   - job: a build's job as in Jenkins URLs, whose case counts
    public static func id(kind: Kind, project: String, iid: Int, job: String? = nil) -> String {
        switch kind {
        case .build: "build:\(project)/\(job ?? "")#\(String(iid))"
        case .mergeRequest: "\(project)!\(String(iid))".lowercased()
        case .workItem: "\(project)#\(String(iid))".lowercased()
        }
    }

    /// the short form the sidebar shows: `!12` or `#12`; a build's number is `#7` too, which its symbol tells apart
    public var shortReference: String {
        "\(kind == .mergeRequest ? "!" : "#")\(String(iid))"
    }

    /// what the sidebar shows before the item's title is known: the project of a merge request or work item, the job's
    /// label for a build
    public var fallbackTitle: String {
        kind == .build ? Build.label(forJob: job ?? "") : project
    }
}

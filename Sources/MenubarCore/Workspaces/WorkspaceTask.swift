import Foundation

/// The team's branch names: `<number>-<title-as-slug>`, GitLab's "Create branch" naming, so a branch leads to its work
/// item (WS-04).
public enum BranchTask {
    /// Returns the work item's number at the start of a branch name: `1234-fix-login` is 1234. A folder-like prefix is
    /// skipped (`feature/1234-fix-login`, `jdoe/1234`), and the number must end the name or be followed by `-` or `_`,
    /// so `v2-cleanup`, `2fa-login` and `develop` have none.
    ///
    /// - Parameter branch: the branch name
    /// - Returns: the number, 1 or more; `nil` when the branch has none
    public static func number(of branch: String) -> Int? {
        let name = branch.split(separator: "/").last.map(String.init) ?? branch
        let digits = name.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else {
            return nil
        }
        let rest = name.dropFirst(digits.count)
        guard rest.isEmpty || rest.hasPrefix("-") || rest.hasPrefix("_"), let number = Int(digits), number > 0 else {
            return nil
        }
        return number
    }

    /// Returns a branch's slug made readable, for a work item the app doesn't know: `1234-fix-login-timeout` is "Fix
    /// login timeout".
    ///
    /// - Parameter branch: the branch name
    /// - Returns: the title; `nil` when only the number is left
    public static func readableTitle(of branch: String) -> String? {
        guard number(of: branch) != nil else {
            return nil
        }
        let name = branch.split(separator: "/").last.map(String.init) ?? branch
        let slug = name.drop { $0.isASCII && $0.isNumber }
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        guard let first = words.first else {
            return nil
        }
        return first.uppercased() + words.dropFirst()
    }
}

/// What a checkout works on, joined from what the app knows already: the work item by the branch's number, the merge
/// request by its source branch, and that merge request's Jenkins build (WS-04). Nothing is asked for it.
public struct WorkspaceTask: Hashable, Sendable {
    /// the work item's number, from the branch
    public var number: Int?
    /// the work item, when it is among the loaded ones
    public var workItem: WorkItem?
    /// the work item's title, or the branch's slug made readable when the work item isn't loaded
    public var title: String?
    /// the open merge request of mine whose source branch is the checkout's branch
    public var mergeRequest: MergeRequest?
    /// the merge request's last Jenkins build, when Pipelines follows it
    public var build: Build?
    /// the work item's page: its own link, or one built from the merge request's project
    public var workItemURL: URL?

    public init(
        number: Int? = nil, workItem: WorkItem? = nil, title: String? = nil, mergeRequest: MergeRequest? = nil,
        build: Build? = nil, workItemURL: URL? = nil
    ) {
        self.number = number
        self.workItem = workItem
        self.title = title
        self.mergeRequest = mergeRequest
        self.build = build
        self.workItemURL = workItemURL
    }

    /// Joins a branch with the work items, merge requests and builds the app has.
    ///
    /// - Parameters:
    ///   - branch: the checkout's branch; `nil` for a detached HEAD
    ///   - workItems: the loaded work items
    ///   - mergeRequests: the loaded merge requests
    ///   - builds: the builds Pipelines follows, mine and watched
    /// - Returns: the task; empty for a detached HEAD
    public static func match(
        branch: String?, workItems: [WorkItem], mergeRequests: [MergeRequest], builds: [Build]
    ) -> WorkspaceTask {
        guard let branch else {
            return WorkspaceTask()
        }
        let number = BranchTask.number(of: branch)
        let mergeRequest = mergeRequests.first { $0.sourceBranch == branch }
        // A number names an issue of the merge request's project; the same number in another project is another item.
        let candidates = number.map { number in workItems.filter { !$0.isEpic && $0.iid == String(number) } } ?? []
        let project = mergeRequest.map { projectPath(of: $0.reference) }
        let workItem = candidates.first { projectPath(of: $0.reference) == project } ?? candidates.first
        let build = mergeRequest.flatMap { mergeRequest in
            builds.first { $0.mergeRequestIID == mergeRequest.iid && sameProject($0, mergeRequest) }
        }
        return WorkspaceTask(
            number: number,
            workItem: workItem,
            title: workItem?.displayTitle ?? BranchTask.readableTitle(of: branch),
            mergeRequest: mergeRequest,
            build: build,
            workItemURL: workItem?.webURL ?? number.flatMap { number in
                mergeRequest.flatMap { issueURL(number, nextTo: $0.webURL) }
            })
    }

    /// Returns `group/project` of a reference like `group/project!12` or `group/project#34`.
    static func projectPath(of reference: String) -> String {
        String(reference.prefix { $0 != "!" && $0 != "#" && $0 != "&" })
    }

    /// Whether a build is the merge request's: its GitLab link, when Jenkins sent one, is the merge request's.
    static func sameProject(_ build: Build, _ mergeRequest: MergeRequest) -> Bool {
        guard let link = build.gitLabURL else {
            return true
        }
        return trimmed(link.absoluteString) == trimmed(mergeRequest.webURL.absoluteString)
    }

    private static func trimmed(_ text: String) -> String {
        var text = text
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// Returns the issue page next to a merge request's page: `<project>/-/merge_requests/12` gives
    /// `<project>/-/issues/<number>`, which GitLab sends on to a work item's page when it is one.
    static func issueURL(_ number: Int, nextTo mergeRequest: URL) -> URL? {
        let text = mergeRequest.absoluteString
        guard let range = text.range(of: "/-/merge_requests/") else {
            return nil
        }
        return URL(string: "\(text[..<range.lowerBound])/-/issues/\(number)")
    }
}

import Foundation

/// The types of work item the New Work Item pages start: GitLab's issue templates of the same name, and the scoped
/// type label (NEW-01).
public enum WorkItemKind: String, CaseIterable, Hashable, Sendable {
    case bug
    case task
    case newFeature
    case improvement

    /// the name in the menus: "Bug", "Task", "New Feature", "Improvement"
    public var title: String {
        switch self {
        case .bug: "Bug"
        case .task: "Task"
        case .newFeature: "New Feature"
        case .improvement: "Improvement"
        }
    }

    /// the name of the project's issue template, as GitLab's `issuable_template` takes it: the file's name without
    /// `.md`
    public var templateName: String {
        switch self {
        case .bug: "Bug"
        case .task: "Task"
        case .newFeature: "New feature"
        case .improvement: "Improvement"
        }
    }

    /// the value of the type label, which follows the team's prefix: `Bug`, `Task`, `NewFeature`, `Improvement`
    public var labelValue: String {
        switch self {
        case .bug: "Bug"
        case .task: "Task"
        case .newFeature: "NewFeature"
        case .improvement: "Improvement"
        }
    }
}

/// What a New Work Item entry point puts on GitLab's new issue page: the type, and a title and a description when the
/// entry point knows the context. Without them the page opens blank, with only the type's template (NEW-01).
public struct NewWorkItemDraft: Hashable, Sendable {
    public var kind: WorkItemKind
    public var title: String
    /// the Markdown description without quick actions; the link adds them
    public var body: String

    public init(kind: WorkItemKind, title: String = "", body: String = "") {
        self.kind = kind
        self.title = title
        self.body = body
    }

    /// whether the draft is only a type: the page opens with the template, which a description would replace
    public var isBlank: Bool { title.isEmpty && body.isEmpty }
}

/// The links to GitLab's own new issue page, prefilled from the URL: no form of the app, no write, no token in the
/// link (NEW-01, NEW-02).
///
/// What GitLab's documentation says about the page (docs.gitlab.com, "Create an issue", prefilled values): the
/// parameters `issue[title]`, `issue[description]`, `issuable_template` (and from GitLab 17.9 `description_template`)
/// and `issue[confidential]`, each URL-encoded; a given `issue[description]` replaces the template. It lists no
/// parameter for the assignee or the labels, so they are quick actions at the end of the description (`/assign me`,
/// `/label ~"…"`), which GitLab runs when the issue is created.
public enum NewWorkItem {
    /// the longest link kept, in characters; the usual web servers refuse a request line of 8 KB or more
    public static let linkLimit = 6000
    /// the longest title kept, in characters
    public static let titleLimit = 200
    /// the most failed tests listed in a description
    public static let testsListed = 10
    /// the longest error line kept for a failed test
    static let messageLimit = 160
    /// the line that ends a description cut to fit the link
    static let cutNote = "_(cut to fit a link)_"

    /// Returns the quick actions that end a description: it is assigned to me, and gets the type label when the team
    /// has a prefix.
    ///
    /// - Parameters:
    ///   - kind: the type
    ///   - typeLabelPrefix: the team's prefix of the type label, like `type::`; empty adds no label
    /// - Returns: the lines, each one quick action
    public static func quickActions(kind: WorkItemKind, typeLabelPrefix: String) -> [String] {
        var lines = ["/assign me"]
        let prefix = typeLabelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            lines.append("/label ~\"\(prefix + kind.labelValue)\"")
        }
        return lines
    }

    /// Returns the link to the new issue page of a draft.
    ///
    /// A blank draft gives the type's template and nothing else, since a description would replace the template, and
    /// the quick actions are part of it. Any other draft gives its title and its description with the quick actions
    /// last; a description too long for ``linkLimit`` is cut at a line end, and the quick actions stay.
    ///
    /// - Parameters:
    ///   - draft: the draft
    ///   - team: the team values, for the GitLab URL, the project and the type label prefix
    /// - Returns: the link; `nil` without a valid GitLab URL and project
    public static func link(for draft: NewWorkItemDraft, team: TeamValues) -> URL? {
        guard let gitLab = team.gitLab, !team.gitLabProject.isEmpty else { return nil }
        let base = gitLab.absoluteString + "/" + team.gitLabProject + "/-/issues/new"
        var query: [(String, String)] = []
        if draft.isBlank {
            query = [("issuable_template", draft.kind.templateName), ("description_template", draft.kind.templateName)]
            return URL(string: base + "?" + encoded(query))
        }
        let title = String(oneLine(draft.title).prefix(titleLimit))
        query = [("issue[title]", title)]
        let actions = quickActions(kind: draft.kind, typeLabelPrefix: team.typeLabelPrefix).joined(separator: "\n")
        func link(body: String) -> String {
            let description = (body.isEmpty ? "" : body + "\n\n") + actions
            return base + "?" + encoded(query + [("issue[description]", description)])
        }
        var text = link(body: draft.body)
        if text.count > linkLimit {
            // The longest prefix of the body, cut at a line end, that fits; the quick actions don't count as cut.
            let lines = draft.body.components(separatedBy: "\n")
            var low = 0
            var high = lines.count
            while low < high {
                let middle = (low + high + 1) / 2
                if link(body: lines.prefix(middle).joined(separator: "\n") + "\n\n" + cutNote).count <= linkLimit {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            text = link(body: lines.prefix(low).joined(separator: "\n") + "\n\n" + cutNote)
        }
        return URL(string: text)
    }

    /// Returns the draft of "New Bug from This Build": the title from the job's label and the failed stages, the
    /// description with the build's link, its facts and the failed tests when they are known.
    ///
    /// - Parameters:
    ///   - build: the failed or unstable build
    ///   - buildURL: the build's page in Jenkins; `nil` without the job URL in the team values
    ///   - failedTests: the failed tests of the report; `nil` when they aren't known
    /// - Returns: the draft, of type Bug
    public static func bugFromBuild(_ build: Build, buildURL: URL?, failedTests: [FailedTest]?) -> NewWorkItemDraft {
        let label = build.label
        let stages = build.failedStages ?? []
        let title = "Build failure in \(label)" + (stages.isEmpty ? "" : ": " + stages.joined(separator: ", "))
        var facts: [String] = []
        if let buildURL {
            facts.append("- Build: \(buildURL.absoluteString)")
        }
        facts.append("- Job: \(label) #\(String(build.number))" + (build.title.map { " (\(oneLine($0)))" } ?? ""))
        if let result = build.result {
            facts.append("- Result: \(result.rawValue)")
        }
        if !stages.isEmpty {
            facts.append("- Failed stages: \(oneLine(stages.joined(separator: ", ")))")
        }
        if let url = build.gitLabURL {
            facts.append("- \(build.mergeRequestIID == nil ? "Branch" : "Merge request"): \(url.absoluteString)")
        }
        if let counts = build.testCounts, counts.failed > 0 {
            facts.append("- Failed tests: \(String(counts.failed)) of \(String(counts.total))")
        }
        var sections = ["### Build\n\n" + facts.joined(separator: "\n")]
        if let tests = failedTests, !tests.isEmpty {
            var lines = tests.prefix(testsListed).map { test in
                let name = (test.shortClassName.isEmpty ? "" : test.shortClassName + ".") + test.name
                var line = "- `\(name.replacingOccurrences(of: "`", with: "'"))`"
                if let message = test.message.flatMap({ $0.components(separatedBy: .newlines).first }) {
                    line += ": " + String(oneLine(message).prefix(messageLimit))
                }
                return line
            }
            if tests.count > testsListed {
                lines.append("- … and \(String(tests.count - testsListed)) more in the build's test report")
            }
            sections.append("### Failed tests\n\n" + lines.joined(separator: "\n"))
        }
        return NewWorkItemDraft(kind: .bug, title: title, body: sections.joined(separator: "\n\n"))
    }

    /// Returns the draft of "New Follow-Up Item": a task that names the merge request and carries its link.
    ///
    /// GitLab cross-references the link on the merge request. The `/relate` quick action takes issues only, so it
    /// isn't used.
    ///
    /// - Parameter mergeRequest: the merge request the work follows up
    /// - Returns: the draft, of type Task
    public static func followUp(of mergeRequest: MergeRequest) -> NewWorkItemDraft {
        let title = oneLine(mergeRequest.title)
        let body = """
            ### Follow-up

            Follows up on \(oneLine(mergeRequest.reference)) (\(mergeRequest.webURL.absoluteString)): \(title)

            ### What is left to do

            """
        return NewWorkItemDraft(kind: .task, title: "Follow-up: " + title, body: body.trimmingCharacters(in: .newlines))
    }

    /// Returns the draft of "New Follow-Up Item" on a work item: a task that names the item, carries its link and is
    /// related to it by the `/relate` quick action, which takes issues and tasks. An epic is named and linked only.
    ///
    /// - Parameter workItem: the work item the work follows up
    /// - Returns: the draft, of type Task
    public static func followUp(of workItem: WorkItem) -> NewWorkItemDraft {
        let title = oneLine(workItem.displayTitle)
        let reference = oneLine(workItem.reference)
        var body = """
            ### Follow-up

            Follows up on \(reference) (\(workItem.webURL.absoluteString)): \(title)

            ### What is left to do
            """
        if !workItem.isEpic, !reference.contains(" ") {
            body += "\n\n/relate \(reference)"
        }
        return NewWorkItemDraft(kind: .task, title: "Follow-up: " + title, body: body)
    }

    // MARK: - Encoding

    /// Returns a text on one line, so no pasted line can start a quick action.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Returns the query string: every character but the unreserved ones percent-encoded, so `+` and `&` in a text
    /// stay what they are.
    static func encoded(_ items: [(String, String)]) -> String {
        items.map { name, value in
            let name = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
            let value = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return name + "=" + value
        }.joined(separator: "&")
    }
}

/// Where a new work item starts: the entry points of NEW-01 to NEW-04.
public enum NewWorkItemSource: Hashable, Sendable {
    /// "New Work Item": the page with the type's template
    case blank(WorkItemKind)
    /// "New Bug from This Build", with the build's page in Jenkins
    case bugFromBuild(Build, URL?)
    /// "New Follow-Up Item" on a merge request
    case followUp(MergeRequest)
    /// "New Follow-Up Item" on a work item
    case followUpOfWorkItem(WorkItem)

    /// the build whose failed tests the draft lists when they are known
    public var failedTestsBuild: BuildID? {
        if case .bugFromBuild(let build, _) = self, (build.testCounts?.failed ?? 0) > 0 { build.id } else { nil }
    }

    /// Returns the draft of the entry point.
    ///
    /// - Parameter failedTests: the failed tests of ``failedTestsBuild``; `nil` when they aren't known
    /// - Returns: the draft
    public func draft(failedTests: [FailedTest]?) -> NewWorkItemDraft {
        switch self {
        case .blank(let kind): NewWorkItemDraft(kind: kind)
        case .bugFromBuild(let build, let url): NewWorkItem.bugFromBuild(build, buildURL: url, failedTests: failedTests)
        case .followUp(let mergeRequest): NewWorkItem.followUp(of: mergeRequest)
        case .followUpOfWorkItem(let workItem): NewWorkItem.followUp(of: workItem)
        }
    }
}

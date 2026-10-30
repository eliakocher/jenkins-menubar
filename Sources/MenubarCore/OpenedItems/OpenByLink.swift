import Foundation

/// Reads what people type into "Open by Link…" (⌘⇧O, WIN-06): a GitLab merge request or work item link, or a short
/// reference, `group/project!123` or `group/project#123`, and `!123` or `#123` for the project in Team.
public enum OpenByLink {
    /// Why a text isn't an item.
    public enum Refusal: Hashable, Sendable, Error {
        case empty
        /// a link, but not to a merge request or work item of the GitLab in Team
        case notAnItem
        /// a short form without a project, and none in Team
        case noProject

        /// the line under the field
        public var message: String {
            switch self {
            case .empty: "Paste a link or type group/project!123"
            case .notAnItem: "That isn't a merge request or work item of your GitLab"
            case .noProject: "Add the project in Settings → Team, or type group/project!123"
            }
        }
    }

    /// Reads a text.
    ///
    /// - Parameters:
    ///   - text: what was typed or pasted
    ///   - projects: the projects, whose GitLab instances a link must be on
    ///   - defaultProject: the project of `!123` and `#123`, as Team has it
    /// - Returns: the merge request or work item, as ``LinkRouter`` names them
    public static func parse(_ text: String, projects: [Project], defaultProject: String) -> Result<LinkRoute, Refusal> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(.empty)
        }
        if text.contains("://") {
            guard let url = URL(string: text) else {
                return .failure(.notAnItem)
            }
            let route = LinkRouter(projects: projects).route(url)
            switch route {
            case .mergeRequest, .workItem:
                return .success(route)
            default:
                return .failure(.notAnItem)
            }
        }
        guard let sign = text.lastIndex(where: { $0 == "!" || $0 == "#" }),
            let iid = Int(text[text.index(after: sign)...]), iid > 0,
            text[text.index(after: sign)...].allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            return .failure(.notAnItem)
        }
        var path = String(text[..<sign]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if path.isEmpty {
            path = defaultProject.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        guard !path.isEmpty else {
            return .failure(.noProject)
        }
        guard path.contains("/"), !path.contains(" ") else {
            return .failure(.notAnItem)
        }
        return .success(text[sign] == "!" ? .mergeRequest(gitLabProject: path, iid: iid) : .workItem(gitLabProject: path, iid: iid))
    }
}

/// Where a link to a build, merge request or work item opens in the main window.
public enum InAppDestination: Hashable, Sendable {
    /// a build in Pipelines, by its job's key
    case pipelines(String)
    /// a merge request in my list
    case mergeRequests(MergeRequest.ID)
    /// a work item in my lists
    case workItems(WorkItem.ID)
    /// an item outside my lists, under "Opened"
    case opened(OpenedItem.ID)
}

extension AppModel {
    /// Finds where a build, merge request or work item opens in the app: in its list when it is there, else under
    /// "Opened", where it is added for the time (WIN-06). ``LinkDecision`` decides.
    ///
    /// - Parameters:
    ///   - route: a build, job, merge request or work item, as ``LinkRouter`` names them
    ///   - link: the link it came from, whose host picks the GitLab instance of a merge request or work item; `nil` takes
    ///     the one of the first project
    ///   - optionHeld: whether ⌥ is held, which sends every link to the browser
    /// - Returns: the place; `nil` for the browser: any other route, ⌥, a job outside the lists, or no GitLab or Jenkins
    ///   URL in Team to load the item from
    public func destination(for route: LinkRoute, link: URL? = nil, optionHeld: Bool = false) -> InAppDestination? {
        switch route {
        case .jenkinsBuild(let project, let job, let number):
            let listed = listedJob(project: project, job: job, number: number)
            let page = team.project(project)?.team.jenkinsJob.map { AlertContent.buildURL(job: job, number: number, jobURL: $0) }
            switch LinkDecision.decide(route, optionHeld: optionHeld, isListed: listed != nil, canOpen: page != nil) {
            case .list: return listed.map(InAppDestination.pipelines)
            case .opened: return page.map { .opened(opened.openBuild(project: project, job: job, number: number, webURL: $0)) }
            case .browser: return nil
            }
        case .jenkinsJob(let project, let job):
            let listed = listedJob(project: project, job: job, number: nil)
            guard LinkDecision.decide(route, optionHeld: optionHeld, isListed: listed != nil, canOpen: false) == .list else {
                return nil
            }
            return listed.map(InAppDestination.pipelines)
        case .mergeRequest(let project, let number):
            let reference = "\(project)!\(number)".lowercased()
            let found = mergeRequests.list?.mergeRequests.first { $0.reference.lowercased() == reference }
            return gitLabDestination(
                route, kind: .mergeRequest, project: project, iid: number, link: link, optionHeld: optionHeld,
                listed: found.map { .mergeRequests($0.id) })
        case .workItem(let project, let number):
            let reference = "\(project)#\(number)".lowercased()
            let found = workItems.lists?.all.first { $0.reference.lowercased() == reference }
            return gitLabDestination(
                route, kind: .workItem, project: project, iid: number, link: link, optionHeld: optionHeld,
                listed: found.map { .workItems($0.id) })
        case .pipeline, .browser:
            return nil
        }
    }

    /// Returns the GitLab page of a merge request or work item that a reference names, on the GitLab of the first project:
    /// where ⌥ sends a direct hit of the window's search (WIN-07).
    ///
    /// - Parameter route: a merge request or work item, as ``OpenByLink`` reads it
    /// - Returns: the page; `nil` for any other route or without a GitLab URL in Team
    public func gitLabPage(of route: LinkRoute) -> URL? {
        guard let gitLab = gitLab(for: nil) else {
            return nil
        }
        switch route {
        case .mergeRequest(let project, let iid):
            return gitLab.appending(path: project).appending(path: "-/merge_requests").appending(path: String(iid))
        case .workItem(let project, let iid):
            return gitLab.appending(path: project).appending(path: "-/issues").appending(path: String(iid))
        default:
            return nil
        }
    }

    private func gitLabDestination(
        _ route: LinkRoute, kind: OpenedItem.Kind, project: String, iid: Int, link: URL?, optionHeld: Bool,
        listed: InAppDestination?
    ) -> InAppDestination? {
        let gitLab = gitLab(for: link)
        switch LinkDecision.decide(route, optionHeld: optionHeld, isListed: listed != nil, canOpen: gitLab != nil) {
        case .list:
            return listed
        case .opened:
            guard let gitLab else {
                return nil
            }
            let page = gitLab.appending(path: project).appending(path: kind == .mergeRequest ? "-/merge_requests" : "-/issues")
                .appending(path: String(iid))
            return .opened(opened.open(kind: kind, project: project, iid: iid, webURL: page))
        case .browser:
            return nil
        }
    }

    /// Returns the job's key when Pipelines lists it: a build of mine or a watched one that isn't hidden, or a watched job
    /// still waiting for its first answer. With a number, the listed build must be that one: the list shows each job's
    /// last build only.
    private func listedJob(project: ProjectID, job: String, number: Int?) -> String? {
        guard let store = projects.store(for: project) else {
            return nil
        }
        let key = BuildID.jobKey(job, project: project)
        if let build = (store.myBuilds + store.watchedBuilds).first(where: { $0.job == job }) {
            return number == nil || build.number == number ? key : nil
        }
        if number == nil, store.userState.watched.contains(where: { $0.job == job }) {
            return key
        }
        return nil
    }

    /// the GitLab instance of the project whose host a link has, else the first project's
    private func gitLab(for link: URL?) -> URL? {
        let projects = team.projects()
        if let host = link?.host(percentEncoded: false)?.lowercased(),
            let match = projects.compactMap(\.team.gitLab).first(where: { $0.host(percentEncoded: false)?.lowercased() == host })
        {
            return match
        }
        return team.primaryProject().team.gitLab
    }
}

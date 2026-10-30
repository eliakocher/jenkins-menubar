import Foundation
import Observation

// MARK: - The values

/// A work item that a merge request or a build leads to: the app connects the three everywhere (the user, 2026-10-30).
public struct LinkedWorkItem: Codable, Hashable, Identifiable, Sendable {
    /// How the connection is known, strongest first.
    public enum Origin: String, Codable, Hashable, Sendable {
        /// the team's convention: the merge request's title starts with the work item's reference
        case title
        /// GitLab's own link: the merge request closes the work item when it merges
        case closes
        /// GitLab's own link: the merge request mentions the work item (title, description, commits, comments)
        case related
        /// the work item's related merge requests, which the Work Items section loaded, name this merge request
        case mentions
    }

    /// the project's full path, like `group/project`
    public var project: String
    public var iid: Int
    /// the work item's title when the app knows it
    public var title: String?
    /// the work item's page; `nil` when the GitLab URL isn't known
    public var webURL: URL?
    public var origin: Origin

    public init(project: String, iid: Int, title: String? = nil, webURL: URL? = nil, origin: Origin) {
        self.project = project
        self.iid = iid
        self.title = title
        self.webURL = webURL
        self.origin = origin
    }

    /// the full reference, like `group/project#123`
    public var reference: String { "\(project)#\(iid)" }

    /// the same work item for every origin, in any case
    public var id: String { reference.lowercased() }

    /// "#123" in the team's project, "other#123" in another
    ///
    /// - Parameter project: the team's project path
    public func shortReference(project: String) -> String {
        GitLabText.shortReference(reference, project: project)
    }
}

/// The merge request of a build, as the build's job and Jenkins name it.
public struct LinkedMergeRequest: Hashable, Sendable {
    /// the full reference, like `group/project!12`
    public var reference: String
    public var project: String
    public var iid: Int
    public var webURL: URL
    /// Jenkins' name of the merge request, its title; `nil` when Jenkins has none
    public var title: String?

    public init(project: String, iid: Int, webURL: URL, title: String?) {
        self.project = project
        self.iid = iid
        self.webURL = webURL
        self.title = title
        reference = "\(project)!\(iid)"
    }

    /// "!12" in the team's project, "other!12" in another
    ///
    /// - Parameter project: the team's project path
    public func shortReference(project: String) -> String {
        GitLabText.shortReference(reference, project: project)
    }
}

// MARK: - The title convention

/// Reads the work item references at the start of a merge request's title: the team writes `#19202 Dialog bot…`, and
/// `group/project#123` for a work item of another project.
public enum WorkItemTitleReferences {
    /// One reference of a title.
    public struct Reference: Hashable, Sendable {
        /// the project's path; `nil` for a bare `#123`, which means the merge request's own project
        public var project: String?
        public var iid: Int

        public init(project: String? = nil, iid: Int) {
            self.project = project
            self.iid = iid
        }
    }

    /// Returns the references a title starts with.
    ///
    /// A leading `Draft:`, `[Draft]` or `WIP:` is skipped. References follow one another, separated by spaces, commas,
    /// `+` or `&`, and may be in brackets or followed by a colon: `[#12, #13]: Fix`. The first word that isn't a
    /// reference ends them, so a number in the middle of a title is no work item.
    ///
    /// - Parameter title: the merge request's title
    /// - Returns: the references in order, each once
    public static func parse(_ title: String) -> [Reference] {
        var rest = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
        // A draft marker isn't part of the convention.
        while let stripped = Self.withoutDraftMarker(rest) {
            rest = stripped
        }
        var found: [Reference] = []
        let opening = CharacterSet(charactersIn: "[(")
        let separators = CharacterSet(charactersIn: " \t,+&:])")
        while true {
            rest = rest.drop { $0.unicodeScalars.allSatisfy { opening.contains($0) || separators.contains($0) } }
            guard let (reference, tail) = Self.reference(at: rest) else {
                break
            }
            if !found.contains(reference) {
                found.append(reference)
            }
            rest = tail
        }
        return found
    }

    private static func withoutDraftMarker(_ text: Substring) -> Substring? {
        for marker in ["draft:", "[draft]", "(draft)", "draft ", "wip:", "[wip]"] where text.lowercased().hasPrefix(marker) {
            return text.dropFirst(marker.count).drop { $0 == " " }
        }
        return nil
    }

    /// Reads `#123` or `path/with/slash#123` at the start, when digits end at a boundary.
    private static func reference(at text: Substring) -> (Reference, Substring)? {
        guard let hash = text.firstIndex(of: "#") else {
            return nil
        }
        let path = text[..<hash]
        let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        guard path.unicodeScalars.allSatisfy(pathCharacters.contains), path.isEmpty || path.contains("/") else {
            return nil
        }
        let afterHash = text[text.index(after: hash)...]
        let digits = afterHash.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let iid = Int(digits), iid > 0 else {
            return nil
        }
        let tail = afterHash.dropFirst(digits.count)
        // `#123abc` and `#123_x` are something else.
        if let next = tail.first, next.isLetter || next.isNumber || next == "_" {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (Reference(project: trimmed.isEmpty ? nil : trimmed, iid: iid), tail)
    }
}

// MARK: - The resolver

/// What the app knows about the work items of a merge request, besides its title.
public struct WorkItemEvidence: Sendable {
    /// the issues GitLab says the merge request closes
    public var closes: [LinkedWorkItem]
    /// the issues GitLab relates to it
    public var related: [LinkedWorkItem]
    /// the full references of the work items whose related merge requests name it
    public var mentionedBy: [String]

    public init(closes: [LinkedWorkItem] = [], related: [LinkedWorkItem] = [], mentionedBy: [String] = []) {
        self.closes = closes
        self.related = related
        self.mentionedBy = mentionedBy
    }
}

/// Finds the work items of a merge request, and the merge request and work items of a build. Pure: the stores bring
/// what they know, the views and the tests get the same answers.
public enum ItemLinks {
    /// Returns the work items of a merge request.
    ///
    /// The title's references come first (the team's convention), then the issues GitLab says it closes. Only when
    /// neither names one, GitLab's looser links count: the issues related to it, and the work items whose related merge
    /// requests list it, as the title of a merge request that mentions many items would make a long strip of chips. A
    /// merge request with the team's ignored prefix, like an automatic cascade, never gets those.
    ///
    /// - Parameters:
    ///   - reference: the merge request's full reference, like `group/project!12`; its project is the one of a bare `#123`
    ///   - title: the merge request's title; `nil` when not known
    ///   - evidence: what GitLab and the stores say
    ///   - ignoredPrefix: the title prefix of merge requests that don't count (Team); empty counts every one
    ///   - gitLab: the GitLab instance, to make the pages of work items GitLab didn't name
    ///   - titleOf: a work item's title by its lowercase full reference, from the lists
    /// - Returns: the work items, each once, in that order
    public static func workItems(
        ofMergeRequest reference: String, title: String?, evidence: WorkItemEvidence = WorkItemEvidence(),
        ignoredPrefix: String = "", gitLab: URL? = nil, titleOf: (String) -> String? = { _ in nil }
    ) -> [LinkedWorkItem] {
        let ownProject = project(ofReference: reference)
        let fromTitle: [LinkedWorkItem] = WorkItemTitleReferences.parse(title ?? "").compactMap { parsed in
            (parsed.project ?? ownProject).map { LinkedWorkItem(project: $0, iid: parsed.iid, origin: .title) }
        }
        var items = unique(fromTitle + evidence.closes)
        let ignored = !ignoredPrefix.isEmpty && (title?.hasPrefix(ignoredPrefix) ?? false)
        if items.isEmpty, !ignored {
            let mentions = evidence.mentionedBy.compactMap(workItem(ofReference:))
            items = unique(evidence.related + mentions)
        }
        return items.map { item in
            var item = item
            item.title = item.title ?? titleOf(item.id)
            item.webURL = item.webURL ?? gitLab.map {
                $0.appending(path: item.project).appending(path: "-/issues").appending(path: String(item.iid))
            }
            return item
        }
    }

    /// Returns the merge request of a build: the `MR-<n>` job of a project, as its Jenkins link names it, else as the
    /// project's team values build its page.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - team: the values of the build's project
    /// - Returns: the merge request; `nil` for a branch job, or without a GitLab URL to name its page
    public static func mergeRequest(ofBuild build: Build, team: TeamValues) -> LinkedMergeRequest? {
        guard let iid = build.mergeRequestIID else {
            return nil
        }
        if let url = build.gitLabURL,
            case .mergeRequest(let project, let linked) = LinkRouter(projects: [Project(id: build.project, team: team)]).route(url)
        {
            return LinkedMergeRequest(project: project, iid: linked, webURL: url, title: build.title)
        }
        let path = team.gitLabProject.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let gitLab = team.gitLab, !path.isEmpty else {
            return nil
        }
        let page = gitLab.appending(path: path).appending(path: "-/merge_requests").appending(path: String(iid))
        return LinkedMergeRequest(project: path, iid: iid, webURL: page, title: build.title)
    }

    /// Returns the work items of a build: those of its merge request.
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - team: the values of the build's project
    ///   - title: the merge request's title when a list has it, which Jenkins' name of the build may lack
    ///   - evidence: what GitLab and the stores say about the merge request
    ///   - gitLab: see ``workItems(ofMergeRequest:title:evidence:ignoredPrefix:gitLab:titleOf:)``
    ///   - titleOf: see ``workItems(ofMergeRequest:title:evidence:ignoredPrefix:gitLab:titleOf:)``
    /// - Returns: the work items; empty for a branch job
    public static func workItems(
        ofBuild build: Build, team: TeamValues, title: String? = nil, evidence: WorkItemEvidence = WorkItemEvidence(),
        gitLab: URL? = nil, titleOf: (String) -> String? = { _ in nil }
    ) -> [LinkedWorkItem] {
        guard let mergeRequest = mergeRequest(ofBuild: build, team: team) else {
            return []
        }
        return workItems(
            ofMergeRequest: mergeRequest.reference, title: title ?? mergeRequest.title, evidence: evidence,
            ignoredPrefix: team.ignoredMergeRequestPrefix, gitLab: gitLab ?? team.gitLab, titleOf: titleOf)
    }

    /// "group/project" of `group/project!12`
    static func project(ofReference reference: String) -> String? {
        guard let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" }), sign > reference.startIndex else {
            return nil
        }
        return String(reference[..<sign])
    }

    /// the work item of a full reference like `group/project#12`
    private static func workItem(ofReference reference: String) -> LinkedWorkItem? {
        guard !reference.contains("&"), let sign = reference.lastIndex(of: "#"), let project = project(ofReference: reference),
            let iid = Int(reference[reference.index(after: sign)...])
        else {
            return nil
        }
        return LinkedWorkItem(project: project, iid: iid, origin: .mentions)
    }

    private static func unique(_ items: [LinkedWorkItem]) -> [LinkedWorkItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}

extension RelatedMergeRequestsCache {
    /// Returns the work items whose related merge requests name a merge request: the other way round of the cache.
    ///
    /// - Parameter mergeRequest: the merge request's full reference, like `group/project!12`
    /// - Returns: the work items' full references, sorted for a steady order
    public func workItems(mentioning mergeRequest: String) -> [String] {
        let wanted = mergeRequest.lowercased()
        return entries.filter { $0.value.mergeRequests.contains { $0.reference.lowercased() == wanted } }.keys.sorted()
    }
}

// MARK: - GitLab's links

/// What GitLab says about the work items of a merge request.
public struct GitLabWorkItemLinks: Hashable, Sendable {
    public var closes: [LinkedWorkItem]
    public var related: [LinkedWorkItem]

    public init(closes: [LinkedWorkItem] = [], related: [LinkedWorkItem] = []) {
        self.closes = closes
        self.related = related
    }
}

/// One issue of GitLab's `closes_issues` and `related_issues` answers.
struct LinkedIssueShape: Decodable {
    var iid: Int
    var title: String?
    var webURL: URL?
    var references: References?

    struct References: Decodable {
        var full: String?
    }

    private enum CodingKeys: String, CodingKey {
        case iid, title, references
        case webURL = "web_url"
    }

    /// Returns the work item: its project from the full reference, else from the page's path before `/-/`.
    func workItem(origin: LinkedWorkItem.Origin) -> LinkedWorkItem? {
        var project: String?
        if let full = references?.full, let sign = full.lastIndex(of: "#"), full[..<sign].contains("/") {
            project = String(full[..<sign])
        } else if let webURL {
            let segments = webURL.path(percentEncoded: false).split(separator: "/").map(String.init)
            if let dash = segments.firstIndex(of: "-"), dash >= 2 {
                project = segments[..<dash].joined(separator: "/")
            }
        }
        // The GitLab instance may sit under a path; the full reference is then the way, and without it the page's own
        // path is as good as GitLab's.
        guard let project else {
            return nil
        }
        return LinkedWorkItem(project: project, iid: iid, title: title, webURL: webURL, origin: origin)
    }
}

extension GitLabClient {
    /// Asks GitLab which issues a merge request closes and which it relates to: `GET /projects/:path/merge_requests/:iid/
    /// closes_issues` and `.../related_issues` (GitLab's REST reference, both listed under merge requests). Neither is
    /// paged here: a merge request names a handful.
    ///
    /// The closing issues decide: when they fail the whole call fails. The related ones are the looser link, and a GitLab
    /// without that endpoint just has none.
    ///
    /// - Parameter source: the merge request
    /// - Returns: the links
    /// - Throws: ``GitLabError`` when GitLab didn't answer the closing issues
    public func workItemLinks(of source: DescriptionSource) async throws -> GitLabWorkItemLinks {
        let closes = try await linkedIssues(of: source, endpoint: "closes_issues", origin: .closes)
        let related = (try? await linkedIssues(of: source, endpoint: "related_issues", origin: .related)) ?? []
        return GitLabWorkItemLinks(closes: closes, related: related)
    }

    private func linkedIssues(
        of source: DescriptionSource, endpoint: String, origin: LinkedWorkItem.Origin
    ) async throws -> [LinkedWorkItem] {
        guard let (path, iid) = source.pathAndIID, var components = URLComponents(url: restBase, resolvingAgainstBaseURL: false)
        else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        // The project's path is one segment of the URL, its slashes encoded.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let project = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        components.percentEncodedPath += "/projects/\(project)/merge_requests/\(iid)/\(endpoint)"
        guard let url = components.url else {
            throw GitLabError(.httpStatus(.gitLab, status: 404))
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(
                    method: "GET", url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
                    timeout: timeout,
                    // Marks the request as GitLab's for the logs, which tell the servers apart by it.
                    graphQL: GraphQLOperation(name: "MergeRequest\(origin == .closes ? "ClosesIssues" : "RelatedIssues")", variables: "{}")))
        } catch is TransportError {
            throw GitLabError(.unreachable(.gitLab))
        }
        guard response.status == 200, let issues = try? JSONDecoder().decode([LinkedIssueShape].self, from: response.body) else {
            throw GitLabError(.httpStatus(.gitLab, status: response.status))
        }
        return issues.compactMap { $0.workItem(origin: origin) }
    }
}

// MARK: - The store

/// GitLab's links from merge requests to work items, loaded when a merge request or a build of one is shown, kept in
/// memory per merge request.
///
/// The links are kept for the merge request's last update when it is known (every push and every new mention updates
/// it), else for ``maxAge``. A failed request is asked again after ``retryAfter``, so a rejected token isn't asked at
/// every redraw.
@Observable @MainActor
public final class LinkedWorkItemsStore {
    /// how long links stay for a merge request whose update isn't known, such as a build's
    public static let maxAge: TimeInterval = 10 * 60
    /// how long after a failure the next request waits
    public static let retryAfter: TimeInterval = 60

    private struct Entry {
        var links: GitLabWorkItemLinks?
        var loadedAt: Date?
        /// the merge request's `updatedAt` the links belong to, when it was known
        var updatedAt: Date?
        var isLoading = false
        var failedAt: Date?
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private let services: GitLabServices

    /// - Parameter services: the transport, the token and the team values; the logs record the requests
    public init(services: GitLabServices) {
        self.services = services
    }

    /// Returns what GitLab said of a merge request, also an older answer.
    ///
    /// - Parameter reference: the merge request's full reference, like `group/project!12`
    /// - Returns: the links; `nil` before an answer
    public func links(of reference: String) -> GitLabWorkItemLinks? {
        entries[reference.lowercased()]?.links
    }

    /// Loads the links of a merge request, unless they are loading, or fresh. Without a GitLab token or the team values
    /// it asks nothing and fails quietly. Cancelling the calling task doesn't cancel the request.
    ///
    /// - Parameters:
    ///   - reference: the merge request's full reference
    ///   - webURL: the merge request's page
    ///   - updatedAt: when the merge request last changed; `nil` when only its build is known
    public func load(reference: String, webURL: URL, updatedAt: Date? = nil) async {
        let key = reference.lowercased()
        var entry = entries[key] ?? Entry()
        let now = services.now()
        if entry.isLoading || entry.failedAt.map({ now.timeIntervalSince($0) < Self.retryAfter }) == true {
            return
        }
        if entry.links != nil, let loadedAt = entry.loadedAt {
            let isFresh = updatedAt.map { (entry.updatedAt ?? .distantPast) >= $0 } ?? (now.timeIntervalSince(loadedAt) < Self.maxAge)
            if isFresh {
                return
            }
        }
        let source = DescriptionSource(kind: .mergeRequest, reference: reference, webURL: webURL, updatedAt: updatedAt ?? now)
        guard source.pathAndIID != nil else {
            return
        }
        entry.isLoading = true
        entries[key] = entry
        let services = services
        let links = await Task { () -> GitLabWorkItemLinks? in
            guard let client = try? await services.session().get().client else {
                return nil
            }
            return try? await client.workItemLinks(of: source)
        }.value
        entry = entries[key] ?? Entry()
        entry.isLoading = false
        if let links {
            entry.links = links
            entry.loadedAt = now
            entry.updatedAt = updatedAt ?? now
            entry.failedAt = nil
        } else {
            entry.failedAt = now
        }
        entries[key] = entry
    }
}

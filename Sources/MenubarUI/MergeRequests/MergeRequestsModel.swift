import Foundation
import MenubarCore

/// Everything the Merge Requests section shows, as plain values: what the stores hold at one moment. The public views
/// take it from the stores; the gallery and the tests build it from fixtures.
struct MergeRequestsData: Sendable {
    /// the time the ages count from
    var now: Date
    var team: TeamValues
    /// `PipelinesStore.problem`: offline, the team values or Jenkins' own, for the app-wide rows
    var jenkinsProblem: Problem?
    /// where the app's update stands, for "Update failed" (APP-05)
    var update: UpdateState
    /// my merge requests, from `MergeRequestsStore`
    var mergeRequests: PanelData.MergeRequests
    /// the builds Pipelines shows, mine first, then the watched ones; the MR detail finds its Jenkins build here
    var builds: [Build]
    /// my jobs, `nil` before the first Jenkins lookup, and the jobs watched now: "Watch Builds" on an MR (WATCH-01)
    var myJobs: [String]?
    var watchedJobs: [String]
    /// the Jenkins side of the projects, to find an MR's own project (plan Phase 13)
    var jenkins: PanelData.Jenkins

    /// Returns the section's part of the panel's values, which the main window's shell takes too.
    ///
    /// - Parameter panel: the stores' values, as ``PanelView`` takes them
    init(_ panel: PanelData) {
        now = panel.now
        team = panel.team
        jenkinsProblem = panel.jenkins.problem
        update = panel.update
        mergeRequests = panel.mergeRequests
        builds = panel.jenkins.mine + panel.jenkins.watched
        myJobs = panel.jenkins.myJobs
        watchedJobs = panel.jenkins.watchedJobs
        jenkins = panel.jenkins
    }

    /// Returns what the stores hold now.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - now: the time the ages count from
    @MainActor
    init(_ model: AppModel, now: Date) {
        self.init(PanelView.data(model, now: now))
    }

    /// whether the section shows its own data: not while the team values are missing (TEAM-03) or the GitLab token is
    /// (MR-04)
    var showsMergeRequests: Bool {
        !MainWindowProblems.teamValuesMissing(jenkinsProblem) && mergeRequests.problem != .noToken(.gitLab)
    }
}

/// What the Merge Requests list shows of a ``MergeRequestsData``, after the search: the problem rows, MR-04's setup
/// steps, MR-01's sections, the link row, or the empty state (`docs/design/merge-requests.md`, List).
struct MergeRequestsListModel: Sendable {
    /// the red rows on top: the app-wide ones, then MR-05's
    var problems: [PanelModel.ProblemItem]
    /// MR-04's note and steps without a GitLab token
    var setup: Setup?
    /// two placeholder rows: never loaded (OD-01)
    var isPlaceholder: Bool
    /// the sections that have rows after the search, in MR-01's order
    var sections: [PanelModel.Subsection<MergeRequestRowModel>]
    /// "No open merge requests" with the link as its action: loaded, and nothing open
    var emptyLink: URL?
    /// whether the empty state shows
    var showsEmpty: Bool
    /// "All Merge Requests in GitLab", the last row; `nil` while searching, without a token or while empty
    var link: URL?
    /// the search text, trimmed
    var query: String

    /// MR-04's setup steps.
    struct Setup: Hashable, Sendable {
        /// the page that creates the token, step 1; `nil` without a GitLab URL in Team
        var newTokenURL: URL?
    }

    /// whether a search finds nothing, which shows the system's no-results view
    var findsNothing: Bool {
        !query.isEmpty && setup == nil && !isPlaceholder && sections.isEmpty && !showsEmpty
    }

    /// whether the "In GitLab" search may show: GitLab is asked only with the team values and the token (WIN-07)
    var showsGitLabSearch: Bool {
        !query.isEmpty && setup == nil
    }

    /// Returns the row with an id.
    ///
    /// - Parameter id: the MR's web URL
    /// - Returns: the row, or `nil` when no section has it
    func row(_ id: MergeRequest.ID?) -> MergeRequestRowModel? {
        guard let id else {
            return nil
        }
        return sections.lazy.flatMap(\.rows).first { $0.id == id }
    }

    /// Returns what the list shows.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - query: the window's search text; empty shows everything
    init(_ data: MergeRequestsData, query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        problems = MainWindowProblems.appWide(jenkins: data.jenkinsProblem, update: data.update)
        setup = nil
        isPlaceholder = false
        sections = []
        emptyLink = nil
        showsEmpty = false
        link = nil
        // TEAM-03 shows alone: nothing can be asked without the values.
        guard !MainWindowProblems.teamValuesMissing(data.jenkinsProblem) else {
            return
        }
        let state = data.mergeRequests
        let offline = data.jenkinsProblem == .offline
        let needsToken = state.problem == .noToken(.gitLab)
        // Offline shows the cached MRs without other problem rows (OD-05); a missing token shows the steps instead.
        if !offline, !needsToken, let problem = state.problem {
            problems.append(PanelModel.problemItem(problem))
        }
        let gitLabLink = data.team.gitLab.map { GitLabLinks.mergeRequests(gitLab: $0) }
        if needsToken {
            setup = Setup(newTokenURL: data.team.gitLab.map { GitLabLinks.newToken(gitLab: $0) })
            return
        }
        guard let list = state.list else {
            // Never loaded: placeholders, unless a problem or offline explains why nothing came.
            isPlaceholder = state.problem == nil && !offline && query.isEmpty
            link = query.isEmpty ? gitLabLink : nil
            return
        }
        let all = MergeRequestSections(list.mergeRequests, me: list.username)
        let project = data.team.gitLabProject
        sections = all.sections.map { section in
            let rows = section.mergeRequests
                .map { MergeRequestRowModel($0, me: list.username, project: project, now: data.now) }
                .filter { $0.matches(query) }
            return PanelModel.Subsection(title: section.title, rows: rows)
        }
        .filter { !$0.rows.isEmpty }
        if all.isEmpty, query.isEmpty {
            showsEmpty = true
            emptyLink = gitLabLink
        } else if query.isEmpty {
            link = gitLabLink
        }
    }
}

/// A merge request's row: the MR-02 badge, the title, and the MR-03 details in two parts, so the reference and the
/// badge text truncate last.
struct MergeRequestRowModel: Hashable, Sendable, Identifiable {
    var mergeRequest: MergeRequest
    var status: MergeRequestStatus
    /// "!21", or "web!8" for another project (MR-03)
    var shortReference: String
    /// "!21 · Ready to merge"
    var lead: String
    /// "by Sam Lee · updated 5m ago · 3 files +10 −2 · pipeline success"
    var rest: String
    /// "Open Merge Request !21 in GitLab"
    var openTitle: String
    /// whether I wrote it, so a line can leave out "by …"
    var isMine: Bool

    var id: MergeRequest.ID { mergeRequest.id }

    /// the MR-03 details in one line, as the panel's tooltip has them
    var details: String { rest.isEmpty ? lead : "\(lead) · \(rest)" }

    /// - Parameters:
    ///   - mergeRequest: the MR
    ///   - me: my GitLab username
    ///   - project: the team's project path
    ///   - now: the time the age counts from
    init(_ mergeRequest: MergeRequest, me: String, project: String, now: Date) {
        self.mergeRequest = mergeRequest
        status = MergeRequestStatus.of(mergeRequest, me: me)
        shortReference = mergeRequest.shortReference(project: project)
        lead = "\(shortReference) · \(status.text)"
        let details = mergeRequest.details(me: me, project: project, now: now)
        // The details start with the reference and the badge text; the rest truncates first.
        rest = details.hasPrefix(lead + " · ") ? String(details.dropFirst(lead.count + 3)) : ""
        openTitle = "Open Merge Request \(shortReference) in GitLab"
        isMine = mergeRequest.author.username == me
    }

    /// Returns whether the row matches a search: its title, its short reference or its author's name, ignoring case
    /// (`docs/design/merge-requests.md`, Search; WIN-03).
    ///
    /// - Parameter query: the trimmed search text; empty matches
    func matches(_ query: String) -> Bool {
        PanelModel.matches(query, [mergeRequest.title, shortReference, mergeRequest.author.name])
    }
}

/// What the Merge Requests detail shows of the selected MR (`docs/design/merge-requests.md`, Detail): the header, the
/// facts, its Jenkins build, the reviewers and the links. Built from the store's values only, so selecting asks
/// nothing.
struct MergeRequestDetailModel: Sendable {
    var mergeRequest: MergeRequest
    var status: MergeRequestStatus
    /// "Open Merge Request !14"
    var openTitle: String
    /// the project's name without its group, "project", which the header shows before the iid
    var projectName: String
    /// the head pipeline's status; `nil` shows "No pipeline"
    var pipeline: PipelineFact?
    /// the MR's build while Pipelines shows it (WIN-02); `nil` shows no row
    var jenkinsBuild: JenkinsBuildFact?
    /// what the Jenkins build row offers for watching the MR's builds (WATCH-01)
    var watch: MergeRequestWatch
    /// "3 files +10 −2" (MR-03's text)
    var changes: String
    /// the easter egg line under the diff stats (EGG-19); set by the view, `nil` for none
    var eggLine: String?
    /// the work items of the merge request: its title's references and GitLab's links (MR-12); set by the view, since it
    /// reads the lists and GitLab's answers
    var workItems: [LinkedWorkItem] = []
    /// "Sam Lee", mine "Jane Doe (me)"
    var author: String
    /// "5m ago"
    var updated: String
    /// me first, then GitLab's order; empty shows "No reviewers yet"
    var reviewers: [ReviewerRow]
    /// GitLab's Changes tab of the MR
    var changesURL: URL
    /// GitLab's Pipelines tab of the MR
    var pipelinesURL: URL
    /// GitLab's new-token page with the name and the `api` scope filled in, for a re-request the token can't make (MR-09)
    var newTokenURL: URL?

    /// the note without reviewers (MR-02's text)
    static let noReviewers = "No reviewers yet"

    /// The head pipeline's status, in the pipeline symbols of `docs/design/merge-requests.md` (SF Symbols).
    struct PipelineFact: Hashable, Sendable {
        var symbol: String
        var tint: Tint
        /// GitLab's value in lowercase, `_` as spaces: "success", "waiting for resource"
        var word: String

        /// Returns the fact of a pipeline status.
        init(_ status: MergeRequest.PipelineStatus) {
            word = status.rawValue.lowercased().replacingOccurrences(of: "_", with: " ")
            switch status.rawValue {
            case "SUCCESS": (symbol, tint) = ("checkmark.circle", .green)
            case "FAILED": (symbol, tint) = ("xmark.circle.fill", .red)
            case "RUNNING": (symbol, tint) = ("hourglass", .label)
            case "CANCELED", "CANCELING": (symbol, tint) = ("stop.circle", .secondary)
            case "SKIPPED": (symbol, tint) = ("minus.circle", .secondary)
            case "MANUAL": (symbol, tint) = ("pause.circle", .secondary)
            case "CREATED", "PENDING", "PREPARING", "SCHEDULED", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK":
                (symbol, tint) = ("clock", .secondary)
            default: (symbol, tint) = ("questionmark.circle", .secondary)
            }
        }
    }

    /// A symbol's color: a system color, the label color or `.secondary`.
    enum Tint: Hashable, Sendable {
        case label
        case secondary
        case green
        case red
    }

    /// The MR's Jenkins build: the one Pipelines shows whose GitLab URL is the MR's.
    struct JenkinsBuildFact: Hashable, Sendable {
        /// the build's job, which "Show in Pipelines" selects
        var job: String
        var state: BuildState
        /// "!16 #3 · FAILURE", running "!14 #3 · running"
        var text: String
        /// the header's chip: "Jenkins #3 · Failure", "Jenkins #3 · Running"
        var chip: String

        init(_ build: Build) {
            job = build.job
            state = BuildState(build)
            text = "\(build.label) #\(String(build.number)) · \(state.resultText ?? "running")"
            chip = "Jenkins #\(String(build.number)) · \((state.resultText ?? "running").capitalized)"
        }
    }

    /// A reviewer with their review.
    struct ReviewerRow: Hashable, Sendable, Identifiable {
        /// "Alex Kim", mine "Jane Doe (me)"; "@akim" from a cache without names
        var name: String
        /// "approved", "requested changes", "review started"
        var word: String
        /// the symbol for an approval or requested changes; `nil` for the other states
        var mark: Mark?
        var id: String
        /// GitLab's state of the review, which picks the chip's glyph
        var state: MergeRequest.ReviewState = .unreviewed
        /// whether the reviewer is me, whom the chip rings
        var isMe = false

        /// Returns the word and the symbol of a review state: "approved", "requested changes", "review started".
        static func describe(state: MergeRequest.ReviewState, approved: Bool) -> (word: String, mark: Mark?) {
            let mark: Mark? = approved || state == .approved ? .approved : state == .requestedChanges ? .requestedChanges : nil
            let word = mark == .approved ? "approved" : state.rawValue.lowercased().replacingOccurrences(of: "_", with: " ")
            return (word, mark)
        }

        enum Mark: Hashable, Sendable {
            /// `checkmark.circle.fill` in MR-02's green
            case approved
            /// `exclamationmark.circle.fill` in MR-02's orange
            case requestedChanges
        }
    }

    /// Returns the detail of the selected MR.
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - selection: the selected MR, by its web URL
    /// - Returns: the detail; `nil` without a selection, or when the MR isn't in the list (merged, closed, the token
    ///   removed), which shows a blank detail
    init?(_ data: MergeRequestsData, selection: MergeRequest.ID?) {
        guard let selection, data.showsMergeRequests, let list = data.mergeRequests.list,
            let mergeRequest = list.mergeRequests.first(where: { $0.id == selection })
        else {
            return nil
        }
        self.init(data, mergeRequest: mergeRequest, me: list.username)
    }

    /// Returns the detail of a merge request that isn't in the list, one opened under "Opened" (WIN-06).
    ///
    /// - Parameters:
    ///   - data: the stores' values
    ///   - mergeRequest: the merge request, as loaded for itself
    ///   - me: my username; `nil` takes the one of the last list load, or none before it
    init(_ data: MergeRequestsData, mergeRequest: MergeRequest, me: String? = nil) {
        let me = me ?? data.mergeRequests.list?.username ?? ""
        let project = data.team.gitLabProject
        self.mergeRequest = mergeRequest
        status = MergeRequestStatus.of(mergeRequest, me: me)
        openTitle = "Open Merge Request \(mergeRequest.shortReference(project: project)) in GitLab"
        projectName = Self.projectName(of: mergeRequest.reference)
        pipeline = mergeRequest.pipelineStatus.map(PipelineFact.init)
        jenkinsBuild = Self.build(of: mergeRequest, in: data.builds).map(JenkinsBuildFact.init)
        // An MR is watched in its own project; one of a project not set up offers nothing (plan Phase 13).
        watch = data.jenkins.project(of: mergeRequest).map {
            MergeRequestWatch.of(mergeRequest, me: me, myJobs: data.myJobs, watchedJobs: data.watchedJobs, project: $0)
        } ?? .hidden
        let stats = mergeRequest.diffStats ?? MergeRequest.DiffStats(additions: 0, deletions: 0, fileCount: 0)
        changes = "\(String(stats.fileCount)) file\(stats.fileCount == 1 ? "" : "s") +\(String(stats.additions)) −\(String(stats.deletions))"
        author = Self.name(mergeRequest.author.name, username: mergeRequest.author.username, me: me)
        updated = "\(GitLabText.age(since: mergeRequest.updatedAt, now: data.now)) ago"
        let mine = mergeRequest.reviewers.filter { $0.username == me }
        reviewers = (mine + mergeRequest.reviewers.filter { $0.username != me }).map { reviewer in
            let (word, mark) = ReviewerRow.describe(state: reviewer.reviewState, approved: reviewer.approved)
            return ReviewerRow(
                name: Self.name(reviewer.name, username: reviewer.username, me: me), word: word, mark: mark,
                id: reviewer.username, state: reviewer.reviewState, isMe: reviewer.username == me)
        }
        changesURL = mergeRequest.webURL.appending(path: "diffs")
        pipelinesURL = mergeRequest.webURL.appending(path: "pipelines")
        newTokenURL = data.team.gitLab.map { GitLabLinks.newToken(gitLab: $0) }
    }

    /// Returns the build Pipelines shows for an MR: the first whose GitLab URL is the MR's web URL (WIN-02). A
    /// trailing slash doesn't count.
    ///
    /// - Parameters:
    ///   - mergeRequest: the MR
    ///   - builds: the builds Pipelines shows, mine first
    /// - Returns: the build, or `nil`
    static func build(of mergeRequest: MergeRequest, in builds: [Build]) -> Build? {
        let target = Self.comparable(mergeRequest.webURL)
        return builds.first { $0.gitLabURL.map(Self.comparable) == target }
    }

    /// "project" of `group/subgroup/project!16`
    private static func projectName(of reference: String) -> String {
        let path = reference.split(separator: "!").first.map(String.init) ?? reference
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func comparable(_ url: URL) -> String {
        var text = url.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// "Sam Lee", "Jane Doe (me)", or "@akim" without a name.
    private static func name(_ name: String, username: String, me: String) -> String {
        let shown = name.isEmpty ? "@\(username)" : name
        return username == me ? "\(shown) (me)" : shown
    }
}

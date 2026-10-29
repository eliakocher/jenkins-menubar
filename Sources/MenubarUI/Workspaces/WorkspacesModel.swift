import Foundation
import MenubarCore

/// What the Workspaces section draws from (WS-01 to WS-05): the checkouts with their git readings, and the merge
/// requests, work items and builds the app knows already. Plain values, so the gallery and the tests fill it too.
struct WorkspacesData: Sendable {
    var settings: RepositorySettings
    var findings: [FolderFindings]
    var readings: [Checkout.ID: CheckoutReading]
    var isRefreshing: Bool
    var lastRefreshAt: Date?
    var actionProblems: [Checkout.ID: String] = [:]
    var openingInIDE: Set<Checkout.ID> = []
    /// each checkout's local branches, read when its detail shows (WS-06)
    var branches: [Checkout.ID: LocalBranchesReading] = [:]
    var startingWork: Set<Checkout.ID> = []
    var actionNotes: [Checkout.ID: String] = [:]
    /// the GitLab instance and the project's path from Team, for the new merge request page; `nil` and empty without
    var gitLab: URL?
    var gitLabProject = ""
    var mergeRequests: [MergeRequest]
    var workItems: [WorkItem]
    var builds: [Build]
    /// my GitLab username, for the merge request's status badge
    var me: String
    var home: URL
    var now: Date

    /// every checkout, in the entries' order
    var checkouts: [Checkout] {
        findings.flatMap(\.checkouts)
    }
}

extension WorkspacesData {
    /// Reads the stores.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - now: the current time
    @MainActor
    init(_ model: AppModel, now: Date) {
        let store = model.workspaces
        self.init(
            settings: store.settings, findings: store.findings, readings: store.readings,
            isRefreshing: store.isRefreshing, lastRefreshAt: store.lastRefreshAt, actionProblems: store.actionProblems,
            openingInIDE: store.openingInIDE, branches: store.branchReadings, startingWork: store.startingWork,
            actionNotes: store.actionNotes, gitLab: model.pipelines.project.team.gitLab,
            gitLabProject: model.pipelines.project.team.gitLabProject,
            mergeRequests: model.mergeRequests.list?.mergeRequests ?? [],
            workItems: model.workItems.lists?.all ?? [], builds: model.projects.myBuilds + model.projects.watchedBuilds,
            me: model.mergeRequests.list?.username ?? model.pipelines.gitLabUsername ?? "", home: store.homeFolder,
            now: now)
    }
}

/// One checkout's row and detail facts.
struct WorkspaceRowModel: Identifiable, Hashable, Sendable {
    let checkout: Checkout
    /// the row's state, which picks its tile
    var kind: Kind
    /// "#1234", from the branch; `nil` without a number
    var number: String?
    /// the work item's title, the branch's slug made readable, the branch, or "Detached HEAD"
    var title: String
    /// whether ``title`` comes from the branch because the work item isn't loaded
    var titleFromBranch: Bool
    /// the branch; `nil` for a detached HEAD or before the first reading
    var branch: String?
    /// "Clean", "1 changed file", "3 changed files"; `nil` before the first reading
    var changes: String?
    /// the changed and untracked files; `nil` before the first reading
    var changedCount: Int?
    /// "2 changed, 1 untracked" for the detail; `nil` before the first reading
    var changesInDetail: String?
    /// "2 ahead, 14 behind" of `origin/<base>`; `nil` when it is unknown
    var aheadBehind: AheadBehind?
    /// how far the local base lags `origin/<base>`; `nil` without a local base branch
    var localBaseBehind: Int?
    var hasStaleBase: Bool
    var task: WorkspaceTask
    /// the merge request's badge
    var status: MergeRequestStatus?
    /// the merge request's Jenkins build
    var build: BuildState?
    /// why git couldn't read the checkout
    var problem: String?
    /// why the last action failed
    var actionProblem: String?
    /// what the last Start Work Here did, when it worked
    var actionNote: String?
    var isOpeningInIDE: Bool
    var isStartingWork: Bool
    /// the local branches without a merge request; `nil` until read
    var localBranches: LocalBranchesModel?

    var id: Checkout.ID { checkout.id }

    /// The row's state.
    enum Kind: Hashable, Sendable {
        /// clean on its base branch: ready for the next task (WS-03)
        case free
        /// clean on a task's branch
        case working
        /// with changed or untracked files
        case changed
        /// clean, at a commit without a branch
        case detached
        /// git couldn't read it
        case problem
        /// not read yet
        case unknown
    }

    /// Ahead and behind `origin/<base>`.
    struct AheadBehind: Hashable, Sendable {
        var ahead: Int
        var behind: Int

        /// "↑2 ↓14", leaving out a zero; `nil` when both are zero
        var compact: String? {
            let parts = [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        /// "2 ahead, 14 behind", "Even"
        var words: String {
            switch (ahead, behind) {
            case (0, 0): "Even"
            case (_, 0): "\(ahead) ahead"
            case (0, _): "\(behind) behind"
            default: "\(ahead) ahead, \(behind) behind"
            }
        }
    }

    init(_ checkout: Checkout, data: WorkspacesData) {
        self.checkout = checkout
        let reading = data.readings[checkout.id]
        let state = reading?.state
        branch = state?.status.branch
        task = WorkspaceTask.match(
            branch: branch, workItems: data.workItems, mergeRequests: data.mergeRequests, builds: data.builds)
        number = task.number.map { "#\($0)" }
        status = task.mergeRequest.map { MergeRequestStatus.of($0, me: data.me) }
        build = task.build.map(BuildState.init)
        actionProblem = data.actionProblems[checkout.id]
        actionNote = data.actionNotes[checkout.id]
        isOpeningInIDE = data.openingInIDE.contains(checkout.id)
        isStartingWork = data.startingWork.contains(checkout.id)
        localBranches = data.branches[checkout.id].map { LocalBranchesModel($0, checkout: checkout, data: data) }
        if case .failed(let message) = reading {
            problem = message
        }
        localBaseBehind = state?.localBaseBehind
        hasStaleBase = state?.hasStaleBase ?? false
        if let ahead = state?.ahead, let behind = state?.behind {
            aheadBehind = AheadBehind(ahead: ahead, behind: behind)
        }
        if let state {
            let count = state.changedFiles
            changedCount = count
            changes = count == 0 ? "Clean" : "\(count) changed file\(count == 1 ? "" : "s")"
            let tracked = state.status.changedFiles
            let untracked = state.status.untrackedFiles
            changesInDetail = switch (tracked, untracked) {
            case (0, 0): "Clean"
            case (_, 0): "\(tracked) changed file\(tracked == 1 ? "" : "s")"
            case (0, _): "\(untracked) untracked file\(untracked == 1 ? "" : "s")"
            default: "\(tracked) changed, \(untracked) untracked"
            }
        }

        let isTaskBranch = branch != nil && branch != checkout.baseBranch
        titleFromBranch = isTaskBranch && task.workItem == nil && task.title != nil
        if let branch {
            title = isTaskBranch ? (task.title ?? branch) : "On \(branch)"
        } else {
            title = state == nil ? (problem == nil ? "Reading…" : "Couldn't read") : "Detached HEAD"
        }

        kind = if problem != nil {
            .problem
        } else if let state {
            if state.isFree(baseBranch: checkout.baseBranch) {
                .free
            } else if !state.isClean {
                .changed
            } else if state.status.branch == nil {
                .detached
            } else {
                .working
            }
        } else {
            .unknown
        }
    }

    /// "!87", the merge request's short reference
    var mergeRequestReference: String? {
        task.mergeRequest.map { "!\($0.iid)" }
    }

    /// "#12 · SUCCESS", "#13 · running"
    var buildText: String? {
        guard let build = task.build else {
            return nil
        }
        return "#\(build.number) · \(BuildState(build).resultText ?? "running")"
    }

    /// the checkout's path with `~` for the home folder
    func shownPath(home: URL) -> String {
        WorkspaceDiscovery.abbreviate(checkout.path, home: home)
    }

    /// the words the window's search matches: the name, the branch, the number, the title and the merge request
    func matches(_ query: String) -> Bool {
        let fields = [checkout.name, branch, number, title, mergeRequestReference, task.mergeRequest?.title]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

/// A checkout's local branches that have no merge request yet (WS-06).
struct LocalBranchesModel: Hashable, Sendable {
    var rows: [LocalBranchRow]
    /// how many local branches the checkout has, the base and those with a merge request included
    var total: Int
    /// why git couldn't list them
    var problem: String?

    init(_ reading: LocalBranchesReading, checkout: Checkout, data: WorkspacesData) {
        switch reading {
        case .failed(let message):
            rows = []
            total = 0
            problem = message
        case .read(let result):
            let open = LocalBranch.withoutMergeRequest(
                result.branches, base: checkout.baseBranch, mergeRequests: data.mergeRequests)
            rows = open.map { LocalBranchRow($0, base: checkout.baseBranch, data: data) }
            total = result.total
            problem = nil
        }
    }
}

/// One local branch: its tracking, its distance to the base and its last commit, as short sentences.
struct LocalBranchRow: Hashable, Sendable, Identifiable {
    var name: String
    var isCurrent: Bool
    /// "1 ahead, 2 behind origin/12-fix", "In sync with origin/12-fix", "On origin", "Not pushed", "Remote branch gone"
    var remote: String
    /// whether `origin` has the branch, which a merge request needs
    var isPushed: Bool
    /// "3 ahead, 40 behind origin/develop"; `nil` when git can't tell
    var base: String?
    /// the last commit's subject and age, "Fix the timeout · 5m ago"
    var lastCommit: String
    /// GitLab's new merge request page for a pushed branch; `nil` when not pushed or without Team's GitLab values
    var newMergeRequest: URL?

    var id: String { name }

    init(_ branch: LocalBranch, base: String, data: WorkspacesData) {
        name = branch.name
        isCurrent = branch.isCurrent
        isPushed = branch.isPushed
        if branch.upstreamGone {
            remote = "Remote branch gone"
        } else if let upstream = branch.upstream, let ahead = branch.aheadOfUpstream, let behind = branch.behindUpstream {
            let words = WorkspaceRowModel.AheadBehind(ahead: ahead, behind: behind).words
            remote = words == "Even" ? "In sync with \(upstream)" : "\(words) of \(upstream)"
        } else {
            remote = branch.isPushed ? "On origin" : "Not pushed"
        }
        if let ahead = branch.aheadOfBase, let behind = branch.behindBase {
            self.base = "\(WorkspaceRowModel.AheadBehind(ahead: ahead, behind: behind).words) of origin/\(base)"
                .replacingOccurrences(of: "Even of", with: "Even with")
        } else {
            self.base = nil
        }
        let age = "\(GitLabText.age(since: branch.committedAt, now: data.now)) ago"
        lastCommit = branch.subject.isEmpty ? age : "\(branch.subject) · \(age)"
        newMergeRequest = branch.isPushed
            ? data.gitLab.flatMap {
                NewMergeRequestLink.url(gitLab: $0, project: data.gitLabProject, source: branch.name, target: base)
            }
            : nil
    }
}

/// A work item Start Work Here can name a branch after (WS-08).
struct StartWorkItem: Hashable, Sendable, Identifiable {
    var number: Int
    var title: String
    /// the full reference, like `group/project#12`
    var reference: String

    var id: String { reference }
}

/// The Workspaces list: the rows, and what shows instead of them.
struct WorkspacesListModel: Sendable {
    var rows: [WorkspaceRowModel]
    /// the open work items the app knows, for Start Work Here
    var startWorkItems: [StartWorkItem]
    var query: String
    /// what shows without rows
    var empty: Empty?
    /// whether the first reading still runs, which shows placeholder rows
    var isPlaceholder: Bool
    /// the entries in Settings that found nothing, as "~/workspaces/*/project: No checkout matches"
    var folderProblems: [String]
    /// whether Open in IDE is set up
    var hasIDECommand: Bool
    var home: URL

    /// What shows without rows.
    enum Empty: Hashable, Sendable {
        /// Settings → Repositories has no folder
        case noFolders
        /// the folders found no checkout
        case noCheckouts
    }

    init(_ data: WorkspacesData, query: String = "") {
        self.query = query
        home = data.home
        hasIDECommand = LaunchCommand.words(of: data.settings.ideCommand)?.isEmpty == false
        startWorkItems = data.workItems.compactMap { item in
            guard !item.isEpic, item.state == .opened, let number = item.iid.flatMap(Int.init), number > 0 else {
                return nil
            }
            return StartWorkItem(number: number, title: item.displayTitle, reference: item.reference)
        }
        let all = data.checkouts.map { WorkspaceRowModel($0, data: data) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        rows = trimmed.isEmpty ? all : all.filter { $0.matches(trimmed) }
        folderProblems = data.settings.folders.compactMap { folder in
            guard let problem = data.findings.first(where: { $0.folder == folder.id })?.problem else {
                return nil
            }
            let path = folder.path.isEmpty ? "An empty entry" : folder.path
            return "\(path): \(problem.message)"
        }
        isPlaceholder = all.isEmpty && data.isRefreshing && data.lastRefreshAt == nil && !data.settings.folders.isEmpty
        if data.settings.folders.isEmpty {
            empty = .noFolders
        } else if all.isEmpty && !isPlaceholder && data.lastRefreshAt != nil {
            empty = .noCheckouts
        } else {
            empty = nil
        }
    }

    /// whether the search hides every row
    var findsNothing: Bool {
        rows.isEmpty && empty == nil && !isPlaceholder && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// the row of a selection
    func row(_ id: Checkout.ID?) -> WorkspaceRowModel? {
        id.flatMap { id in rows.first { $0.id == id } }
    }

    /// "4 checkouts · 2 free"; `nil` without checkouts
    var subtitle: String? {
        guard !rows.isEmpty else {
            return nil
        }
        let free = rows.count { $0.kind == .free }
        let count = "\(rows.count) checkout\(rows.count == 1 ? "" : "s")"
        return free > 0 ? "\(count) · \(free) free" : count
    }
}

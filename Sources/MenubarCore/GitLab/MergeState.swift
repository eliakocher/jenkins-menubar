import Foundation

/// What GitLab says about merging one merge request: its state, GitLab's merge checks, the branches and commits, the
/// project's squash and branch rules, the default messages, auto-merge and what the token may do (MR-16).
///
/// Read with GraphQL (`project.mergeRequest`), checked against GitLab's schema (gitlab.com, 19.6) on 2026-11-03; never
/// sent to the team's GitLab by the author. `mergeabilityChecks` is an experiment in GitLab's reference: a GitLab that
/// refuses it is asked again without it, and the checks come from `detailedMergeStatus` alone.
///
/// Codable for the ``DetailCache``, which keeps the last one per merge request so the card shows at once (MR-16): a
/// copy that no longer decodes, like one from before a field was added, is ignored. A new field should be optional.
public struct MergeState: Codable, Hashable, Sendable {
    public var lifecycle: Lifecycle
    public var isDraft: Bool
    /// GitLab's `detailedMergeStatus`
    public var status: MergeRequest.MergeStatus?
    /// GitLab's `mergeabilityChecks`, inactive ones included; `nil` when GitLab didn't answer them
    public var checks: [GitLabCheck]?
    /// the head commit of the diff the user sees, sent with every merge so it never takes commits nobody saw
    public var headSHA: String?
    public var sourceBranch: String
    public var targetBranch: String
    /// the commits of the merge request; `nil` when GitLab doesn't say
    public var commitCount: Int?
    /// whether the target branch has commits the source branch lacks
    public var isBehind: Bool
    /// how many: REST's `diverged_commits_count`, asked only when ``isBehind``; `nil` when not known
    public var behindCount: Int?
    /// the head pipeline's status; `nil` without one
    public var pipelineStatus: MergeRequest.PipelineStatus?
    public var hasConflicts: Bool
    public var squash: Squash
    /// whether the source branch goes after the merge, as GitLab's widget starts it: `shouldRemoveSourceBranch ||
    /// forceRemoveSourceBranch` (the latter is the merge request's setting, which the project's default fills in)
    public var removesSourceBranch: Bool
    public var defaultMergeMessage: String?
    public var defaultSquashMessage: String?
    /// the auto-merge that is set; `nil` without one
    public var autoMerge: AutoMerge?
    /// GitLab's `availableAutoMergeStrategies`, like `merge_when_checks_pass`; empty when auto-merge can't be set
    public var autoMergeStrategies: [String]
    /// who merged it, once merged
    public var mergedBy: MergeRequest.Person?
    public var mergedAt: Date?
    public var closedAt: Date?
    /// GitLab's last merge error
    public var mergeError: String?
    /// whether GitLab is merging it right now
    public var isMerging: Bool
    /// whether the project only fast-forwards, so no merge commit is made
    public var fastForwardOnly: Bool
    public var permissions: Permissions

    public init(
        lifecycle: Lifecycle = .opened, isDraft: Bool = false, status: MergeRequest.MergeStatus? = nil,
        checks: [GitLabCheck]? = nil, headSHA: String? = nil, sourceBranch: String, targetBranch: String,
        commitCount: Int? = nil, isBehind: Bool = false, behindCount: Int? = nil,
        pipelineStatus: MergeRequest.PipelineStatus? = nil, hasConflicts: Bool = false, squash: Squash = .optional(on: false),
        removesSourceBranch: Bool = false, defaultMergeMessage: String? = nil, defaultSquashMessage: String? = nil,
        autoMerge: AutoMerge? = nil, autoMergeStrategies: [String] = [], mergedBy: MergeRequest.Person? = nil,
        mergedAt: Date? = nil, closedAt: Date? = nil, mergeError: String? = nil, isMerging: Bool = false,
        fastForwardOnly: Bool = false, permissions: Permissions = .all
    ) {
        self.lifecycle = lifecycle
        self.isDraft = isDraft
        self.status = status
        self.checks = checks
        self.headSHA = headSHA
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.commitCount = commitCount
        self.isBehind = isBehind
        self.behindCount = behindCount
        self.pipelineStatus = pipelineStatus
        self.hasConflicts = hasConflicts
        self.squash = squash
        self.removesSourceBranch = removesSourceBranch
        self.defaultMergeMessage = defaultMergeMessage
        self.defaultSquashMessage = defaultSquashMessage
        self.autoMerge = autoMerge
        self.autoMergeStrategies = autoMergeStrategies
        self.mergedBy = mergedBy
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.mergeError = mergeError
        self.isMerging = isMerging
        self.fastForwardOnly = fastForwardOnly
        self.permissions = permissions
    }

    /// GitLab's `MergeRequestState`.
    public enum Lifecycle: String, Codable, Hashable, Sendable {
        case opened
        case merged
        case closed
        case locked
    }

    /// One of GitLab's merge checks, as it comes: `identifier` like `NOT_APPROVED`, `status` like `FAILED`.
    public struct GitLabCheck: Codable, Hashable, Sendable {
        public var identifier: String
        public var status: String

        public init(identifier: String, status: String) {
            self.identifier = identifier
            self.status = status
        }
    }

    /// The project's squash setting, as the merge request's `squash`, `squashOnMerge` and `squashReadOnly` tell it.
    public enum Squash: Codable, Hashable, Sendable {
        /// the project never squashes: no choice
        case never
        /// the project always squashes: no choice
        case always
        /// the user chooses; `on` is the merge request's setting, which the project's "encouraged" turns on at first
        case optional(on: Bool)

        /// whether the merge squashes unless the user changes it
        public var isOn: Bool {
            switch self {
            case .never: false
            case .always: true
            case .optional(let on): on
            }
        }
    }

    /// An auto-merge that is set: GitLab's strategy, like `merge_when_checks_pass`, and who set it.
    public struct AutoMerge: Codable, Hashable, Sendable {
        public var strategy: String?
        public var setBy: MergeRequest.Person?

        public init(strategy: String?, setBy: MergeRequest.Person?) {
            self.strategy = strategy
            self.setBy = setBy
        }
    }

    /// What the token's user may do with the merge request (`userPermissions`).
    public struct Permissions: Codable, Hashable, Sendable {
        public var canMerge: Bool
        /// edit the merge request, which marking it ready needs
        public var canUpdate: Bool
        /// choose whether the source branch goes
        public var canRemoveSourceBranch: Bool

        public init(canMerge: Bool, canUpdate: Bool, canRemoveSourceBranch: Bool) {
            self.canMerge = canMerge
            self.canUpdate = canUpdate
            self.canRemoveSourceBranch = canRemoveSourceBranch
        }

        /// everything allowed
        public static let all = Permissions(canMerge: true, canUpdate: true, canRemoveSourceBranch: true)
    }

    /// GitLab's auto-merge strategy for "Set to Auto-Merge", as `MergeStrategyEnum` names it, in the order of GitLab's
    /// widget (`getPreferredAutoMergeStrategy`): the merge train, then merge when the checks pass, then add to the merge
    /// train when they pass; `nil` when GitLab offers none of them.
    public var autoMergeStrategy: String? {
        let preferred = ["merge_train", "merge_when_checks_pass", "add_to_merge_train_when_checks_pass"]
        return preferred.first(where: autoMergeStrategies.contains)?.uppercased()
    }

    /// whether the auto-merge GitLab offers puts the merge request on a merge train, which its button says
    public var autoMergeJoinsTrain: Bool { autoMergeStrategy?.contains("TRAIN") == true }

    /// "1 commit and 1 merge commit into develop", "3 commits into develop" when fast-forwarding, "1 commit (4 squashed)
    /// and 1 merge commit into develop"; `nil` while the number of commits isn't known
    ///
    /// - Parameter squash: whether the merge squashes, as the user chose
    public func summary(squash: Bool) -> String? {
        guard let commitCount else {
            return nil
        }
        let count = squash ? 1 : commitCount
        var text = "\(count) \(count == 1 ? "commit" : "commits")"
        if squash, commitCount > 1 {
            text += " (\(commitCount) squashed)"
        }
        if !fastForwardOnly {
            text += " and 1 merge commit"
        }
        return text + " into \(targetBranch)"
    }
}

// MARK: - The overview

/// The Merge card's rules (MR-16): one headline for the state, the checks that need something (with their fix), the
/// count of those that passed, and the actions there are. Built from the merge state and what the details know of the
/// approvals and threads.
public struct MergeOverview: Hashable, Sendable {
    public var headline: Headline
    /// the checks that failed, are pending, warn, or only inform, in that order
    public var open: [MergeCheck]
    /// the checks that passed
    public var passed: [MergeCheck]
    /// what the user can do now, in the order the card shows them
    public var actions: [MergeAction]

    /// The state in one line, and its tone.
    public struct Headline: Hashable, Sendable {
        public var title: String
        /// the line under it, like "Approvals and the pipeline"; `nil` for none
        public var detail: String?
        public var tone: Tone
        public var symbol: String

        public init(title: String, detail: String?, tone: Tone, symbol: String) {
            self.title = title
            self.detail = detail
            self.tone = tone
            self.symbol = symbol
        }
    }

    /// The headline's color, which MenubarUI picks.
    public enum Tone: Hashable, Sendable {
        /// green
        case ready
        /// red
        case blocked
        /// orange
        case waiting
        /// blue: auto-merge is on, or the merge is under way
        case autoMerge
        /// purple
        case merged
        /// grey
        case neutral
    }

    /// Returns the overview of a merge state.
    ///
    /// - Parameters:
    ///   - state: GitLab's merge state
    ///   - approvals: "2 of 4 approvals", from the details; `nil` while they aren't known
    ///   - openThreads: the unresolved threads, from the details; `nil` while they aren't known
    public init(_ state: MergeState, approvals: String? = nil, openThreads: Int? = nil) {
        let checks = MergeCheck.checks(of: state, approvals: approvals, openThreads: openThreads)
        open = checks.filter { $0.status == .failed } + checks.filter { $0.status == .pending }
            + checks.filter { $0.status == .warning } + checks.filter { $0.status == .info }
        passed = checks.filter { $0.status == .passed }
        headline = Self.headline(state, checks: checks)
        actions = Self.actions(state, checks: checks)
    }

    /// whether GitLab would merge it now
    static func isReady(_ state: MergeState, checks: [MergeCheck]) -> Bool {
        if state.status == .mergeable {
            return true
        }
        // Without GitLab's checks only its status can say so; while it checks, nothing is ready.
        guard state.checks != nil, !(state.status.map(checkingStatuses.contains) ?? false) else {
            return false
        }
        return !checks.isEmpty && !checks.contains { $0.status == .failed || $0.status == .pending }
    }

    private static let checkingStatuses: Set<MergeRequest.MergeStatus> = [.unchecked, .checking, .preparing, .approvalsSyncing]

    private static func headline(_ state: MergeState, checks: [MergeCheck]) -> Headline {
        let target = state.targetBranch
        switch state.lifecycle {
        case .merged:
            let by = state.mergedBy.map { "by \($0.name.isEmpty ? $0.username : $0.name) " } ?? ""
            return Headline(title: "Merged", detail: "\(by)into \(target)", tone: .merged, symbol: "arrow.triangle.merge")
        case .closed, .locked:
            return Headline(title: "Closed", detail: "Closed without merging", tone: .neutral, symbol: "xmark.circle.fill")
        case .opened:
            break
        }
        if state.isMerging {
            return Headline(title: "Merging…", detail: "GitLab is merging into \(target)", tone: .autoMerge, symbol: "arrow.triangle.merge")
        }
        if let autoMerge = state.autoMerge {
            let who = autoMerge.setBy.map { " · set by \($0.name.isEmpty ? $0.username : $0.name)" } ?? ""
            let train = autoMerge.strategy?.contains("train") == true
            return Headline(
                title: "Auto-merge on", detail: (train ? "Joins the merge train when checks pass" : "Merges when checks pass") + who,
                tone: .autoMerge, symbol: "clock.badge.checkmark.fill")
        }
        let failed = checks.filter { $0.status == .failed }
        let pending = checks.filter { $0.status == .pending }
        if failed.isEmpty, !isReady(state, checks: checks), let status = state.status, checkingStatuses.contains(status) {
            return Headline(
                title: "Checking…", detail: "GitLab is checking whether it can merge", tone: .neutral, symbol: "ellipsis.circle.fill")
        }
        if !failed.isEmpty {
            // One check names itself; several are listed by their short names.
            let detail = failed.count == 1 ? failed[0].nextStep(target: target) : Self.list(failed.map(\.shortName))
            return Headline(
                title: "Blocked: \(failed.count) \(failed.count == 1 ? "check" : "checks")", detail: detail,
                tone: .blocked, symbol: "xmark.octagon.fill")
        }
        if !pending.isEmpty {
            let isPipeline = pending.contains { $0.kind == .pipeline }
            let then = state.autoMergeStrategy != nil
                ? "Set to auto-merge, and it merges when \(isPipeline ? "the pipeline passes" : "they pass")"
                : "Then it's ready to merge"
            return Headline(
                title: isPipeline ? "Waiting for the pipeline" : "Waiting for checks", detail: then, tone: .waiting,
                symbol: "hourglass.circle.fill")
        }
        if isReady(state, checks: checks) {
            let passed = checks.filter { $0.status == .passed }.count
            return Headline(
                title: "Ready to Merge", detail: passed > 0 ? "All \(passed) checks passed" : "GitLab can merge it now", tone: .ready,
                symbol: "checkmark.circle.fill")
        }
        // GitLab says nothing we can name: its status, in words.
        let words = (state.status?.rawValue ?? "unknown").lowercased().replacingOccurrences(of: "_", with: " ")
        return Headline(title: "Not mergeable yet", detail: "GitLab says: \(words)", tone: .neutral, symbol: "questionmark.circle.fill")
    }

    private static func actions(_ state: MergeState, checks: [MergeCheck]) -> [MergeAction] {
        guard state.lifecycle == .opened, !state.isMerging else {
            return []
        }
        var actions: [MergeAction] = []
        let permissions = state.permissions
        // GitLab's widget: Cancel while auto-merge is set; else auto-merge whenever GitLab offers a strategy (it offers
        // none once it could merge now); else Merge when it would merge now.
        if state.autoMerge != nil {
            if permissions.canMerge {
                actions.append(.cancelAutoMerge)
            }
        } else if permissions.canMerge, state.headSHA != nil {
            if state.autoMergeStrategy != nil {
                actions.append(.setAutoMerge)
            } else if isReady(state, checks: checks) {
                actions.append(.merge)
            }
        }
        if checks.contains(where: { $0.fix == .markReady }) {
            actions.append(.markReady)
        }
        return actions
    }

    /// "Approvals", "Approvals and the pipeline", "Approvals, threads and the pipeline"
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else {
            return ""
        }
        let text = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What the Merge card can do: each a write on the user's click (MR-16).
public enum MergeAction: String, Hashable, Sendable, CaseIterable {
    case merge
    case setAutoMerge
    case cancelAutoMerge
    case markReady

    /// the button's title, in Title Style
    public var title: String {
        switch self {
        case .merge: "Merge"
        case .setAutoMerge: "Set to Auto-Merge"
        case .cancelAutoMerge: "Cancel Auto-Merge"
        case .markReady: "Mark as Ready"
        }
    }
}

// MARK: - The checks

/// One merge check as the card lists it: what it is about, whether it passed, its words, and the fix the card offers.
public struct MergeCheck: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: Kind
    public var status: Status
    public var title: String
    /// a sentence under the title; `nil` for none
    public var detail: String?
    public var fix: Fix?

    public init(id: String, kind: Kind, status: Status, title: String, detail: String? = nil, fix: Fix? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.fix = fix
    }

    public enum Kind: Hashable, Sendable {
        case approvals
        case requestedChanges
        case pipeline
        case threads
        case draft
        case conflicts
        /// behind the target branch: a rebase needed, or only for the record
        case behind
        /// any other check GitLab lists
        case other
    }

    public enum Status: Hashable, Sendable {
        case failed
        /// being checked, or the pipeline still running
        case pending
        /// passed, with a warning of GitLab's
        case warning
        /// for the record, blocking nothing: behind the target branch without needing a rebase
        case info
        case passed
    }

    /// The fix a check offers inline.
    public enum Fix: Hashable, Sendable {
        /// opens the Reviewers card
        case assignReviewers
        /// opens the Reviewers card, for a reviewer's requested changes
        case showReviewers
        /// shows the build in the app
        case showBuild
        /// jumps to the open threads in the Discussion card
        case showThreads
        /// a write: marks the merge request ready
        case markReady
        /// opens GitLab's conflicts page
        case openConflicts
        /// opens the merge request in GitLab
        case openInGitLab
    }

    /// What a lone failed check asks for, under the headline: "Resolve the conflicts first".
    func nextStep(target: String) -> String {
        switch kind {
        case .approvals: "Waiting for approvals"
        case .requestedChanges: "A reviewer requested changes"
        case .pipeline: "The pipeline must pass"
        case .threads: "Resolve the open threads first"
        case .draft: "Mark it as ready first"
        case .conflicts: "Resolve the conflicts first"
        case .behind: "Rebase onto \(target) first"
        case .other: title
        }
    }

    /// the check's name in the headline's list: "approvals", "the pipeline"
    var shortName: String {
        switch kind {
        case .approvals: "approvals"
        case .requestedChanges: "requested changes"
        case .pipeline: "the pipeline"
        case .threads: "threads"
        case .draft: "draft"
        case .conflicts: "conflicts"
        case .behind: "a rebase"
        case .other: title.prefix(1).lowercased() + title.dropFirst()
        }
    }

    /// Returns the checks of a merge state: GitLab's own when it sent them, inactive ones and "not open" left out; else
    /// the one ``MergeState/status`` names. Behind the target branch without a needed rebase adds a line for the
    /// record.
    static func checks(of state: MergeState, approvals: String?, openThreads: Int?) -> [MergeCheck] {
        let gitLab = state.checks ?? state.status.flatMap(Self.identifier(of:)).map {
            [MergeState.GitLabCheck(identifier: $0.identifier, status: $0.status)]
        } ?? []
        var checks = gitLab.compactMap { check -> MergeCheck? in
            guard let status = Self.status(check.status) else {
                return nil
            }
            return Self.check(check.identifier, status: status, state: state, approvals: approvals, openThreads: openThreads)
        }
        let needsRebase = checks.contains { $0.kind == .behind && $0.status == .failed }
        if state.isBehind, !needsRebase, state.lifecycle == .opened, !state.hasConflicts {
            checks.removeAll { $0.kind == .behind }
            checks.append(
                MergeCheck(
                    id: "BEHIND", kind: .behind, status: .info, title: behindTitle(state)))
        }
        return checks
    }

    /// GitLab's check status: `nil` for an inactive check, which the project turned off
    private static func status(_ text: String) -> Status? {
        switch text.uppercased() {
        case "SUCCESS": .passed
        case "FAILED": .failed
        case "WARNING": .warning
        case "CHECKING": .pending
        default: nil
        }
    }

    /// The check that a `detailedMergeStatus` names, for a GitLab that didn't send its checks.
    private static func identifier(of status: MergeRequest.MergeStatus) -> (identifier: String, status: String)? {
        let map: [String: String] = [
            "CI_MUST_PASS": "CI_MUST_PASS", "CI_STILL_RUNNING": "CI_MUST_PASS",
            "DISCUSSIONS_NOT_RESOLVED": "DISCUSSIONS_NOT_RESOLVED", "DRAFT_STATUS": "DRAFT_STATUS",
            "NOT_APPROVED": "NOT_APPROVED", "REQUESTED_CHANGES": "REQUESTED_CHANGES", "CONFLICT": "CONFLICT",
            "NEED_REBASE": "NEED_REBASE", "BLOCKED_STATUS": "MERGE_REQUEST_BLOCKED",
            "EXTERNAL_STATUS_CHECKS": "STATUS_CHECKS_MUST_PASS", "JIRA_ASSOCIATION": "JIRA_ASSOCIATION_MISSING",
            "LOCKED_PATHS": "LOCKED_PATHS", "LOCKED_LFS_FILES": "LOCKED_LFS_FILES", "MERGE_TIME": "MERGE_TIME",
            "SECURITY_POLICIES_VIOLATIONS": "SECURITY_POLICY_VIOLATIONS", "TITLE_NOT_MATCHING": "TITLE_REGEX",
            "SECURITY_POLICY_PIPELINE_CHECK": "SECURITY_POLICY_PIPELINE_CHECK", "COMMITS_STATUS": "COMMITS_STATUS",
        ]
        guard let identifier = map[status.rawValue] else {
            return nil
        }
        return (identifier, status == .ciStillRunning ? "CHECKING" : "FAILED")
    }

    /// "40 commits behind develop", "Behind develop"
    private static func behindTitle(_ state: MergeState) -> String {
        guard let count = state.behindCount, count > 0 else {
            return "Behind \(state.targetBranch)"
        }
        return "\(count) \(count == 1 ? "commit" : "commits") behind \(state.targetBranch)"
    }

    private static let pendingPipelines: Set<String> = [
        "RUNNING", "PENDING", "CREATED", "PREPARING", "SCHEDULED", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK",
    ]

    private static func check(
        _ identifier: String, status: Status, state: MergeState, approvals: String?, openThreads: Int?
    ) -> MergeCheck? {
        let passed = status == .passed
        let target = state.targetBranch
        let canEdit = state.permissions
        func make(_ kind: Kind, _ failed: String, _ ok: String, detail: String? = nil, fix: Fix? = nil) -> MergeCheck {
            MergeCheck(
                id: identifier, kind: kind, status: status, title: passed ? ok : failed, detail: passed ? nil : detail,
                fix: passed ? nil : fix)
        }
        switch identifier {
        case "NOT_OPEN":
            // The headline says merged or closed.
            return nil
        case "NOT_APPROVED":
            return make(.approvals, approvals ?? "Approvals required", "Approved", fix: .assignReviewers)
        case "REQUESTED_CHANGES":
            return make(.requestedChanges, "Changes requested", "No changes requested",
                        detail: "A reviewer asked for changes; they approve or remove their request.", fix: .showReviewers)
        case "CI_MUST_PASS":
            let pipeline = state.pipelineStatus?.rawValue
            var check = make(.pipeline, "Pipeline must pass", "Pipeline passed", fix: .showBuild)
            if !passed {
                if let pipeline, pendingPipelines.contains(pipeline) {
                    check.status = .pending
                    check.title = "Pipeline running"
                } else if pipeline == "FAILED" {
                    check.title = "Pipeline failed"
                } else if pipeline == nil {
                    check.title = "No pipeline yet"
                    check.detail = "The merge needs a pipeline that passed."
                }
                if status == .pending {
                    check.title = "Pipeline running"
                }
            }
            return check
        case "DISCUSSIONS_NOT_RESOLVED":
            let count = openThreads ?? 0
            let failed = count > 0 ? "\(count) open \(count == 1 ? "thread" : "threads")" : "Unresolved threads"
            return make(.threads, failed, "Threads resolved", fix: .showThreads)
        case "DRAFT_STATUS":
            return make(.draft, "Marked as draft", "Not a draft", fix: canEdit.canUpdate ? .markReady : .openInGitLab)
        case "CONFLICT":
            return make(
                .conflicts, "Merge conflicts", "No conflicts",
                detail: "\(state.sourceBranch) conflicts with \(target). Resolve them locally, or in GitLab when they're simple.",
                fix: .openConflicts)
        case "NEED_REBASE":
            return make(
                .behind, behindTitle(state), "Up to date with \(target)",
                detail: "The project merges fast-forward only: rebase the branch in GitLab or locally first.",
                fix: .openInGitLab)
        default:
            let (failed, ok) = otherTitles[identifier]
                ?? (identifier.prefix(1) + identifier.dropFirst().lowercased().replacingOccurrences(of: "_", with: " "), "")
            return make(.other, failed, ok.isEmpty ? failed : ok, fix: .openInGitLab)
        }
    }

    /// the words of GitLab's other checks: failed, passed
    private static let otherTitles: [String: (String, String)] = [
        "MERGE_REQUEST_BLOCKED": ("Blocked by other merge requests", "No blocking merge requests"),
        "COMMITS_STATUS": ("The source branch is missing or empty", "Source branch has commits"),
        "STATUS_CHECKS_MUST_PASS": ("External status checks must pass", "External status checks passed"),
        "JIRA_ASSOCIATION_MISSING": ("Needs a Jira issue in the title or description", "Jira issue named"),
        "LOCKED_PATHS": ("Changes locked paths", "No locked paths"),
        "LOCKED_LFS_FILES": ("Changes locked LFS files", "No locked LFS files"),
        "SECURITY_POLICY_VIOLATIONS": ("Security policies not satisfied", "Security policies satisfied"),
        "SECURITY_POLICY_PIPELINE_CHECK": ("Security policy pipelines must pass", "Security policy pipelines passed"),
        "MERGE_TIME": ("Outside the merge time window", "Inside the merge time window"),
        "TITLE_REGEX": ("The title doesn't match the project's rule", "Title matches the project's rule"),
    ]
}

// MARK: - The query

/// How much of the merge state to ask: `mergeabilityChecks` is an experiment, which a GitLab may refuse.
enum MergeStateLevel: Sendable {
    case full
    /// without `mergeabilityChecks`
    case basic
}

extension GitLabOperation where Value == MergeState {
    /// The merge state of a merge request (MR-16): one query of `project.mergeRequest` and the project's merge rules.
    ///
    /// - Parameters:
    ///   - source: the merge request
    ///   - level: with GitLab's checks, or without them
    /// - Returns: the operation, or `nil` for a reference without a path or an iid
    static func mergeState(of source: DescriptionSource, level: MergeStateLevel = .full) -> GitLabOperation? {
        guard let (path, iid) = source.pathAndIID else {
            return nil
        }
        let checks = level == .full ? "mergeabilityChecks { identifier status }" : ""
        return GitLabOperation(
            name: "MergeRequestMergeState",
            query: """
                query MergeRequestMergeState($path: ID!, $iid: String!) {
                  project(fullPath: $path) {
                    mergeRequestsFfOnlyEnabled
                    mergeRequest(iid: $iid) {
                      state draft detailedMergeStatus \(checks)
                      diffHeadSha sourceBranch targetBranch commitCount divergedFromTargetBranch conflicts
                      squash squashOnMerge squashReadOnly shouldRemoveSourceBranch forceRemoveSourceBranch
                      defaultMergeCommitMessage defaultSquashCommitMessage
                      autoMergeEnabled autoMergeStrategy availableAutoMergeStrategies
                      mergeUser { username name }
                      mergedAt closedAt mergeError mergeOngoing
                      headPipeline { status }
                      userPermissions { canMerge updateMergeRequest removeSourceBranch }
                    }
                  }
                }
                """,
            variables: .object([("path", .string(path)), ("iid", .string(iid))]),
            decode: { body in
                let project = try GraphQLAnswer<MergeStateShape>.value(of: body).project
                guard let project, let node = project.mergeRequest else {
                    throw DecodingError.valueNotFound(MergeState.self, .init(codingPath: [], debugDescription: "no merge request"))
                }
                return node.state(project: project)
            })
    }
}

/// The shape of the merge state's answer.
struct MergeStateShape: Decodable {
    var project: Project?

    struct Project: Decodable {
        var mergeRequestsFfOnlyEnabled: Bool?
        var mergeRequest: Node?
    }

    struct Node: Decodable {
        var state: String?
        var draft: Bool?
        var detailedMergeStatus: String?
        var mergeabilityChecks: [Check]?
        var diffHeadSha: String?
        var sourceBranch: String?
        var targetBranch: String?
        var commitCount: Int?
        var divergedFromTargetBranch: Bool?
        var conflicts: Bool?
        var squash: Bool?
        var squashOnMerge: Bool?
        var squashReadOnly: Bool?
        var shouldRemoveSourceBranch: Bool?
        var forceRemoveSourceBranch: Bool?
        var defaultMergeCommitMessage: String?
        var defaultSquashCommitMessage: String?
        var autoMergeEnabled: Bool?
        var autoMergeStrategy: String?
        var availableAutoMergeStrategies: [String]?
        var mergeUser: User?
        var mergedAt: Date?
        var closedAt: Date?
        var mergeError: String?
        var mergeOngoing: Bool?
        var headPipeline: Pipeline?
        var userPermissions: Permissions?

        func state(project: Project) -> MergeState {
            let squash: MergeState.Squash =
                if squashReadOnly == true {
                    squashOnMerge == true ? .always : .never
                } else {
                    // GitLab's widget starts the checkbox at `squashOnMerge`.
                    .optional(on: squashOnMerge ?? self.squash ?? false)
                }
            let person = mergeUser.map { MergeRequest.Person(username: $0.username, name: $0.name ?? "") }
            let lifecycle = MergeState.Lifecycle(rawValue: state ?? "") ?? .opened
            return MergeState(
                lifecycle: lifecycle,
                isDraft: draft ?? false,
                status: detailedMergeStatus.map(MergeRequest.MergeStatus.init(rawValue:)),
                checks: mergeabilityChecks?.map { MergeState.GitLabCheck(identifier: $0.identifier, status: $0.status) },
                headSHA: diffHeadSha,
                sourceBranch: sourceBranch ?? "",
                targetBranch: targetBranch ?? "",
                commitCount: commitCount,
                isBehind: divergedFromTargetBranch ?? false,
                pipelineStatus: headPipeline?.status.map(MergeRequest.PipelineStatus.init(rawValue:)),
                hasConflicts: conflicts ?? false,
                squash: squash,
                // As GitLab's widget starts its checkbox.
                removesSourceBranch: shouldRemoveSourceBranch == true || forceRemoveSourceBranch == true,
                defaultMergeMessage: defaultMergeCommitMessage,
                defaultSquashMessage: defaultSquashCommitMessage,
                autoMerge: autoMergeEnabled == true ? .init(strategy: autoMergeStrategy, setBy: person) : nil,
                autoMergeStrategies: availableAutoMergeStrategies ?? [],
                mergedBy: lifecycle == .merged ? person : nil,
                mergedAt: mergedAt,
                closedAt: closedAt,
                mergeError: mergeError,
                isMerging: mergeOngoing ?? false,
                fastForwardOnly: project.mergeRequestsFfOnlyEnabled ?? false,
                permissions: userPermissions.map {
                    .init(
                        canMerge: $0.canMerge ?? false, canUpdate: $0.updateMergeRequest ?? false,
                        canRemoveSourceBranch: $0.removeSourceBranch ?? false)
                } ?? .all)
        }
    }

    struct Check: Decodable {
        var identifier: String
        var status: String
    }

    struct User: Decodable {
        var username: String
        var name: String?
    }

    struct Pipeline: Decodable {
        var status: String?
    }

    struct Permissions: Decodable {
        var canMerge: Bool?
        var updateMergeRequest: Bool?
        var removeSourceBranch: Bool?
    }
}

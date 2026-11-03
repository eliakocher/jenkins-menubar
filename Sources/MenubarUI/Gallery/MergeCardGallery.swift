#if DEBUG
import MenubarCore
import SwiftUI

/// The Merge card (MR-16) in each state, on !16 of the merge requests fixtures: made-up branches of a made-up Swift app.
extension MergeRequestsFixtures {
    /// every check GitLab lists, passed, with the inactive ones a project turned off
    static var passedChecks: [MergeState.GitLabCheck] {
        [
            "NOT_APPROVED", "REQUESTED_CHANGES", "CI_MUST_PASS", "DISCUSSIONS_NOT_RESOLVED", "DRAFT_STATUS", "CONFLICT",
            "NEED_REBASE", "MERGE_REQUEST_BLOCKED",
        ].map { MergeState.GitLabCheck(identifier: $0, status: "SUCCESS") }
            + ["JIRA_ASSOCIATION_MISSING", "LOCKED_PATHS", "TITLE_REGEX"].map { .init(identifier: $0, status: "INACTIVE") }
    }

    /// GitLab's checks with some of them changed
    static func checks(_ changed: [String: String]) -> [MergeState.GitLabCheck] {
        passedChecks.map { check in
            var check = check
            check.status = changed[check.identifier] ?? check.status
            return check
        }
    }

    /// !16 ready to merge: one commit, the pipeline passed, the branch deleted after the merge
    var mergeReady: MergeState {
        MergeState(
            status: .mergeable, checks: Self.passedChecks, headSHA: "4f2a9c1e", sourceBranch: "feature/export-retry",
            targetBranch: "develop", commitCount: 1, pipelineStatus: .success, squash: .optional(on: false),
            removesSourceBranch: true,
            defaultMergeMessage: "Merge branch 'feature/export-retry' into 'develop'\n\nAdd a retry to the export job\n\nSee merge request group/subgroup/project!16",
            defaultSquashMessage: "Add a retry to the export job", autoMergeStrategies: [])
    }

    /// !16 blocked by the approvals, the threads and a failed pipeline, and 40 commits behind develop
    var mergeBlocked: MergeState {
        var state = mergeReady
        state.status = .notApproved
        state.checks = Self.checks(["NOT_APPROVED": "FAILED", "CI_MUST_PASS": "FAILED", "DISCUSSIONS_NOT_RESOLVED": "FAILED"])
        state.pipelineStatus = .failed
        state.isBehind = true
        state.behindCount = 40
        state.autoMergeStrategies = ["merge_when_checks_pass"]
        state.commitCount = 4
        return state
    }

    /// !16 waiting for its pipeline, which auto-merge can wait for
    var mergePending: MergeState {
        var state = mergeReady
        state.status = .ciStillRunning
        state.checks = Self.checks(["CI_MUST_PASS": "FAILED"])
        state.pipelineStatus = .running
        state.autoMergeStrategies = ["merge_when_checks_pass"]
        return state
    }

    /// !16 set to auto-merge by Sam Lee
    var mergeAuto: MergeState {
        var state = mergePending
        state.autoMerge = .init(strategy: "merge_when_checks_pass", setBy: .init(username: "slee", name: "Sam Lee"))
        return state
    }

    /// !16 with merge conflicts
    var mergeConflicts: MergeState {
        var state = mergeReady
        state.status = .conflict
        state.checks = Self.checks(["CONFLICT": "FAILED"])
        state.hasConflicts = true
        state.isBehind = true
        state.behindCount = 12
        return state
    }

    /// !16 in a fast-forward project, 40 commits behind: a rebase first
    var mergeBehind: MergeState {
        var state = mergeReady
        state.status = .needRebase
        state.checks = Self.checks(["NEED_REBASE": "FAILED"])
        state.isBehind = true
        state.behindCount = 40
        state.fastForwardOnly = true
        state.squash = .always
        return state
    }

    /// !16 still a draft
    var mergeDraft: MergeState {
        var state = mergeReady
        state.status = .draftStatus
        state.isDraft = true
        state.checks = Self.checks(["DRAFT_STATUS": "FAILED"])
        return state
    }

    /// !16 merged by Alex Kim
    var mergeMerged: MergeState {
        var state = mergeReady
        state.lifecycle = .merged
        state.mergedBy = .init(username: "akim", name: "Alex Kim")
        state.checks = Self.checks(["NOT_OPEN": "FAILED"])
        return state
    }

    /// !16 closed without merging
    var mergeClosed: MergeState {
        var state = mergeReady
        state.lifecycle = .closed
        return state
    }

    /// !16 with the squash encouraged by the project, in four commits
    var mergeSquash: MergeState {
        var state = mergeReady
        state.squash = .optional(on: true)
        state.commitCount = 4
        return state
    }
}

extension GalleryCatalog {
    /// The Merge card in each state, alone at the detail's width and at the narrowest one; and on the whole detail page.
    static var mergeCardEntries: [GalleryEntry] {
        let wide: CGFloat = 720
        let narrow: CGFloat = 400
        func card(
            _ state: String, width: CGFloat = wide, height: CGFloat = 520, phase: MergeCardPhase? = nil,
            activity: MergeActivity = .idle, failed: Bool = false, cached: Bool = false,
            pick: @escaping @MainActor (MergeRequestsFixtures) -> MergeState?
        ) -> GalleryEntry {
            GalleryEntry(screen: "merge-requests", state: state, size: CGSize(width: width, height: height)) { f in
                let m = f.mergeRequestsScreen
                let mergeRequest = m.mr16
                var model = MergeRequestDetailModel(MergeRequestsData(m.panel(m.sections + [m.mr16])), mergeRequest: mergeRequest)
                model.workItems = [
                    LinkedWorkItem(
                        project: "group/subgroup/project", iid: 18874, title: "Exports fail when the connection drops",
                        origin: .title)
                ]
                // `cached`: the copy kept on disk, while GitLab is asked again (a failed ask stays on the cached copy).
                let load = pick(m).map { MergeStateLoad(state: $0, failed: failed, isCached: cached, isRefreshing: cached && !failed) }
                    ?? MergeStateLoad(state: nil, failed: failed)
                return MergeCard(model: model, details: m.details16, actions: .gallery) { _ in }
                    .padding(20)
                    .frame(width: width, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                .environment(
                    \.mergeRequestDetailsFixtures,
                    MergeRequestDetailsFixtures(
                        states: [:], writeAccess: .allowed, mergeStates: [mergeRequest.reference: load],
                        mergeActivity: [mergeRequest.reference: activity], mergePhase: phase))
            }
        }
        let shaError = MergeActivity.failed(
            .merge, message: "SHA does not match HEAD of source branch: 9b1d77e0", needsToken: false)
        return [
            card("merge-ready") { $0.mergeReady },
            card("merge-ready-narrow", width: narrow) { $0.mergeReady },
            card("merge-blocked", height: 620) { $0.mergeBlocked },
            card("merge-blocked-narrow", width: narrow, height: 760) { $0.mergeBlocked },
            card("merge-pending") { $0.mergePending },
            card("merge-auto") { $0.mergeAuto },
            card("merge-conflicts") { $0.mergeConflicts },
            card("merge-behind") { $0.mergeBehind },
            card("merge-draft") { $0.mergeDraft },
            card("merge-merged", height: 260) { $0.mergeMerged },
            card("merge-closed", height: 260) { $0.mergeClosed },
            card("merge-confirm", phase: .confirming) { $0.mergeReady },
            card("merge-confirm-narrow", width: narrow, height: 600, phase: .confirming) { $0.mergeReady },
            card("merge-message", height: 720, phase: .editingMessage) { $0.mergeSquash },
            card("merge-failed", activity: shaError) { $0.mergeReady },
            card("merge-done", height: 300, activity: .succeeded(.merge)) { $0.mergeMerged },
            card("merge-cached", cached: true) { $0.mergeReady },
            card("merge-cached-narrow", width: narrow, cached: true) { $0.mergeReady },
            card("merge-cached-pending", cached: true) { $0.mergePending },
            card("merge-cached-failed", height: 560, failed: true, cached: true) { $0.mergeReady },
            card("merge-loading", height: 260) { _ in nil },
            card("merge-load-failed", height: 200, failed: true) { _ in nil },
        ]
    }
}
#endif

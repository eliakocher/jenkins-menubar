#if DEBUG
import Foundation
import MenubarCore

/// The merge requests of `docs/design/merge-requests.md`, States: made up, with reviewers by name. Me `jdoe` ("Jane
/// Doe"); others Sam Lee, Alex Kim, Robin Meyer, Chris Novak, Pat Rivera and Kim Weber; the team's project
/// `group/subgroup/project` and another one, `group/subgroup/web`. The last load 10:41.
struct MergeRequestsFixtures {
    let f: Fixtures

    var me: MergeRequest.Person { MergeRequest.Person(username: "jdoe", name: "Jane Doe") }
    var samLee: MergeRequest.Person { MergeRequest.Person(username: "slee", name: "Sam Lee") }
    var alexKim: MergeRequest.Person { MergeRequest.Person(username: "akim", name: "Alex Kim") }

    /// the time of the last load, 10:41
    var lastLoad: Date { f.minutesAgo(1) }

    /// A reviewer by username, with their name.
    func reviewer(_ username: String, _ state: MergeRequest.ReviewState, approved: Bool? = nil) -> MergeRequest.Reviewer {
        let names = [
            "jdoe": "Jane Doe", "slee": "Sam Lee", "akim": "Alex Kim", "rmeyer": "Robin Meyer", "cnovak": "Chris Novak",
            "privera": "Pat Rivera", "kweber": "Kim Weber",
        ]
        return MergeRequest.Reviewer(
            username: username, name: names[username] ?? "", reviewState: state, approved: approved ?? (state == .approved))
    }

    /// An open MR with everything set.
    func mergeRequest(
        _ iid: Int, _ title: String, project: String = "group/subgroup/project", status: String? = "MERGEABLE",
        draft: Bool = false, pipeline: String? = "SUCCESS", author: MergeRequest.Person? = nil,
        reviewers: [MergeRequest.Reviewer] = [], updatedMinutesAgo: Double = 5, roles: Set<MergeRequest.Role> = [.authored],
        files: Int = 3, additions: Int = 10, deletions: Int = 2
    ) -> MergeRequest {
        MergeRequest(
            iid: iid, title: title, webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
            reference: "\(project)!\(iid)", isDraft: draft, mergeStatus: status.map(MergeRequest.MergeStatus.init(rawValue:)),
            author: author ?? me, reviewers: reviewers, pipelineStatus: pipeline.map(MergeRequest.PipelineStatus.init(rawValue:)),
            diffStats: MergeRequest.DiffStats(additions: additions, deletions: deletions, fileCount: files),
            updatedAt: f.minutesAgo(updatedMinutesAgo), roles: roles)
    }

    // MARK: - The sections

    /// !21: mine, ready to merge, approved by Sam Lee and Alex Kim
    var mr21: MergeRequest {
        mergeRequest(21, "Remove the old onboarding page", reviewers: [reviewer("slee", .approved), reviewer("akim", .approved)])
    }

    /// !24: Sam Lee's, assigned to me, one of two approvals missing
    var mr24: MergeRequest {
        mergeRequest(
            24, "Add keyboard shortcuts to the filter menu", status: "NOT_APPROVED", author: samLee,
            reviewers: [reviewer("akim", .approved), reviewer("rmeyer", .unreviewed)], updatedMinutesAgo: 25, roles: [.assigned])
    }

    /// !14: Sam Lee's, my review requested, Alex Kim approved; GitLab lists Alex first
    var mr14: MergeRequest {
        mergeRequest(
            14, "Rework the color tokens", status: "NOT_APPROVED", author: samLee,
            reviewers: [reviewer("akim", .approved), reviewer("jdoe", .unreviewed)], updatedMinutesAgo: 12,
            roles: [.reviewRequested])
    }

    /// web!8: Alex Kim's, in another project, approved by me
    var web8: MergeRequest {
        mergeRequest(
            8, "Fix the date format in the export dialog", project: "group/subgroup/web", author: alexKim,
            reviewers: [reviewer("jdoe", .approved)], updatedMinutesAgo: 180, roles: [.reviewRequested], files: 2,
            additions: 14, deletions: 6)
    }

    /// all three sections: !21, !24, !14, web!8
    var sections: [MergeRequest] { [mr21, mr24, mr14, web8] }

    /// !14's description (WIN-02), a made-up merge request template: sections, steps, a table of images, check boxes, a
    /// code block, a link and a hidden comment
    var description14: String {
        """
        ## What does this MR do?

        Moves the badge colors into **one token file**, so light and dark come from the same entry. The old constants \
        stay until the settings window reads the tokens too.

        Closes #31

        ## How to check it

        1. Open *Settings → Appearance* and switch between light and dark.
        2. Look at the badges in the panel and in the main window.
        3. Run the snapshot tests: `./test.sh BadgeColors`

        ## Screenshots

        | Before | After |
        |--------|-------|
        | ![before](/uploads/0f3a9c/badges-before.png) | ![after](/uploads/0f3a9c/badges-after.png) |

        ## Checklist

        - [x] Tests for the new token lookup
        - [x] Light and dark checked
        - [ ] Documentation updated
        - [ ] Changelog entry

        ```swift
        let tint = ColorTokens.badge(.failed, scheme: .dark)
        ```

        The full palette is in the [design notes](https://design.example.com/color-tokens).

        <!-- Keep the checklist up to date before asking for a review. -->
        """
    }

    // MARK: - MR-02's badges

    var mr25: MergeRequest {
        mergeRequest(25, "Draft: Try a sidebar for the settings window", status: "DRAFT_STATUS", draft: true, pipeline: nil,
                     updatedMinutesAgo: 8, files: 1, additions: 4, deletions: 0)
    }

    var mr18: MergeRequest {
        mergeRequest(18, "Speed up the search index rebuild", status: "CI_MUST_PASS", pipeline: "FAILED",
                     reviewers: [reviewer("slee", .unreviewed)], updatedMinutesAgo: 15)
    }

    var mr16: MergeRequest {
        mergeRequest(16, "Add a retry to the export job", status: "REQUESTED_CHANGES", pipeline: "FAILED",
                     reviewers: [reviewer("slee", .requestedChanges), reviewer("akim", .approved)], updatedMinutesAgo: 42)
    }

    /// !16 with a pipeline that doesn't fail, so rule 6 ("Changes requested") shows and not rule 3
    var mr16ChangesRequested: MergeRequest {
        mergeRequest(16, "Add a retry to the export job", status: "REQUESTED_CHANGES", pipeline: "SUCCESS",
                     reviewers: [reviewer("slee", .requestedChanges), reviewer("akim", .approved)], updatedMinutesAgo: 42)
    }

    /// MR-02's rules 1 to 6 in My Merge Requests
    var badges: [MergeRequest] {
        badgesWith(sixth: mr16ChangesRequested)
    }

    /// MR-02's rules 1 to 5 and the given MR as the sixth; `jenkins-build` takes !16 with its failed pipeline
    func badgesWith(sixth: MergeRequest) -> [MergeRequest] {
        [
            mr21, mr25, mr18,
            mergeRequest(19, "Migrate the settings storage", status: "CONFLICT", updatedMinutesAgo: 20),
            mergeRequest(9, "Update the date picker translations", status: "NEED_REBASE", updatedMinutesAgo: 30),
            sixth,
        ]
    }

    /// MR-02's rules 7 to 11 in My Merge Requests, and !14 in Review Requested
    var badgesMore: [MergeRequest] {
        [
            mergeRequest(22, "Clean up the old report exporter", status: "NOT_APPROVED",
                         reviewers: [reviewer("slee", .approved), reviewer("akim", .reviewStarted)], updatedMinutesAgo: 6),
            mergeRequest(26, "Show the build number in the alert", status: "DISCUSSIONS_NOT_RESOLVED", updatedMinutesAgo: 9),
            mergeRequest(23, "Speed up the CSV export", status: "CI_STILL_RUNNING", pipeline: "RUNNING", updatedMinutesAgo: 14),
            mergeRequest(27, "Try the new linter rules", status: "CHECKING", updatedMinutesAgo: 22),
            mergeRequest(28, "Bump the date library", status: "BLOCKED_STATUS", pipeline: "PENDING", updatedMinutesAgo: 31),
            mr14,
        ]
    }

    /// !16 with six reviewers, one per review state, a running pipeline and 12 files
    var mr16AllReviewers: MergeRequest {
        mergeRequest(
            16, "Add a retry to the export job", status: "REQUESTED_CHANGES", pipeline: "RUNNING",
            reviewers: [
                reviewer("slee", .requestedChanges), reviewer("akim", .approved), reviewer("rmeyer", .reviewed),
                reviewer("cnovak", .reviewStarted), reviewer("privera", .unreviewed), reviewer("kweber", .unapproved),
            ],
            updatedMinutesAgo: 42, files: 12, additions: 240, deletions: 31)
    }

    // MARK: - Builds

    /// A build of an MR, linked to it by its GitLab URL, as Jenkins' `objectUrl`.
    func build(of mergeRequest: MergeRequest, number: Int, phase: BuildPhase, kind: JobKind = .mine) -> Build {
        Build(
            job: "MR-\(mergeRequest.iid)", number: number, title: mergeRequest.title, gitLabURL: mergeRequest.webURL,
            author: kind == .watched ? mergeRequest.author.name : nil, kind: kind, phase: phase,
            startedAt: f.minutesAgo(9), estimatedDuration: 20 * 60)
    }

    // MARK: - Many and long

    /// 20 of mine, 50 to review, 12 reviewed
    var many: [MergeRequest] {
        let titles = [
            "Cache the label colors per project", "Show the merge status in the tooltip", "Retry the upload when the connection drops",
            "Translate the settings pane", "Speed up the search index", "Fix the flaky upload test", "Document the release steps",
            "Move the settings import to the new format", "Clean up the old report exporter", "Remove the unused color constants",
        ]
        let statuses = ["MERGEABLE", "NOT_APPROVED", "CI_STILL_RUNNING", "DISCUSSIONS_NOT_RESOLVED", "NEED_REBASE"]
        let mine = (0..<20).map { index in
            mergeRequest(100 + index, titles[index % titles.count], status: statuses[index % statuses.count],
                         reviewers: [reviewer("slee", .unreviewed)], updatedMinutesAgo: Double(index * 7 + 3))
        }
        let toReview = (0..<50).map { index in
            mergeRequest(200 + index, titles[(index + 3) % titles.count], status: "NOT_APPROVED", author: samLee,
                         reviewers: index == 0 ? twelveReviewers : [reviewer("jdoe", .unreviewed), reviewer("akim", .approved)],
                         updatedMinutesAgo: Double(index * 11 + 2), roles: [.reviewRequested])
        }
        let reviewed = (0..<12).map { index in
            mergeRequest(300 + index, titles[(index + 5) % titles.count], author: alexKim,
                         reviewers: [reviewer("jdoe", .approved)], updatedMinutesAgo: Double(index * 60 + 30),
                         roles: [.reviewRequested])
        }
        return mine + toReview + reviewed
    }

    /// me, unreviewed, and eleven others, approved and not
    private var twelveReviewers: [MergeRequest.Reviewer] {
        let others = ["slee", "akim", "rmeyer", "cnovak", "privera", "kweber"]
        var reviewers = [reviewer("jdoe", .unreviewed)]
        for index in 0..<11 {
            let username = index < others.count ? others[index] : "\(others[index % others.count])\(index)"
            reviewers.append(reviewer(username, index.isMultiple(of: 2) ? .approved : .reviewStarted))
        }
        return reviewers
    }

    /// the long project, author and reviewer names of `long-titles`
    var longProject: String { "group/subgroup/a-very-long-project-name-for-the-search-index-rework" }

    /// 200-character titles; the selected one, !31, asks my review, and its reviewers, without me, all approved
    var longTitles: [MergeRequest] {
        let author = MergeRequest.Person(username: "mkml", name: "Maximiliane Konstanze Müller-Lüdenscheidt")
        let anna = MergeRequest.Reviewer(username: "akrl", name: "Anna-Katharina Rosenberger-Lindqvist", reviewState: .approved, approved: true)
        return [
            mergeRequest(33, f.longTitle, project: longProject, author: author, updatedMinutesAgo: 4, files: 128, additions: 4210, deletions: 1877),
            mergeRequest(
                31, f.longTitle, project: longProject, status: "NOT_APPROVED", author: author,
                reviewers: [anna, reviewer("akim", .approved)], updatedMinutesAgo: 16, roles: [.reviewRequested],
                files: 42, additions: 980, deletions: 311),
        ]
    }

    // MARK: - Data

    /// two running builds of MRs this screen doesn't list, for the Pipelines badge
    var otherBuilds: [Build] {
        [
            f.running("MR-12", 7, "Fix the login redirect after a timeout", startedMinutesAgo: 5, estimateMinutes: 25, stages: ["tests"]),
            f.running("MR-15", 5, "Retry the upload when the connection drops", startedMinutesAgo: 31, estimateMinutes: 28),
        ]
    }

    /// The stores' values: the MRs as loaded at 10:41, the builds Pipelines shows, the work items for their badge,
    /// and the app-wide state.
    ///
    /// - Parameters:
    ///   - mergeRequests: the loaded MRs; `nil` takes the `sections` MRs, or none when `loaded` is false
    ///   - problem: the MR load's problem
    ///   - isLoading: whether a load runs
    ///   - loaded: whether a load ever answered
    ///   - builds: the builds Pipelines shows, besides ``otherBuilds``
    ///   - jenkinsProblem: offline, the team values or Jenkins' own
    ///   - team: the team values
    func panel(
        _ mergeRequests: [MergeRequest]? = nil, problem: Problem? = nil, isLoading: Bool = false, loaded: Bool = true,
        builds: [Build] = [], jenkinsProblem: Problem? = nil, team: TeamValues? = nil
    ) -> PanelData {
        let builds = otherBuilds + builds
        return PanelData(
            now: f.now, team: team ?? f.team,
            jenkins: PanelData.Jenkins(
                problem: jenkinsProblem, lastCheckedAt: f.now, mine: builds.filter { $0.kind == .mine },
                watched: builds.filter { $0.kind == .watched }),
            mergeRequests: PanelData.MergeRequests(
                list: (mergeRequests ?? (loaded ? sections : nil)).map { MergeRequestList(username: f.me, mergeRequests: $0) },
                problem: problem, isLoading: isLoading, lastLoadAt: loaded || problem != nil ? lastLoad : nil),
            // Without the GitLab token, neither section has data (MR-04).
            workItems: problem == .noToken(.gitLab)
                ? PanelData.WorkItems(problem: .noToken(.gitLab)) : f.workItemsScreen.panelWorkItems())
    }
}

extension Fixtures {
    /// the fixtures of the Merge Requests section
    var mergeRequestsScreen: MergeRequestsFixtures { MergeRequestsFixtures(f: self) }
}
#endif

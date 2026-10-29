import Foundation
import Testing

@testable import MenubarCore

/// The sections, the status badge and the details of merge requests (MR-01 to MR-03).
@Suite("Merge requests")
struct MergeRequestTests {
    private static let project = "acme/main/server/server"
    private static let me = "alex.doe"

    private static func date(_ text: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(text)
    }

    /// The MRs of `merge-requests-sections.json`, decoded by the client.
    private static func sectionsFixture() async throws -> MergeRequestList {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequests", body: try FixtureFiles.string("GitLab/merge-requests-sections.json"))
        return try await GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: "t").send(.mergeRequests)
    }

    private static func mergeRequest(
        _ iid: Int = 1,
        status: MergeRequest.MergeStatus? = nil,
        draft: Bool = false,
        pipeline: MergeRequest.PipelineStatus? = nil,
        reviewers: [MergeRequest.Reviewer] = [],
        roles: Set<MergeRequest.Role> = [.authored],
        updatedAt: Date = date("2026-10-28T10:00:00Z")
    ) -> MergeRequest {
        MergeRequest(iid: iid, title: "Change \(iid)", webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
                     reference: "\(project)!\(iid)", isDraft: draft, mergeStatus: status,
                     author: .init(username: me, name: "Alex Doe"), reviewers: reviewers, pipelineStatus: pipeline,
                     updatedAt: updatedAt, roles: roles)
    }

    private static func reviewer(_ username: String, _ state: MergeRequest.ReviewState, approved: Bool = false) -> MergeRequest.Reviewer {
        MergeRequest.Reviewer(username: username, reviewState: state, approved: approved)
    }

    // MARK: - MR-01

    @Test("MR-01 sorts my MRs and the reviews asked of me into sections")
    func sections() async throws {
        let list = try await Self.sectionsFixture()
        #expect(list.username == "alex.doe")

        let sections = MergeRequestSections(list.mergeRequests, me: list.username)
        #expect(sections.yours.map(\.iid) == [3, 1])
        #expect(sections.reviewRequested.map(\.iid) == [5, 2])
        #expect(sections.reviewed.map(\.iid) == [4])
        #expect(sections.sections.map(\.title) == ["My Merge Requests", "Review Requested", "Reviewed"])

        // The real answer: one review asked of me, still unreviewed.
        let stub = StubTransport()
        stub.answer(operation: "MergeRequests", body: try FixtureFiles.string("GitLab/merge-requests.json"))
        let real = try await GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: "t").send(.mergeRequests)
        let realSections = MergeRequestSections(real.mergeRequests, me: real.username)
        #expect(realSections.reviewRequested.map(\.iid) == [12437])
        #expect(realSections.yours.isEmpty && realSections.reviewed.isEmpty)
        let mergeRequest = try #require(real.mergeRequests.first)
        #expect(mergeRequest.isDraft && mergeRequest.mergeStatus == .draftStatus && mergeRequest.pipelineStatus == .running)
        #expect(mergeRequest.diffStats == MergeRequest.DiffStats(additions: 1895, deletions: 0, fileCount: 34))
        #expect(mergeRequest.reviewers.count == 5)
        #expect(mergeRequest.reviewers.first.map { [$0.username, $0.name] } == ["sam.reviewer", "Sam Reviewer"])
        #expect(mergeRequest.updatedAt == Self.date("2026-10-28T10:35:14Z"))
    }

    @Test("MR-01 a review I approved is in Reviewed")
    func approvedReview() {
        for state in [MergeRequest.ReviewState.approved, .reviewed, .requestedChanges] {
            let sections = MergeRequestSections(
                [Self.mergeRequest(roles: [.reviewRequested]).with(reviewers: [Self.reviewer(Self.me, state, approved: state == .approved)])],
                me: Self.me)
            #expect(sections.reviewed.map(\.iid) == [1], "\(state)")
            #expect(sections.reviewRequested.isEmpty)
        }
        for state in [MergeRequest.ReviewState.unreviewed, .reviewStarted, .unapproved] {
            let sections = MergeRequestSections(
                [Self.mergeRequest(roles: [.reviewRequested]).with(reviewers: [Self.reviewer(Self.me, state)])], me: Self.me)
            #expect(sections.reviewRequested.map(\.iid) == [1], "\(state)")
        }
        // Not among the reviewers counts as unreviewed.
        let notAmong = MergeRequestSections([Self.mergeRequest(roles: [.reviewRequested])], me: Self.me)
        #expect(notAmong.reviewRequested.map(\.iid) == [1])
    }

    @Test("MR-01 an MR authored and assigned shows once")
    func authoredAndAssigned() async throws {
        let list = try await Self.sectionsFixture()
        #expect(list.mergeRequests.filter { $0.iid == 1 }.count == 1)
        #expect(list.mergeRequests.first { $0.iid == 1 }?.roles == [.authored, .assigned])
        #expect(MergeRequestSections(list.mergeRequests, me: list.username).yours.filter { $0.iid == 1 }.count == 1)

        // Mine and asked of me: Review requested only.
        let both = MergeRequestSections([Self.mergeRequest(roles: [.authored, .reviewRequested])], me: Self.me)
        #expect(both.yours.isEmpty && both.reviewRequested.map(\.iid) == [1] && both.reviewed.isEmpty)
    }

    @Test("MR-01 sections are newest first")
    func newestFirst() {
        let sections = MergeRequestSections([
            Self.mergeRequest(1, updatedAt: Self.date("2026-10-26T10:00:00Z")),
            Self.mergeRequest(2, updatedAt: Self.date("2026-10-28T10:00:00Z")),
            Self.mergeRequest(3, updatedAt: Self.date("2026-10-27T10:00:00Z")),
        ], me: Self.me)
        #expect(sections.yours.map(\.iid) == [2, 3, 1])
    }

    @Test("MR-01 header counts open and to review")
    func header() async throws {
        let list = try await Self.sectionsFixture()
        #expect(MergeRequestSections(list.mergeRequests, me: list.username).header == "Merge Requests · 2 open · 2 to review")
        #expect(MergeRequestSections([Self.mergeRequest()], me: Self.me).header == "Merge Requests · 1 open")
        #expect(MergeRequestSections([Self.mergeRequest(roles: [.reviewRequested])], me: Self.me).header == "Merge Requests · 1 to review")
        // Reviewed doesn't count.
        let reviewed = Self.mergeRequest(roles: [.reviewRequested]).with(reviewers: [Self.reviewer(Self.me, .approved, approved: true)])
        #expect(MergeRequestSections([reviewed], me: Self.me).header == "Merge Requests")
    }

    @Test("MR-01 says when there are no open merge requests")
    func empty() {
        let sections = MergeRequestSections([], me: Self.me)
        #expect(sections.isEmpty)
        #expect(sections.sections.isEmpty)
        #expect(MergeRequestSections.emptyText == "No open merge requests")
    }

    // MARK: - MR-02

    @Test("MR-02 badge for every status")
    func everyStatus() {
        let cases: [(MergeRequest, String, String, MergeRequestStatus.Color, MergeRequestStatus.Kind)] = [
            (Self.mergeRequest(status: .mergeable), "Ready to merge", "checkmark.circle.fill", .green, .readyToMerge),
            (Self.mergeRequest(status: .draftStatus, draft: true), "Draft", "pencil.circle.fill", .neutral, .draft),
            (Self.mergeRequest(status: .ciStillRunning, pipeline: .failed), "Pipeline failed", "xmark.circle.fill", .red, .pipelineFailed),
            (Self.mergeRequest(status: .conflict), "Merge conflicts", "exclamationmark.circle.fill", .red, .conflicts),
            (Self.mergeRequest(status: .needRebase), "Needs a rebase", "arrow.up.circle.fill", .orange, .needsRebase),
            (Self.mergeRequest(status: .requestedChanges), "Changes requested", "exclamationmark.circle.fill", .orange, .changesRequested),
            (Self.mergeRequest(status: .notApproved), "No reviewers yet", "hourglass.circle.fill", .neutral, .notApproved),
            (Self.mergeRequest(status: .discussionsNotResolved), "Unresolved threads", "bubble.left.circle.fill", .orange, .unresolvedThreads),
            (Self.mergeRequest(status: .ciStillRunning, pipeline: .running), "Pipeline running", "arrow.triangle.2.circlepath.circle.fill",
             .blue, .pipelineRunning),
            (Self.mergeRequest(status: .unchecked), "Checking mergeability", "ellipsis.circle.fill", .neutral, .checking),
            (Self.mergeRequest(status: .checking), "Checking mergeability", "ellipsis.circle.fill", .neutral, .checking),
            (Self.mergeRequest(status: .preparing), "Checking mergeability", "ellipsis.circle.fill", .neutral, .checking),
            (Self.mergeRequest(status: .approvalsSyncing), "Checking mergeability", "ellipsis.circle.fill", .neutral, .checking),
            (Self.mergeRequest(status: .init(rawValue: "BLOCKED_STATUS")), "blocked status", "questionmark.circle.fill", .neutral, .other),
        ]
        for (mergeRequest, text, symbol, color, kind) in cases {
            #expect(MergeRequestStatus.of(mergeRequest, me: Self.me)
                == MergeRequestStatus(kind: kind, text: text, symbol: symbol, color: color), "\(text)")
        }
        #expect(MergeRequestStatus.Color.green == .init(light: "#108548", dark: "#52B87A"))
        #expect(MergeRequestStatus.Color.neutral == .init(light: "#737278", dark: "#A4A3A8"))
        #expect(MergeRequestStatus.Color.red == .init(light: "#DD2B0E", dark: "#EC5941"))
        #expect(MergeRequestStatus.Color.orange == .init(light: "#C17D10", dark: "#D99530"))
        #expect(MergeRequestStatus.Color.blue == .init(light: "#1F75CB", dark: "#428FDC"))
    }

    @Test("MR-02 ready to merge wins over draft")
    func readyOverDraft() {
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .mergeable, draft: true, pipeline: .failed)).kind == .readyToMerge)
    }

    @Test("MR-02 draft wins over a failed pipeline")
    func draftOverFailedPipeline() {
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .conflict, draft: true, pipeline: .failed)).kind == .draft)
    }

    @Test("MR-02 failed pipeline wins over conflicts")
    func failedPipelineOverConflicts() {
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .conflict, pipeline: .failed)).kind == .pipelineFailed)
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .conflict, pipeline: .success)).kind == .conflicts)
    }

    @Test("MR-02 approvals text")
    func approvalsText() {
        let approved = Self.reviewer("kim", .approved, approved: true)
        let waiting = Self.reviewer("sam", .unreviewed)
        func text(_ reviewers: [MergeRequest.Reviewer]) -> String {
            MergeRequestStatus.of(Self.mergeRequest(status: .notApproved, reviewers: reviewers)).text
        }
        #expect(text([]) == "No reviewers yet")
        #expect(text([approved, approved]) == "All reviewers approved, approval rules still open")
        #expect(text([waiting]) == "Missing 1 of 1 approval")
        #expect(text([approved, waiting, waiting]) == "Missing 2 of 3 approvals")
    }

    @Test("MR-02 review requested badge wraps the status")
    func reviewRequestedBadge() async throws {
        let list = try await Self.sectionsFixture()
        let theirs = try #require(list.mergeRequests.first { $0.iid == 2 })
        #expect(MergeRequestStatus.of(theirs, me: list.username)
            == MergeRequestStatus(kind: .reviewRequested, text: "Review requested · Ready to merge", symbol: "eye.circle.fill", color: .orange))
        // The status alone, and once my review is done.
        #expect(MergeRequestStatus.of(theirs).kind == .readyToMerge)
        let approvedByMe = try #require(list.mergeRequests.first { $0.iid == 4 })
        #expect(MergeRequestStatus.of(approvedByMe, me: list.username).kind == .pipelineFailed)
    }

    @Test("MR-02 unknown status shows in words")
    func unknownStatus() {
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .draftStatus)).text == "draft status")
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: nil)).text == "unknown")
        #expect(MergeRequestStatus.of(Self.mergeRequest(status: .init(rawValue: "NOT_OPEN"))).symbol == "questionmark.circle.fill")
    }

    // MARK: - MR-03

    @Test("MR-03 details of my MR")
    func detailsOfMine() async throws {
        let list = try await Self.sectionsFixture()
        let mine = try #require(list.mergeRequests.first { $0.iid == 1 })
        #expect(mine.details(me: list.username, project: Self.project, now: Self.date("2026-10-28T10:05:30Z"))
            == "!1 · No reviewers yet · updated 5m ago · 3 files +10 −2 · pipeline success")
        #expect(mine.details(me: list.username, project: Self.project, now: Self.date("2026-10-28T13:00:00Z")).contains("updated 3h ago"))
        #expect(mine.details(me: list.username, project: Self.project, now: Self.date("2026-10-31T09:00:00Z")).contains("updated 2d ago"))
        // A clock that is behind never shows a negative age.
        #expect(mine.details(me: list.username, project: Self.project, now: Self.date("2026-10-28T09:00:00Z")).contains("updated 0m ago"))
    }

    @Test("MR-03 details name the author of someone else's MR")
    func detailsOfSomeoneElse() async throws {
        let list = try await Self.sectionsFixture()
        let theirs = try #require(list.mergeRequests.first { $0.iid == 2 })
        #expect(theirs.details(me: list.username, project: Self.project, now: Self.date("2026-10-28T10:05:00Z"))
            == "!2 · Review requested · Ready to merge · by Kim Reviewer · updated 1d ago · 0 files +0 −0")
    }

    @Test("MR-03 reference of another project")
    func otherProject() async throws {
        let list = try await Self.sectionsFixture()
        let other = try #require(list.mergeRequests.first { $0.iid == 5 })
        #expect(other.shortReference(project: Self.project) == "client!5")
        #expect(other.details(me: list.username, project: Self.project, now: Self.date("2026-10-28T10:00:00Z")).hasPrefix("client!5 · "))
        #expect(Self.mergeRequest(12).shortReference(project: Self.project) == "!12")
    }

    @Test("MR-03 diff stats singular and plural")
    func diffStats() async throws {
        let list = try await Self.sectionsFixture()
        let now = Self.date("2026-10-28T12:00:00Z")
        #expect(try #require(list.mergeRequests.first { $0.iid == 3 }).details(me: list.username, project: Self.project, now: now)
            .contains(" · 1 file +1 −0 · "))
        #expect(try #require(list.mergeRequests.first { $0.iid == 4 }).details(me: list.username, project: Self.project, now: now)
            .contains(" · 2 files +5 −5 · "))
    }

    @Test("MR-03 no pipeline part without a pipeline")
    func noPipeline() {
        let details = Self.mergeRequest(status: .mergeable).details(me: Self.me, project: Self.project, now: Self.date("2026-10-28T10:00:00Z"))
        #expect(details == "!1 · Ready to merge · updated 0m ago · 0 files +0 −0")
        #expect(Self.mergeRequest(pipeline: .canceled).details(me: Self.me, project: Self.project, now: .now).hasSuffix(" · pipeline canceled"))
    }
}

extension MergeRequest {
    fileprivate func with(reviewers: [Reviewer]) -> MergeRequest {
        var copy = self
        copy.reviewers = reviewers
        return copy
    }
}

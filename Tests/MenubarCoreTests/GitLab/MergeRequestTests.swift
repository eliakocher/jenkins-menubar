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

    @Test("MR-01 sorts my MRs and the reviews asked of me into sections, newest first")
    func sections() async throws {
        let list = try await Self.sectionsFixture()
        #expect(list.username == "alex.doe")

        let sections = MergeRequestSections(list.mergeRequests, me: list.username)
        #expect(sections.yours.map(\.iid) == [3, 1])
        #expect(sections.reviewRequested.map(\.iid) == [5, 2])
        #expect(sections.reviewed.map(\.iid) == [4])

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

        // Newest first, whatever the order GitLab sent.
        let unordered = MergeRequestSections([
            Self.mergeRequest(1, updatedAt: Self.date("2026-10-26T10:00:00Z")),
            Self.mergeRequest(2, updatedAt: Self.date("2026-10-28T10:00:00Z")),
            Self.mergeRequest(3, updatedAt: Self.date("2026-10-27T10:00:00Z")),
        ], me: Self.me)
        #expect(unordered.yours.map(\.iid) == [2, 3, 1])
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

    // MARK: - MR-02

    @Test("MR-02 the badge kind for every status, and which one wins when several apply")
    func everyStatus() {
        let cases: [(MergeRequest, MergeRequestStatus.Kind)] = [
            (Self.mergeRequest(status: .mergeable), .readyToMerge),
            (Self.mergeRequest(status: .draftStatus, draft: true), .draft),
            (Self.mergeRequest(status: .ciStillRunning, pipeline: .failed), .pipelineFailed),
            (Self.mergeRequest(status: .conflict), .conflicts),
            (Self.mergeRequest(status: .needRebase), .needsRebase),
            (Self.mergeRequest(status: .requestedChanges), .changesRequested),
            (Self.mergeRequest(status: .notApproved), .notApproved),
            (Self.mergeRequest(status: .discussionsNotResolved), .unresolvedThreads),
            (Self.mergeRequest(status: .ciStillRunning, pipeline: .running), .pipelineRunning),
            (Self.mergeRequest(status: .unchecked), .checking),
            (Self.mergeRequest(status: .checking), .checking),
            (Self.mergeRequest(status: .preparing), .checking),
            (Self.mergeRequest(status: .approvalsSyncing), .checking),
            (Self.mergeRequest(status: .init(rawValue: "BLOCKED_STATUS")), .other),
            // Ready to merge wins over draft, draft over a failed pipeline, a failed pipeline over conflicts.
            (Self.mergeRequest(status: .mergeable, draft: true, pipeline: .failed), .readyToMerge),
            (Self.mergeRequest(status: .conflict, draft: true, pipeline: .failed), .draft),
            (Self.mergeRequest(status: .conflict, pipeline: .failed), .pipelineFailed),
            (Self.mergeRequest(status: .conflict, pipeline: .success), .conflicts),
        ]
        for (index, (mergeRequest, kind)) in cases.enumerated() {
            #expect(MergeRequestStatus.of(mergeRequest, me: Self.me).kind == kind, "case \(index)")
        }
    }

    @Test("MR-02 a review asked of me wraps the status, and once my review is done it does not")
    func reviewRequestedBadge() async throws {
        let list = try await Self.sectionsFixture()
        let theirs = try #require(list.mergeRequests.first { $0.iid == 2 })
        #expect(MergeRequestStatus.of(theirs, me: list.username).kind == .reviewRequested)
        // The status alone, and once my review is done.
        #expect(MergeRequestStatus.of(theirs).kind == .readyToMerge)
        let approvedByMe = try #require(list.mergeRequests.first { $0.iid == 4 })
        #expect(MergeRequestStatus.of(approvedByMe, me: list.username).kind == .pipelineFailed)
    }

    @Test(
        "MR-02 the badge without the pipeline: what only the pipeline said gives way to the review state",
        arguments: [
            // status, pipeline, whether the one reviewer approved, review asked of me, the badge
            ("CI_MUST_PASS", "FAILED", false, false, "Missing 1 of 1 approval"),
            ("CI_MUST_PASS", "FAILED", true, false, "All reviewers approved"),
            ("CI_STILL_RUNNING", "RUNNING", false, false, "Missing 1 of 1 approval"),
            ("CI_MUST_PASS", "FAILED", false, true, "Review requested"),
            ("NOT_APPROVED", "FAILED", false, true, "Review requested · Missing 1 of 1 approval"),
            ("CONFLICT", "FAILED", false, false, "Merge conflicts"),
            ("MERGEABLE", "SUCCESS", false, false, "Ready to merge"),
        ] as [(String, String, Bool, Bool, String)])
    func badgeWithoutPipeline(status: String, pipeline: String, approved: Bool, asked: Bool, text: String) {
        let reviewer = asked ? Self.reviewer(Self.me, .unreviewed) : Self.reviewer("other", approved ? .approved : .unreviewed, approved: approved)
        let mergeRequest = Self.mergeRequest(
            status: .init(rawValue: status), pipeline: .init(rawValue: pipeline), reviewers: [reviewer],
            roles: asked ? [.reviewRequested] : [.authored])
        let shown = MergeRequestStatus.of(mergeRequest, me: Self.me, saysPipeline: false)
        #expect(shown.text == text)
        #expect(!MergeRequestStatus.textNamesPipeline(shown.text))
        // With the pipeline, the badge says it where it said it before.
        let said = MergeRequestStatus.of(mergeRequest, me: Self.me).text
        #expect(MergeRequestStatus.textNamesPipeline(said) == (pipeline != "SUCCESS" && status != "MERGEABLE"))
    }

    @Test("MR-03 the details leave out the pipeline when the badge names it or it is green, and keep it otherwise")
    func detailsPipelinePart() {
        let now = Self.date("2026-10-28T10:05:00Z")
        func details(_ status: String, _ pipeline: String) -> String {
            Self.mergeRequest(status: .init(rawValue: status), pipeline: .init(rawValue: pipeline))
                .details(me: Self.me, project: Self.project, now: now)
        }
        #expect(details("CI_MUST_PASS", "FAILED").hasSuffix("Pipeline failed · updated 5m ago"))
        #expect(details("CI_STILL_RUNNING", "RUNNING").lowercased().components(separatedBy: "pipeline").count == 2)
        // A green pipeline isn't news, and the diff stats are no part of the details.
        #expect(details("CONFLICT", "SUCCESS").hasSuffix("updated 5m ago"))
        #expect(details("MERGEABLE", "SUCCESS").hasSuffix("updated 5m ago"))
        #expect(details("CONFLICT", "CANCELED").hasSuffix("updated 5m ago · pipeline canceled"))
    }

    // MARK: - MR-03

    @Test("MR-03 the details show the age of the update in minutes, hours and days, and never a negative one")
    func detailsAge() async throws {
        let list = try await Self.sectionsFixture()
        let mine = try #require(list.mergeRequests.first { $0.iid == 1 })
        func details(_ now: String) -> String {
            mine.details(me: list.username, project: Self.project, now: Self.date(now))
        }
        #expect(details("2026-10-28T10:05:30Z").contains("updated 5m ago"))
        #expect(details("2026-10-28T13:00:00Z").contains("updated 3h ago"))
        #expect(details("2026-10-31T09:00:00Z").contains("updated 2d ago"))
        // A clock that is behind never shows a negative age.
        #expect(details("2026-10-28T09:00:00Z").contains("updated 0m ago"))
    }
}

extension MergeRequest {
    fileprivate func with(reviewers: [Reviewer]) -> MergeRequest {
        var copy = self
        copy.reviewers = reviewers
        return copy
    }
}

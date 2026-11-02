import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MergeRequestPipelineChip")
@MainActor
struct PipelineChipRuleTests {
    private static let fixtures = Fixtures()

    enum PipelineChipCase: String, CaseIterable, Sendable {
        /// the Jenkins build is unstable, GitLab says failed: the build's chip, GitLab's word in its tooltip
        case jenkinsUnstableGitLabFailed
        /// both say failed: the build's chip, nothing to add
        case jenkinsFailedGitLabFailed
        /// no pipeline in GitLab, a Jenkins build: the build's chip
        case jenkinsOnly
        /// GitLab's pipeline failed and the badge says "Pipeline failed": no second chip
        case badgeSaysIt
        /// GitLab's pipeline succeeded, no Jenkins build: GitLab's chip
        case gitLabOnly
        /// nothing at all
        case noPipeline
    }

    @Test(
        "MR-14 one chip for the pipeline: the Jenkins build when the app knows it, else GitLab's, never both",
        arguments: PipelineChipCase.allCases)
    func oneChip(_ which: PipelineChipCase) throws {
        let m = Self.fixtures.mergeRequestsScreen
        let noPipeline = m.mergeRequest(5, "No pipeline here", pipeline: nil)
        let unstable = BuildPhase.finished(result: .unstable, duration: 60)
        let failed = BuildPhase.finished(result: .failure, duration: 60)
        let (mergeRequest, build, expected): (MergeRequest, Build?, MergeRequestPipelineChip) = switch which {
        case .jenkinsUnstableGitLabFailed:
            (m.mr16, m.build(of: m.mr16, number: 4, phase: unstable),
             .jenkins(help: "Show build #4 in Pipelines (GitLab's pipeline: failed)"))
        case .jenkinsFailedGitLabFailed:
            (m.mr16, m.build(of: m.mr16, number: 4, phase: failed), .jenkins(help: "Show build #4 in Pipelines"))
        case .jenkinsOnly:
            (noPipeline, m.build(of: noPipeline, number: 7, phase: failed), .jenkins(help: "Show build #7 in Pipelines"))
        case .badgeSaysIt: (m.mr16, nil, .hidden)
        case .gitLabOnly: (m.mr21, nil, .gitLab)
        case .noPipeline: (noPipeline, nil, .none)
        }
        let detail = try #require(MergeRequestDetailModel(
            MergeRequestsData(m.panel(m.sections + [m.mr16, noPipeline], builds: build.map { [$0] } ?? [])),
            selection: mergeRequest.id))
        #expect(MergeRequestPipelineChip.of(detail) == expected)
    }

    @Test(
        "MR-14 a badge about the pipeline is told apart, also behind Review requested",
        arguments: [
            ("Pipeline failed", true), ("Pipeline running", true), ("Review requested · Pipeline failed", true),
            ("Review requested · Ready to merge", false), ("Ready to merge", false), ("Changes requested", false),
        ])
    func badgeNamesPipeline(text: String, names: Bool) {
        #expect(MergeRequestPipelineChip.statusNamesPipeline(text) == names)
    }

    @Test(
        "MR-14 while the Jenkins chip shows, the badge leaves the pipeline out; without it, the badge keeps it",
        arguments: [
            // status, pipeline, my roles, the badge with the build, the badge without it
            ("CI_MUST_PASS", "FAILED", [.authored], "Missing 1 of 1 approval", "Pipeline failed"),
            ("CI_STILL_RUNNING", "RUNNING", [.authored], "Missing 1 of 1 approval", "Pipeline running"),
            ("CI_MUST_PASS", "FAILED", [.reviewRequested], "Review requested", "Review requested · Pipeline failed"),
            // a badge about something else stays, behind Review requested too
            ("REQUESTED_CHANGES", "FAILED", [.authored], "Changes requested", "Pipeline failed"),
            ("NOT_APPROVED", "SUCCESS", [.reviewRequested], "Review requested · Missing 1 of 1 approval",
             "Review requested · Missing 1 of 1 approval"),
            ("MERGEABLE", "SUCCESS", [.authored], "Ready to merge", "Ready to merge"),
        ] as [(String, String, Set<MergeRequest.Role>, String, String)])
    func badgeWithoutPipeline(
        status: String, pipeline: String, roles: Set<MergeRequest.Role>, withBuild: String, withoutBuild: String
    ) throws {
        let m = Self.fixtures.mergeRequestsScreen
        let mergeRequest = m.mergeRequest(
            9, "Badge", status: status, pipeline: pipeline, reviewers: [m.reviewer("jdoe", .unreviewed)], roles: roles)
        let build = m.build(of: mergeRequest, number: 2, phase: .finished(result: .failure, duration: 60))
        func badge(builds: [Build]) throws -> String {
            try #require(MergeRequestDetailModel(
                MergeRequestsData(m.panel(m.sections + [mergeRequest], builds: builds)), selection: mergeRequest.id)).status.text
        }
        #expect(try badge(builds: [build]) == withBuild)
        #expect(try badge(builds: []) == withoutBuild)
    }
}

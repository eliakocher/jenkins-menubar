import Foundation
import Testing

@testable import MenubarCore

/// Which MRs offer Watch Builds, and when it reads Watching.
@Suite("MergeRequestWatch")
struct MergeRequestWatchTests {
    private static func mergeRequest(author: String, roles: Set<MergeRequest.Role>) -> MergeRequest {
        MergeRequest(
            iid: 12437, title: "Change", webURL: URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12437")!,
            reference: "group/project!12437", author: MergeRequest.Person(username: author, name: author),
            updatedAt: Date(timeIntervalSince1970: 1_792_800_000), roles: roles)
    }

    struct Case: Sendable {
        var author: String
        var roles: Set<MergeRequest.Role>
        var myJobs: [String]?
        var watched: [String]
        var expected: MergeRequestWatch
    }

    @Test(
        "WATCH-01 an MR offers Watch Builds unless it is mine, and reads Watching once its job is watched",
        arguments: [
            // someone else's, not watched yet, with and without the jobs known
            Case(author: "akim", roles: [.reviewRequested], myJobs: nil, watched: [], expected: .watch(job: "MR-12437")),
            Case(author: "akim", roles: [.reviewRequested], myJobs: ["MR-1"], watched: [], expected: .watch(job: "MR-12437")),
            // watched, though its build isn't in Pipelines yet
            Case(author: "akim", roles: [.reviewRequested], myJobs: ["MR-1"], watched: ["MR-12437"], expected: .watching(job: "MR-12437")),
            // mine by the author, by the role, or by the Jenkins lookup: tracked anyway
            Case(author: "me", roles: [.reviewRequested], myJobs: nil, watched: [], expected: .hidden),
            Case(author: "akim", roles: [.authored], myJobs: nil, watched: [], expected: .hidden),
            Case(author: "akim", roles: [.reviewRequested], myJobs: ["MR-12437"], watched: [], expected: .hidden),
        ])
    func offer(_ testCase: Case) {
        let mergeRequest = Self.mergeRequest(author: testCase.author, roles: testCase.roles)
        #expect(
            MergeRequestWatch.of(mergeRequest, me: "me", myJobs: testCase.myJobs, watchedJobs: testCase.watched)
                == testCase.expected)
    }
}

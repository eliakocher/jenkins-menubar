import Foundation
import Testing

@testable import MenubarCore

/// GitLab's related issues (82 KB, the slowest request of a merge request's detail) are asked only when they can matter.
@Suite("Related issues are asked only when needed")
struct RelatedIssuesAskTests {
    private static let gitLab = URL(string: "https://gitlab.example.com")!
    private static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private static let closing = #"[{"iid":7,"web_url":"https://gitlab.example.com/group/project/-/issues/7","references":{"full":"group/project#7"}}]"#

    private static func stub(closes: String) -> StubTransport {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestClosesIssues", body: closes)
        stub.answer(operation: "MergeRequestRelatedIssues", body: closing)
        return stub
    }

    @Test(
        "MR-12 the related issues are asked when neither the title nor a closing issue names a work item, or the title isn't known",
        arguments: [
            ("Add a retry", "[]", "", 1), ("#19202 Add a retry", "[]", "", 0), ("Add a retry", closing, "", 0),
            ("Resolve \"cascade\"", "[]", "Resolve", 0),
        ])
    func asksOnlyWhenNeeded(title: String, closes: String, ignoredPrefix: String, related: Int) async throws {
        let stub = Self.stub(closes: closes)
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t")

        _ = try await client.workItemLinks(of: Self.source, title: title, ignoredPrefix: ignoredPrefix)

        #expect(stub.requests(operation: "MergeRequestClosesIssues").count == 1)
        #expect(stub.requests(operation: "MergeRequestRelatedIssues").count == related)
    }

    @Test("MR-12 without a title the related issues are asked, as before, also next to a closing issue")
    func unknownTitle() async throws {
        let stub = Self.stub(closes: Self.closing)

        let links = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t").workItemLinks(of: Self.source)

        #expect(stub.requests(operation: "MergeRequestRelatedIssues").count == 1)
        #expect(links.related.map(\.iid) == [7])
    }
}

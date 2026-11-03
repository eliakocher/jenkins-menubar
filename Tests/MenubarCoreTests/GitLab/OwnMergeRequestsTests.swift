import Foundation
import Testing

@testable import MenubarCore

/// Which merge requests are a work item's own, and the branch name the team gives it.
@Suite("Own merge requests and branch names")
struct OwnMergeRequestsTests {
    private static let project = "acme/main/server"

    private static func item(_ iid: Int = 18874, title: String = "Fix closing the dialog", project: String = project) -> WorkItem {
        WorkItem(
            reference: "\(project)#\(iid)", title: title, webURL: URL(string: "https://gitlab.example.com/x")!,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func mergeRequest(
        _ iid: Int, title: String = "Something else", branch: String? = nil, closes: Bool = false, project: String = project
    ) -> RelatedMergeRequest {
        RelatedMergeRequest(
            iid: iid, state: .merged, title: title, webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
            reference: "\(project)!\(iid)", sourceBranch: branch, closesWorkItem: closes)
    }

    @Test("WI-05 an MR is the item's own by its source branch, which starts with the item's number and a dash")
    func ownByBranch() {
        let item = Self.item()
        #expect(Self.mergeRequest(1, branch: "18874-fix-closing-the-dialog").isOwn(of: item))
        #expect(!Self.mergeRequest(2, branch: "188741-other").isOwn(of: item))
        #expect(!Self.mergeRequest(3, branch: "18874").isOwn(of: item))
        #expect(!Self.mergeRequest(4, branch: "feature/18874-x").isOwn(of: item))
        #expect(!Self.mergeRequest(5, branch: nil).isOwn(of: item))
    }

    @Test("WI-05 an MR is the item's own by its title, which starts with the item's number")
    func ownByTitle() {
        let item = Self.item()
        #expect(Self.mergeRequest(1, title: "#18874 Fix closing the dialog").isOwn(of: item))
        #expect(Self.mergeRequest(2, title: "Draft: #18874 Fix closing the dialog").isOwn(of: item))
        #expect(Self.mergeRequest(3, title: "#18874").isOwn(of: item))
        #expect(!Self.mergeRequest(4, title: "#188741 Another one").isOwn(of: item))
        #expect(!Self.mergeRequest(5, title: "Backport of #18874").isOwn(of: item))
    }

    @Test("WI-05 an MR that closes the item is its own, whatever its branch and title")
    func ownByClosing() {
        #expect(Self.mergeRequest(1, closes: true).isOwn(of: Self.item()))
    }

    @Test("WI-05 an MR of another project is not the item's own by number, only by closing")
    func otherProject() {
        let item = Self.item()
        let other = "acme/main/client"
        #expect(!Self.mergeRequest(1, title: "#18874 x", branch: "18874-x", project: other).isOwn(of: item))
        #expect(Self.mergeRequest(1, closes: true, project: other).isOwn(of: item))
    }

    @Test("WI-05 the chips, marker and slots count the own MRs, or all of them when none is")
    func shown() {
        let item = Self.item()
        let own = Self.mergeRequest(1, branch: "18874-fix")
        let mention = Self.mergeRequest(2, title: "Work on #5 that names #18874")
        let backport = Self.mergeRequest(3, title: "#18874 Backport")
        #expect(item.shownMergeRequests(from: [mention, own, backport]) == [own, backport])
        // None is its own: all show, as before the split.
        #expect(item.shownMergeRequests(from: [mention]) == [mention])
        #expect(item.shownMergeRequests(from: []).isEmpty)

        let cache = RelatedMergeRequestsCache(entries: [
            item.reference: .init(workItemUpdatedAt: item.updatedAt, fetchedAt: item.updatedAt, mergeRequests: [mention, own])
        ])
        #expect(cache.shownMergeRequests(of: item) == [own])
        #expect(cache.shownMergeRequests(of: Self.item(5)) == nil)
    }

    @Test("WI-05 a cache entry from before the source branch was asked for still reads")
    func oldCacheEntry() throws {
        let json = #"{"iid":1,"state":"merged","title":"t","webURL":"https://gitlab.example.com/a","reference":"a/b!1"}"#
        let decoded = try JSONDecoder().decode(RelatedMergeRequest.self, from: Data(json.utf8))
        #expect(decoded.sourceBranch == nil && !decoded.closesWorkItem)
        let again = try JSONDecoder().decode(RelatedMergeRequest.self, from: JSONEncoder().encode(Self.mergeRequest(2, branch: "2-x", closes: true)))
        #expect(again.sourceBranch == "2-x" && again.closesWorkItem)
    }

    @Test("WI-05 the query asks for the source branch and reads it")
    func queryAsksSourceBranch() async throws {
        let operation = try #require(GitLabOperation.relatedMergeRequests(of: Self.item()))
        #expect(operation.query.contains("sourceBranch"))
        let body = #"{"data":{"project":{"issue":{"relatedMergeRequests":{"nodes":[{"iid":"7","state":"merged","title":"t","webUrl":"https://gitlab.example.com/a","reference":"a/b!7","sourceBranch":"18874-x"}]}}}}}"#
        let stub = StubTransport()
        stub.answer(operation: "RelatedMergeRequests", body: body)
        let client = GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: "t")
        #expect(try await client.send(operation).first?.sourceBranch == "18874-x")
    }

    @Test(
        "WI-04 the branch name is the number, a dash and the title in lowercase kebab case",
        arguments: [
            ("Fix closing the dialog", "18874-fix-closing-the-dialog"),
            ("Café: déjà vu, Zürich", "18874-cafe-deja-vu-zurich"),
            ("Fix \"quoted\" and 'single' text", "18874-fix-quoted-and-single-text"),
            ("Move a/b\\c to d/e", "18874-move-a-b-c-to-d-e"),
            ("Crash 💥 on start 🚀", "18874-crash-on-start"),
            ("💥", "18874"),
            ("#123 Fix it", "18874-123-fix-it"),
            ("Draft: Try this", "18874-draft-try-this"),
            ("  ...Leading and trailing!!!  ", "18874-leading-and-trailing"),
            ("Support v2.0 of the API", "18874-support-v2-0-of-the-api"),
            ("日本語 title", "18874-title"),
            ("", "18874"),
        ])
    func branchName(title: String, expected: String) {
        #expect(Self.item(title: title).branchName == expected)
    }

    @Test("WI-04 the branch name has no length cap and ends without a dash")
    func branchNameLength() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let name = Self.item(title: long).branchName
        #expect(name.count == 5 + 1 + 60 * 5 - 1)
        #expect(!name.hasSuffix("-"))
    }
}

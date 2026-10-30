import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("MergeRequestsModel")
@MainActor
struct MergeRequestsModelTests {
    private static let fixtures = Fixtures()

    /// Which build Pipelines shows next to the selected MR.
    enum BuildCase: String, CaseIterable, Sendable {
        /// my review's MR, whose build I watch, running
        case watchedRunning
        /// my MR, whose build failed
        case mineFailed
        /// Jenkins' `objectUrl` with a trailing slash
        case trailingSlash
        /// only another MR's build
        case otherMergeRequest
    }

    @Test("WIN-02 MR detail shows its Jenkins build", arguments: BuildCase.allCases)
    func jenkinsBuild(_ buildCase: BuildCase) throws {
        let m = Self.fixtures.mergeRequestsScreen
        let failed = BuildPhase.finished(result: .failure, duration: 12 * 60)
        let (selected, build, expected): (MergeRequest, Build, String?) = switch buildCase {
        case .watchedRunning: (m.mr14, m.build(of: m.mr14, number: 3, phase: .running, kind: .watched), "!14 #3 · running")
        case .mineFailed: (m.mr16, m.build(of: m.mr16, number: 3, phase: failed), "!16 #3 · FAILURE")
        case .trailingSlash:
            (m.mr21, {
                var build = m.build(of: m.mr21, number: 4, phase: .running)
                build.gitLabURL = URL(string: m.mr21.webURL.absoluteString + "/")
                return build
            }(), "!21 #4 · running")
        case .otherMergeRequest: (m.mr21, m.build(of: m.mr14, number: 3, phase: .running), nil)
        }
        let detail = try #require(MergeRequestDetailModel(
            MergeRequestsData(m.panel(m.sections + [m.mr16], builds: [build])), selection: selected.id))
        #expect(detail.jenkinsBuild?.text == expected)
        // "Show in Pipelines" selects the build's job.
        #expect(detail.jenkinsBuild?.job == (expected == nil ? nil : build.job))
    }

    @Test(
        "WIN-03 search filters the current section by title, label and author",
        arguments: [
            ("color", ["!14"], ["#31"]),
            ("SAM LEE", ["!24", "!14"], []),
            ("web!8", ["web!8"], []),
            ("design", [], ["#31", "&12"]),
            // Neither the badge text nor the reviewers match, as in the panel.
            ("ready", [], []),
            ("Alex Kim", ["web!8"], []),
        ])
    func searchFilters(query: String, mergeRequests: [String], workItems: [String]) {
        let f = Self.fixtures
        let list = MergeRequestsListModel(MergeRequestsData(f.mergeRequestsScreen.panel()), query: query)
        #expect(list.sections.flatMap(\.rows).map(\.shortReference) == mergeRequests)
        #expect(list.link == nil)
        #expect(list.findsNothing == mergeRequests.isEmpty)

        let items = WorkItemsListModel(f.workItemsScreen.data().data, query: query)
        #expect(items.sections.flatMap(\.rows).map(\.reference) == workItems)
        #expect(items.link == nil)
        #expect(items.findsNothing == workItems.isEmpty)
    }
}

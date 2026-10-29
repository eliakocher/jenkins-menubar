import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

@Suite("PipelinesListModel")
@MainActor
struct PipelinesListModelTests {
    private static let fixtures = Fixtures()

    @Test(
        "WIN-03 search filters the current section by title, label and author",
        arguments: [
            ("redirect", ["MR-12"]),
            ("!16 #3", ["MR-16"]),
            ("SAM LEE", ["MR-14"]),
            ("!2", ["MR-2"]),
            // Stage names don't match: nearly every build has tests.
            ("tests", []),
            ("", ["MR-12", "MR-16", "MR-9", "MR-14", "MR-2"]),
        ])
    func searchFilters(query: String, jobs: [String]) {
        let f = Self.fixtures
        let model = PipelinesListModel(f.pipelines(waiting: [f.waitingJob]), query: query)
        var shown: [String] = []
        if case .rows(let rows)? = model.myBuilds {
            shown += rows.map(\.build.job)
        }
        shown += model.watching.map(\.id)
        #expect(shown == jobs)
        // Problem rows stay; the link rows hide while searching, and finding nothing shows the system's view.
        #expect((model.allBuilds != nil) == query.isEmpty)
        #expect(model.findsNothing == jobs.isEmpty)
    }

    @Test("PROJ-05 with several projects, each row and the problem name their project, and ids keep projects apart")
    func severalProjects() throws {
        let f = Self.fixtures
        let client = ProjectID(rawValue: "p-client")!
        let clientJob = try #require(URL(string: "https://jenkins.example.com/job/client"))
        let builds = f.typicalBuilds
        let other = builds[1].stamped(client)
        var data = f.pipelines(problem: .unknownJob, mine: [builds[0], builds[1], other])
        data.panel.jenkins.projects = [
            .main: PanelData.Jenkins.ProjectInfo(name: "server", jobURL: f.jobURL),
            client: PanelData.Jenkins.ProjectInfo(name: "client", jobURL: clientJob),
        ]
        data.panel.jenkins.problemProject = "client"

        let model = PipelinesListModel(data, query: "")
        guard case .rows(let rows)? = model.myBuilds else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.map(\.build.jobKey) == ["MR-12", "MR-16", "p-client/MR-16"])
        #expect(rows.map { $0.reference.components(separatedBy: " · ").first } == ["server", "server", "client"])
        #expect(rows[2].buildPage?.url.absoluteString.hasPrefix("https://jenkins.example.com/job/client/") == true)
        #expect(model.problems.map(\.text).contains("client: \(Problem.unknownJob.message)"))
        #expect(data.item("p-client/MR-16") != nil)
        #expect(BuildID.split(jobKey: "p-client/MR-16") == (client, "MR-16"))
        #expect(BuildID.split(jobKey: "MR-16") == (.main, "MR-16"))
    }
}

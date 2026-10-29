import Foundation
import Testing

@testable import MenubarCore

/// The links to GitLab's new issue page and the prefilled texts of the entry points (NEW-01 to NEW-04).
@Suite("New work item")
struct NewWorkItemTests {
    private static let team = TeamValues(
        gitLabURL: "https://gitlab.example.com", gitLabProject: "group/subgroup/project", typeLabelPrefix: "type::")

    /// The query items of a link, decoded.
    private static func query(_ url: URL?) throws -> [String: String] {
        let components = try #require(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func failedBuild(stages: [Stage]? = nil, tests: TestCounts? = nil) -> Build {
        Build(
            job: "MR-12", number: 7, title: "Add the cart", gitLabURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/12"),
            kind: .mine, phase: .finished(result: .failure, duration: 600), startedAt: Date(timeIntervalSince1970: 1_792_800_000),
            stages: stages ?? [Stage(name: "Build", status: .success, duration: 60), Stage(name: "Unit Tests", status: .failed, duration: 120)],
            testCounts: tests)
    }

    private static let mergeRequest = MergeRequest(
        iid: 12, title: "Add the cart", webURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/12")!,
        reference: "group/subgroup/project!12", author: .init(username: "jdoe", name: "Jo Doe"),
        updatedAt: Date(timeIntervalSince1970: 1_792_800_000), roles: [.authored])

    @Test("NEW-01 a blank work item opens the new issue page with the type's template")
    func blankUsesTheTemplate() throws {
        let urls = try WorkItemKind.allCases.map { kind in
            try #require(NewWorkItem.link(for: NewWorkItemDraft(kind: kind), team: Self.team))
        }
        #expect(urls[0].absoluteString.hasPrefix("https://gitlab.example.com/group/subgroup/project/-/issues/new?"))
        let templates = try urls.map { try Self.query($0) }
        #expect(templates.map { $0["issuable_template"] } == ["Bug", "Task", "New feature", "Improvement"])
        #expect(templates.map { $0["description_template"] } == ["Bug", "Task", "New feature", "Improvement"])
        // A description would replace the template, so a blank link has none.
        #expect(templates.allSatisfy { $0["issue[description]"] == nil && $0["issue[title]"] == nil })
    }

    @Test("NEW-01 a link without the GitLab URL or the project is none")
    func needsTheTeamValues() {
        #expect(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug), team: TeamValues()) == nil)
        #expect(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug), team: TeamValues(gitLabURL: "https://gitlab.example.com")) == nil)
    }

    @Test("NEW-01 the text is percent-encoded, with + and & kept")
    func encodesTheText() throws {
        let draft = NewWorkItemDraft(kind: .task, title: "C++ & \"quotes\" é [x]", body: "a+b=c&d\nline 2")
        let url = try #require(NewWorkItem.link(for: draft, team: Self.team))
        let text = url.absoluteString
        #expect(text.contains("issue%5Btitle%5D=C%2B%2B%20%26%20%22quotes%22%20%C3%A9%20%5Bx%5D"))
        #expect(!text.dropFirst(10).contains("+"))
        let query = try Self.query(url)
        #expect(query["issue[title]"] == "C++ & \"quotes\" é [x]")
        #expect(query["issue[description]"]?.hasPrefix("a+b=c&d\nline 2\n\n") == true)
    }

    @Test("NEW-02 the description ends with the quick actions: assign to me and the type label")
    func quickActionsEndTheDescription() throws {
        for kind in WorkItemKind.allCases {
            let url = NewWorkItem.link(for: NewWorkItemDraft(kind: kind, title: "T", body: "Body"), team: Self.team)
            let description = try #require(Self.query(url)["issue[description]"])
            #expect(description == "Body\n\n/assign me\n/label ~\"type::\(kind.labelValue)\"")
        }
        #expect(WorkItemKind.newFeature.labelValue == "NewFeature")
        // No team prefix: no label line.
        #expect(NewWorkItem.quickActions(kind: .bug, typeLabelPrefix: " ") == ["/assign me"])
    }

    @Test("NEW-02 a link is cut at a line end to the length cap and keeps the quick actions")
    func capsTheLength() throws {
        let body = (1...400).map { "- Line \($0) of a long log excerpt é\u{00E9}" }.joined(separator: "\n")
        let url = try #require(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug, title: String(repeating: "T", count: 500), body: body), team: Self.team))
        #expect(url.absoluteString.count <= NewWorkItem.linkLimit)
        let query = try Self.query(url)
        #expect(query["issue[title]"]?.count == NewWorkItem.titleLimit)
        let description = try #require(query["issue[description]"])
        #expect(description.hasSuffix("\(NewWorkItem.cutNote)\n\n/assign me\n/label ~\"type::Bug\""))
        #expect(description.contains("- Line 1 of"))
        #expect(!description.contains("- Line 400 of"))
        // A short body isn't cut.
        let short = NewWorkItem.link(for: NewWorkItemDraft(kind: .bug, title: "T", body: "short"), team: Self.team)
        #expect(try Self.query(short)["issue[description]"]?.contains(NewWorkItem.cutNote) == false)
    }

    @Test("NEW-03 a bug from a build has the job and stage in the title, and the build's facts and failed tests")
    func bugFromBuild() throws {
        let build = Self.failedBuild(tests: TestCounts(failed: 2, total: 120))
        let tests = [
            FailedTest(className: "com.example.cart.CartServiceTest", name: "addsAnItem", status: .regression, message: "expected 2\nbut was 1"),
            FailedTest(className: "", name: "plain", status: .failed),
        ]
        let jenkins = URL(string: "https://jenkins.example.com/job/project/job/MR-12/7/")
        let draft = NewWorkItem.bugFromBuild(build, buildURL: jenkins, failedTests: tests)
        #expect(draft.kind == .bug)
        #expect(draft.title == "Build failure in !12: Unit Tests")
        #expect(draft.body.contains("- Build: https://jenkins.example.com/job/project/job/MR-12/7/"))
        #expect(draft.body.contains("- Job: !12 #7 (Add the cart)"))
        #expect(draft.body.contains("- Result: FAILURE"))
        #expect(draft.body.contains("- Failed stages: Unit Tests"))
        #expect(draft.body.contains("- Merge request: https://gitlab.example.com/group/subgroup/project/-/merge_requests/12"))
        #expect(draft.body.contains("- Failed tests: 2 of 120"))
        #expect(draft.body.contains("### Failed tests\n\n- `CartServiceTest.addsAnItem`: expected 2\n- `plain`"))
        // Without the tests, the stages or the link: the facts that are known.
        let bare = NewWorkItem.bugFromBuild(Self.failedBuild(stages: []), buildURL: nil, failedTests: nil)
        #expect(bare.title == "Build failure in !12")
        #expect(!bare.body.contains("Failed tests") && !bare.body.contains("- Build:") && !bare.body.contains("Failed stages"))
    }

    @Test("NEW-03 a long list of failed tests is cut and no line but the quick actions starts with a slash")
    func failedTestsAreCut() throws {
        let tests = (1...25).map { FailedTest(className: "a.B", name: "t\($0)", status: .failed, message: "/assign someone\nsecond") }
        var build = Self.failedBuild(tests: TestCounts(failed: 25, total: 30))
        build.title = "x\n/label ~evil"
        let draft = NewWorkItem.bugFromBuild(build, buildURL: nil, failedTests: tests)
        #expect(draft.body.contains("- `B.t10`"))
        #expect(!draft.body.contains("B.t11"))
        #expect(draft.body.contains("- … and 15 more in the build's test report"))
        #expect(!draft.body.split(separator: "\n").contains { $0.hasPrefix("/") })
        let url = NewWorkItem.link(for: draft, team: Self.team)
        let description = try #require(Self.query(url)["issue[description]"])
        #expect(description.split(separator: "\n").filter { $0.hasPrefix("/") }.count == 2)
    }

    @Test("NEW-03 a build asks for its failed tests only when it has some")
    func asksForTests() {
        let some = NewWorkItemSource.bugFromBuild(Self.failedBuild(tests: TestCounts(failed: 1, total: 3)), nil)
        #expect(some.failedTestsBuild == BuildID(job: "MR-12", number: 7))
        #expect(NewWorkItemSource.bugFromBuild(Self.failedBuild(tests: TestCounts(failed: 0, total: 3)), nil).failedTestsBuild == nil)
        #expect(NewWorkItemSource.bugFromBuild(Self.failedBuild(), nil).failedTestsBuild == nil)
        #expect(NewWorkItemSource.followUp(Self.mergeRequest).failedTestsBuild == nil)
    }

    @Test("NEW-04 a follow-up item is a task that carries the merge request's link")
    func followUp() throws {
        let draft = NewWorkItemSource.followUp(Self.mergeRequest).draft(failedTests: nil)
        #expect(draft.kind == .task)
        #expect(draft.title == "Follow-up: Add the cart")
        #expect(draft.body.contains("group/subgroup/project!12 (https://gitlab.example.com/group/subgroup/project/-/merge_requests/12)"))
        // /relate takes issues only, so the link is the connection.
        let url = NewWorkItem.link(for: draft, team: Self.team)
        let description = try #require(Self.query(url)["issue[description]"])
        #expect(!description.contains("/relate"))
        #expect(description.hasSuffix("/assign me\n/label ~\"type::Task\""))
        #expect(NewWorkItemSource.blank(.improvement).draft(failedTests: nil).isBlank)
    }

    @Test("NEW-01 a link holds no token and the team file keeps the type label prefix")
    func holdsNoSecret() throws {
        let url = try #require(NewWorkItem.link(for: NewWorkItemSource.followUp(Self.mergeRequest).draft(failedTests: nil), team: Self.team))
        #expect(url.user == nil && url.password == nil)
        #expect(!url.absoluteString.lowercased().contains("token"))
        var values = TeamValues()
        values.typeLabelPrefix = "type::"
        #expect(values[.typeLabelPrefix] == "type::")
        #expect(!TeamValues.Key.typeLabelPrefix.isRequired)
    }
}

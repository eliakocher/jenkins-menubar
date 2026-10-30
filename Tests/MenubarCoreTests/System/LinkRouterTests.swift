import Foundation
import Testing

@testable import MenubarCore

@Suite("LinkRouter")
@MainActor
struct LinkRouterTests {
    private static let main = Project(id: .main, team: TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/My%20Project", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/project"))
    private static let router = LinkRouter(projects: [main])

    private static func route(_ link: String) -> LinkRoute {
        URL(string: link).map(router.route) ?? .browser
    }

    @Test("APP-09 sorts Jenkins links into builds and jobs")
    func jenkins() {
        let base = "https://jenkins.example.com/job/My%20Project/job"
        #expect(Self.route("\(base)/MR-12/45/") == .jenkinsBuild(project: .main, job: "MR-12", number: 45))
        #expect(Self.route("\(base)/MR-12/45/console") == .jenkinsBuild(project: .main, job: "MR-12", number: 45))
        #expect(Self.route("\(base)/MR-12/45/testReport/?x=1#top") == .jenkinsBuild(project: .main, job: "MR-12", number: 45))
        #expect(Self.route("\(base)/MR-12/") == .jenkinsJob(project: .main, job: "MR-12"))
        #expect(Self.route("\(base)/MR-12/lastBuild/") == .jenkinsJob(project: .main, job: "MR-12"))
        // A branch job keeps its encoding, a space in the job URL matches its %20, and the host's case is ignored.
        #expect(Self.route("\(base)/feature%252Ffoo/7") == .jenkinsBuild(project: .main, job: "feature%252Ffoo", number: 7))
        #expect(Self.route("https://JENKINS.example.com/job/My Project/job/MR-3") == .jenkinsJob(project: .main, job: "MR-3"))
        // The job URL itself, another multibranch job and another server are not ours to show.
        #expect(Self.route("https://jenkins.example.com/job/My%20Project/") == .browser)
        #expect(Self.route("https://jenkins.example.com/job/Other/job/MR-12/3/") == .browser)
        #expect(Self.route("https://jenkins.other.example.com/job/My%20Project/job/MR-12/3/") == .browser)
    }

    @Test("APP-09 sorts GitLab links into merge requests, work items and pipelines")
    func gitLab() {
        let base = "https://gitlab.example.com"
        #expect(Self.route("\(base)/group/project/-/merge_requests/12") == .mergeRequest(gitLabProject: "group/project", iid: 12))
        #expect(Self.route("\(base)/group/project/-/merge_requests/12/diffs?commit_id=abc#note_5")
            == .mergeRequest(gitLabProject: "group/project", iid: 12))
        #expect(Self.route("\(base)/group/project/merge_requests/12") == .mergeRequest(gitLabProject: "group/project", iid: 12))
        // Another project of the same GitLab is a merge request too: the window decides whether it has it.
        #expect(Self.route("\(base)/group/sub/other/-/merge_requests/3") == .mergeRequest(gitLabProject: "group/sub/other", iid: 3))
        #expect(Self.route("\(base)/group/project/-/issues/7") == .workItem(gitLabProject: "group/project", iid: 7))
        #expect(Self.route("\(base)/group/project/-/work_items/8#note_1") == .workItem(gitLabProject: "group/project", iid: 8))
        #expect(Self.route("\(base)/group/project/-/pipelines/900") == .pipeline(gitLabProject: "group/project", id: 900))
        // Everything else on GitLab stays in the browser.
        for page in ["", "/group/project", "/group/project/-/merge_requests", "/group/project/-/merge_requests/new",
            "/group/project/-/jobs/5", "/group/project/-/tree/main", "/groups/group/-/epics/4", "/dashboard/merge_requests"] {
            #expect(Self.route(base + page) == .browser, "\(page)")
        }
    }

    @Test("APP-09 passes other hosts, schemes and malformed links to the browser")
    func others() {
        for link in ["https://example.com/group/project/-/merge_requests/12", "https://github.com/a/b/pull/1",
            "ftp://gitlab.example.com/group/project/-/merge_requests/12", "mailto:jane@example.com", "not a url", "",
            "https://gitlab.example.com:8443/group/project/-/merge_requests/12", "http://"] {
            #expect(Self.route(link) == .browser, "\(link)")
        }
        // http reaches the same host.
        #expect(Self.route("http://gitlab.example.com/group/project/-/merge_requests/1") == .mergeRequest(gitLabProject: "group/project", iid: 1))
        // No projects, nothing is ours.
        let none = LinkRouter(projects: [])
        #expect(none.route(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12")!) == .browser)
    }

    @Test("APP-09 reads the links against every project")
    func severalProjects() {
        let second = Project(id: ProjectID(rawValue: "second")!, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/second", gitLabURL: "https://gitlab.example.com",
            gitLabProject: "group/second"))
        let router = LinkRouter(projects: [Self.main, second])
        #expect(router.route(URL(string: "https://jenkins.example.com/job/second/job/MR-5/2/")!)
            == .jenkinsBuild(project: second.id, job: "MR-5", number: 2))
        #expect(router.route(URL(string: "https://jenkins.example.com/job/My%20Project/job/MR-5/2/")!)
            == .jenkinsBuild(project: .main, job: "MR-5", number: 2))
    }
}

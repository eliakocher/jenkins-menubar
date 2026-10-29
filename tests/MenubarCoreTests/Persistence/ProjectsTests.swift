import Foundation
import Testing

@testable import MenubarCore

@Suite("Several projects")
struct ProjectsTests {
    static let primary = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/Team/job/group%252Fserver",
        gitLabURL: "https://gitlab.example.com", gitLabProject: "group/server", committedLabel: "Committed")
    static let second = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/Team/job/group%252Fclient",
        gitLabURL: "https://gitlab.example.com/", gitLabProject: " group/client ")

    @Test("PROJ-01 a stored single project reads as the primary one, unchanged")
    func singleProjectUnchanged() throws {
        let folder = try TemporaryFolder()
        // projects.json as every earlier version wrote it.
        try folder.write(
            #"{"formatVersion": 1, "projects": [{"id": "main", "team": {"jenkinsJobURL": "https://jenkins.example.com/job/Team/job/group%252Fserver", "gitLabURL": "https://gitlab.example.com", "gitLabProject": "group/server", "committedLabel": "Committed"}}]}"#,
            to: "projects.json")
        let store = TeamStore(folder: folder.url, report: { _ in })

        #expect(store.projects() == [Project(id: .main, team: Self.primary)])
        #expect(store.primaryProject() == Project(id: .main, team: Self.primary))
        #expect(store.project(.main) == store.primaryProject())
        #expect(store.project(ProjectID(rawValue: "other")!) == nil)
    }

    @Test("PROJ-01 projects are named by the last part of their path, the full path when two share it")
    func names() {
        let server = Project(id: .main, team: Self.primary)
        let client = Project(id: ProjectID(rawValue: "c")!, team: Self.second.normalized())
        let fork = Project(id: ProjectID(rawValue: "f")!, team: TeamValues(gitLabProject: "fork/server"))

        #expect(Project.names(of: [server, client]) == [.main: "server", client.id: "client"])
        #expect(Project.names(of: [server, client, fork])
            == [.main: "group/server", client.id: "client", fork.id: "fork/server"])
        #expect(Project(id: .main, team: TeamValues()).shortName == "Project")
    }

    @Test("PROJ-02 adds a project after the primary one, normalized, with a new id")
    func adds() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        try store.save(Project(id: .main, team: Self.primary))

        let added = try store.add(Self.second)

        #expect(added.id != .main)
        #expect(added.team == Self.second.normalized())
        #expect(store.projects().map(\.id) == [.main, added.id])
        #expect(store.primaryProject().id == .main)
    }

    @Test("PROJ-02 refuses an incomplete project, the same job, and another Jenkins or GitLab")
    func refuses() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        try store.save(Project(id: .main, team: Self.primary))
        var sameJob = Self.second
        sameJob.jenkinsJobURL = "https://JENKINS.example.com/job/Team/job/group%2Fserver/"
        var otherJenkins = Self.second
        otherJenkins.jenkinsJobURL = "https://ci.example.org/job/x"
        var otherGitLab = Self.second
        otherGitLab.gitLabURL = "https://gitlab.example.org"

        #expect(throws: ProjectError.incomplete) { try store.add(TeamValues(gitLabProject: "g/p")) }
        #expect(throws: ProjectError.sameJob("server")) { try store.add(sameJob) }
        #expect(throws: ProjectError.otherJenkins("server")) { try store.add(otherJenkins) }
        #expect(throws: ProjectError.otherGitLab("server")) { try store.add(otherGitLab) }
        #expect(store.projects().count == 1)
        #expect(ProjectError.otherJenkins("server").message
            == "Uses another Jenkins than server: the Jenkins token is for one server")
    }

    @Test("PROJ-02 removes a project but never the primary one, and forgets only its state")
    func removes() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        let states = UserStateStore(folder: folder.url, report: { _ in })
        try store.save(Project(id: .main, team: Self.primary))
        let added = try store.add(Self.second)
        let watched = UserState(hidden: ["MR-1": 3])
        try states.save(watched, for: .main)
        try states.save(watched, for: added.id)

        #expect(throws: ProjectError.primary) { try store.remove(.main) }
        try store.remove(added.id)
        try states.remove(added.id)

        #expect(store.projects().map(\.id) == [.main])
        #expect(states.load(.main) == watched)
        #expect(states.load(added.id) == UserState())
    }

    @Test("PROJ-02 a team file imports into and exports from the chosen project")
    func teamFilePerProject() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.file("support"), report: { _ in })
        try store.save(Project(id: .main, team: Self.primary))
        let added = try store.add(Self.second)
        var changed = Self.second.normalized()
        changed.committedLabel = "Done"
        let file = folder.file("team.json")
        let other = TeamStore(folder: folder.file("other"), report: { _ in })
        try other.save(Project(id: .main, team: changed))
        try other.exportTeamFile(to: file)

        try store.importTeamFile(from: file, into: added.id)
        try store.exportTeamFile(of: added.id, to: folder.file("back.json"))

        #expect(store.project(added.id)?.team == changed)
        #expect(store.primaryProject().team == Self.primary)
        #expect(try TeamStore.readTeamFile(from: folder.file("back.json")) == changed)
        // A file of the primary project itself can't become a second project.
        try store.exportTeamFile(to: file)
        #expect(throws: ProjectError.sameJob("server")) { try store.importTeamFile(from: file, into: added.id) }
    }
}

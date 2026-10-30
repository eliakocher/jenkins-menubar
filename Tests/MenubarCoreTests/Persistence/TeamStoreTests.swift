import Foundation
import Testing

@testable import MenubarCore

@Suite("TeamStore")
struct TeamStoreTests {
    private static let team = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/GitLab%20Team/job/group%252Fproject",
        gitLabURL: "https://gitlab.example.com", gitLabProject: "group/subgroup/project",
        committedLabel: "cLevel::Committed", slotLabelPrefix: "cDueSlot::", ignoredMergeRequestPrefix: "[ucascade]")

    private static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("TEAM-02 export then import gives the same values")
    func exportThenImport() throws {
        let folder = try TemporaryFolder()
        let mine = TeamStore(folder: folder.file("mine"), report: { _ in })
        let colleague = TeamStore(folder: folder.file("colleague"), report: { _ in })
        try mine.save(Project(id: .main, team: Self.team))

        try mine.exportTeamFile(to: folder.file("team.json"))
        let imported = try colleague.importTeamFile(from: folder.file("team.json"))

        #expect(imported == Project(id: .main, team: Self.team))
        #expect(colleague.primaryProject() == imported)
        #expect(colleague.projects() == [imported])
    }

    @Test("TEAM-02 export holds no token")
    func exportHoldsNoToken() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        try store.save(Project(id: .main, team: Self.team))

        try store.exportTeamFile(to: folder.file("team.json"))
        let text = try folder.read("team.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(Set(json.keys) == ["formatVersion", "team"])
        #expect(json["formatVersion"] as? Int == TeamStore.formatVersion)
        #expect(Set((json["team"] as? [String: String] ?? [:]).keys) == Set(TeamValues.Key.allCases.map(\.rawValue)))
        for secret in ["JENKINS_MCP_BASIC_AUTH", "GITLAB_TOKEN", "Authorization", "token", "Token", "glpat-"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test("TEAM-02 refuses a newer format version")
    func refusesNewerVersion() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.file("support"), report: { _ in })
        let file = try folder.write(#"{"formatVersion": 2, "team": {"gitLabURL": "https://gitlab.example.com"}, "more": 1}"#,
                                    to: "team.json")

        #expect(throws: TeamFileError.newerFormat(2)) {
            try store.importTeamFile(from: file)
        }
        #expect(TeamFileError.newerFormat(2).message
            == "That team file is from a newer MegaMonitor (format 2): update the app first")
        #expect(store.projects().isEmpty)
        #expect(!folder.contents().contains { $0.hasPrefix("support/") })
    }

    @Test("TEAM-02 team example file imports")
    func exampleImports() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        let example = Self.repositoryRoot.appending(path: "team.example.json")

        let project = try store.importTeamFile(from: example)

        #expect(project.team.missing.isEmpty)
        #expect(project.team.jenkinsJob != nil)
        #expect(project.team.gitLab != nil)
        // The example is written exactly as an export writes it, so it shows the real format.
        try store.exportTeamFile(to: folder.file("exported.json"))
        #expect(try folder.read("exported.json") == String(contentsOf: example, encoding: .utf8).trimmingCharacters(in: .newlines))
    }

    @Test("a file that is not a team file is refused with its reason", arguments: [
        "not json", "[]", #"{"team": {}}"#, #"{"formatVersion": "1", "team": {}}"#, #"{"formatVersion": 1}"#,
        #"{"formatVersion": 1, "team": []}"#, #"{"formatVersion": 1, "projects": []}"#,
    ])
    func refusesOtherFiles(content: String) throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.file("support"), report: { _ in })
        let file = try folder.write(content, to: "team.json")

        #expect(throws: TeamFileError.notATeamFile) {
            try store.importTeamFile(from: file)
        }
        #expect(store.projects().isEmpty)
    }

    @Test("a missing team file is refused as unreadable")
    func refusesMissingFile() throws {
        let folder = try TemporaryFolder()
        let error = try #require(throws: TeamFileError.self) {
            try TeamStore.readTeamFile(from: folder.file("nope.json"))
        }

        guard case .unreadable(let reason) = error else {
            Issue.record("expected unreadable, got \(error)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(error.message.hasPrefix("The team file could not be read: "))
    }

    @Test("an imported team file is normalized, and a missing value reads as empty")
    func importNormalizes() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write(
            #"{"formatVersion": 1, "team": {"jenkinsJobURL": " https://jenkins.example.com/job/x/ ", "gitLabURL": "https://gitlab.example.com/", "gitLabProject": "g/p", "unknown": "ignored"}}"#,
            to: "team.json")

        #expect(try TeamStore.readTeamFile(from: file) == TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/x", gitLabURL: "https://gitlab.example.com", gitLabProject: "g/p"))
    }

    @Test("projects are kept in projects.json, replaced by id, and v1 starts with an empty main project")
    func projects() throws {
        let folder = try TemporaryFolder()
        let store = TeamStore(folder: folder.url, report: { _ in })
        let other = Project(id: ProjectID(rawValue: "other")!, team: TeamValues(gitLabProject: "o/p"))

        #expect(store.primaryProject() == Project(id: .main, team: TeamValues()))
        #expect(store.primaryProject().team.missing == [.jenkinsJobURL, .gitLabURL, .gitLabProject])

        try store.save(Project(id: .main, team: TeamValues(gitLabProject: "first")))
        try store.save(other)
        try store.save(Project(id: .main, team: Self.team))

        #expect(store.projects() == [Project(id: .main, team: Self.team), other])
        #expect(store.primaryProject().team == Self.team)
        #expect(folder.contents() == ["projects.json"])
        #expect(try folder.read("projects.json").contains(#""formatVersion" : 1"#))
    }

    @Test("a corrupt projects.json counts as no projects and is reported")
    func corruptProjects() throws {
        let folder = try TemporaryFolder()
        let reports = FileStoreTests.Reports()
        try folder.write(#"{"formatVersion": 1, "projects": [{"id": "../x", "team": {}}]}"#, to: "projects.json")
        let store = TeamStore(folder: folder.url, report: reports.add)

        #expect(store.projects().isEmpty)
        #expect(store.primaryProject().id == .main)
        #expect(reports.all.count == 1)
    }
}

import Foundation
import Testing

@testable import MenubarCore

@Suite("TeamFileImport")
struct TeamFileImportTests {
    private static let team = TeamValues(
        jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: "https://gitlab.example.com",
        gitLabProject: "group/project")

    private static var teamFileJSON: String {
        let data = try! JSONCoding.encoder.encode(TeamStore.TeamFile(formatVersion: 1, team: team))
        return String(decoding: data, as: UTF8.self)
    }

    @Test(
        "TEAM-02 a team file from a URL: https only, the GitLab token only to the app's own GitLab, no redirect",
        arguments: [
            // link, status, whether the token goes along, the error
            ("https://gitlab.example.com/group/setup/-/blob/main/team.json", 200, true, nil),
            ("https://files.example.org/team.json", 200, false, nil),
            ("https://gitlab.example.com.evil.example/team.json", 200, false, nil),
            ("http://gitlab.example.com/group/setup/-/raw/main/team.json", 200, false,
             TeamFileImport.FetchError.notHTTPS),
            ("https://gitlab.example.com/group/setup/-/raw/main/team.json", 302, true,
             TeamFileImport.FetchError.redirected),
            ("https://gitlab.example.com/group/setup/-/raw/main/team.json", 404, true,
             TeamFileImport.FetchError.status(404)),
        ] as [(String, Int, Bool, TeamFileImport.FetchError?)])
    func fetches(link: String, status: Int, sendsToken: Bool, error: TeamFileImport.FetchError?) async {
        let stub = StubTransport()
        stub.answer(status: status, headers: status == 302 ? ["Location": "https://other.example/x"] : [:],
                    body: Self.teamFileJSON)
        let result: Result<TeamValues, TeamFileImport.FetchError>
        do {
            result = .success(try await TeamFileImport.fetch(
                URL(string: link)!, gitLabURL: "https://gitlab.example.com", gitLabToken: "glpat-secret",
                transport: stub))
        } catch let failure {
            result = .failure(failure)
        }

        switch (result, error) {
        case (.success(let values), nil): #expect(values == Self.team)
        case (.failure(let failure), let expected?): #expect(failure == expected)
        default: Issue.record("unexpected \(result)")
        }
        for request in stub.requests {
            #expect(request.followsRedirects == false)
            #expect((request.headers["Authorization"] != nil) == sendsToken)
            #expect(!request.url.absoluteString.contains("glpat"))
            #expect(!request.url.path.contains("/-/blob/"))
        }
    }

    @Test("TEAM-02 the preview lists every change and blocks a changed server host until it is confirmed")
    func previewsHostChanges() {
        var incoming = Self.team
        incoming.gitLabURL = "https://gitlab.evil.example"
        incoming.committedLabel = "Done"

        let preview = TeamFileImport.Preview(current: Self.team, incoming: incoming)

        #expect(preview.changes.map(\.key) == [.gitLabURL, .committedLabel])
        #expect(preview.hostChanges == [.init(key: .gitLabURL, old: "gitlab.example.com", new: "gitlab.evil.example")])
        #expect(!preview.canApply(confirmedHosts: []))
        #expect(!preview.canApply(confirmedHosts: ["gitlab.example.com"]))
        #expect(preview.canApply(confirmedHosts: ["gitlab.evil.example"]))
        // A first setup sends no token anywhere yet: no host to confirm.
        #expect(TeamFileImport.Preview(current: TeamValues(), incoming: incoming).canApply(confirmedHosts: []))
        // Only a different host counts, not another path on the same one.
        var samePlace = Self.team
        samePlace.jenkinsJobURL = "https://jenkins.example.com/job/other"
        #expect(TeamFileImport.Preview(current: Self.team, incoming: samePlace).hostChanges.isEmpty)
    }

    @Test("TEAM-02 a share link carries only the https link, in the app's scheme, and reads back from either scheme")
    func shareLinks() throws {
        let file = URL(string: "https://gitlab.example.com/group/setup/-/blob/main/team.json")!
        let link = try #require(TeamFileImport.shareLink(for: file))

        #expect(link.scheme == AppIdentity.urlScheme)
        #expect(TeamFileImport.fileLink(fromShareLink: link) == file)
        let former = URL(string: link.absoluteString.replacingOccurrences(
            of: AppIdentity.urlScheme + "://", with: AppIdentity.Former.urlScheme + "://"))!
        #expect(TeamFileImport.fileLink(fromShareLink: former) == file)
        #expect(TeamFileImport.shareLink(for: URL(string: "http://gitlab.example.com/team.json")!) == nil)
        #expect(TeamFileImport.fileLink(fromShareLink: URL(string:
            "\(AppIdentity.urlScheme)://import?url=http%3A%2F%2Fgitlab.example.com%2Fteam.json")!) == nil)
    }
}

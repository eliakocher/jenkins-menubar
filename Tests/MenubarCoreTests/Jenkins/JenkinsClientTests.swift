import Foundation
import Testing

@testable import MenubarCore

/// The team values and the token every test here uses, from the made-up names of `Tests/Fixtures/Jenkins/`.
private enum Team {
    static let jobURL = "https://jenkins.example.com/jenkins/job/GitLab%20Team/job/team%252Fproduct"
    static let rootPath = "/jenkins/job/GitLab%20Team/job/team%252Fproduct"
    static let token = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    static let project = Project(
        id: .main,
        team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))

    static func client(_ stub: StubTransport, timeouts: Timeouts = .standard) throws -> JenkinsClient {
        try JenkinsClient.make(project: project, token: token, transport: stub, timeouts: timeouts).get()
    }

    static func fixture(_ name: String) throws -> String {
        try FixtureFiles.string("Jenkins/\(name)")
    }
}

@Suite("JenkinsClient")
struct JenkinsClientTests {
    @Test("NET-02 Jenkins requests use basic auth")
    func basicAuth() async throws {
        let stub = StubTransport()
        stub.answer(path: Team.rootPath + "/api/json", body: try Team.fixture("jobs.json"))
        stub.answer(path: Team.rootPath + "/job/MR-1/api/json", body: try Team.fixture("job-finished.json"))
        stub.answer(path: Team.rootPath + "/job/MR-1/2/wfapi/describe", body: try Team.fixture("describe-finished.json"))
        stub.answer(path: Team.rootPath + "/job/MR-1/2/api/json", body: try Team.fixture("test-counts.json"))
        let client = try Team.client(stub)

        _ = try await client.jobs()
        _ = try await client.job("MR-1")
        _ = try await client.stages(job: "MR-1", number: 2)
        _ = try await client.testCounts(job: "MR-1", number: 2)
        _ = try await client.account()

        #expect(stub.requests.count == 5)
        for request in stub.requests {
            #expect(request.method == "GET")
            #expect(request.headers == ["Authorization": "Basic \(Team.token)"])
            #expect(!request.url.absoluteString.contains(Team.token))
            #expect(!request.url.absoluteString.contains("secret"))
            #expect(request.url.absoluteString.hasPrefix(Team.jobURL + "/"))
        }
    }

    @Test("NET-01 timeouts per request kind")
    func timeoutsPerKind() async throws {
        let stub = StubTransport()
        stub.answer(body: "{}")
        let timeouts = Timeouts(connect: .seconds(1), jenkinsJobList: .seconds(7), jenkins: .seconds(3), gitLab: .seconds(9))
        let client = try Team.client(stub, timeouts: timeouts)

        _ = try await client.jobs()
        _ = try await client.job("MR-1")
        _ = try await client.stages(job: "MR-1", number: 2)
        _ = try await client.testCounts(job: "MR-1", number: 2)
        _ = try await client.account()
        _ = try await Team.client(stub).jobs()
        _ = try await Team.client(stub).job("MR-1")

        #expect(stub.requests.map(\.timeout) == [7, 3, 3, 3, 3, 60, 20].map { Duration.seconds($0) })
    }

    @Test("ACC-04 says who is signed in")
    func accountSaysWho() async throws {
        let stub = StubTransport()
        stub.answer(path: Team.rootPath + "/api/json", body: try Team.fixture("account.json"))

        #expect(try await Team.client(stub).account() == "jdoe")
        #expect(stub.requests.map(\.url.query) == ["tree=name"])
    }

    @Test("ACC-04 tells a rejected Jenkins token")
    func accountTellsWhatIsWrong() async throws {
        let cases: [(status: Int?, error: TransportError?, body: String, problem: Problem)] = [
            (401, nil, try Team.fixture("error-401.html"), .rejectedToken(.jenkins)),
            (403, nil, "", .rejectedToken(.jenkins)),
            (404, nil, try Team.fixture("error-404.html"), .unknownJob),
            (500, nil, try Team.fixture("error-500.html"), .httpStatus(.jenkins, status: 500)),
            (nil, .noAnswer(within: .seconds(20)), "", .unreachable(.jenkins)),
            (nil, .unknownHost, "", .unreachable(.jenkins)),
        ]
        for item in cases {
            let stub = StubTransport()
            if let error = item.error {
                stub.fail(with: error)
            } else {
                stub.answer(status: item.status ?? 200, body: item.body)
            }
            do {
                _ = try await Team.client(stub).account()
                Issue.record("expected \(item.problem)")
            } catch let error as JenkinsError {
                #expect(error.problem == item.problem)
            }
        }
    }
}

@Suite("WatchTarget")
struct WatchTargetTests {
    private static func parse(_ text: String) -> Result<String, WatchRefusal> {
        WatchTarget.parse(text, project: Team.project)
    }

    static let typedByHand =
        "https://jenkins.example.com/jenkins/job/GitLab Team/job/team%252Fproduct/job/feature%252Ffoo/3/"

    /// what the Watch a Build sheet accepts: text and the job it names
    static let accepted: [(String, String)] = {
        var cases: [(String, String)] = [
            (Team.jobURL + "/job/develop/lastBuild/", "develop"),
            ("  \(Team.jobURL)/job/feature%252Ffoo/3/ \n", "feature%252Ffoo"),
            (WatchTargetTests.typedByHand, "feature%252Ffoo"),
            ("https://gitlab.example.com/team/product/-/merge_requests/12", "MR-12"),
            (" https://gitlab.example.com/Team/Product/-/merge_requests/7 ", "MR-7"),
        ]
        for link in [
            "/job/MR-12/5/", "/job/MR-12/5", "/job/MR-12/", "/job/MR-12", "/job/MR-12/5/console", "/job/MR-12?tab=x",
            "/job/MR-12#top", "/job/MR-12/5/testReport/",
        ] {
            cases.append((Team.jobURL + link, "MR-12"))
        }
        for suffix in ["/", "/diffs", "/diffs?commit_id=abc", "#note_123", "?tab=pipelines"] {
            cases.append(("https://gitlab.example.com/team/product/-/merge_requests/12" + suffix, "MR-12"))
        }
        for text in ["!12", "MR-12", "mr-12", "12", " 12\n", "!012"] {
            cases.append((text, "MR-12"))
        }
        return cases
    }()

    @Test("WATCH-01 accepts Jenkins build, job and console links, merge request links, !N MR-N mr-N and N", arguments: WatchTargetTests.accepted)
    func accepts(text: String, job: String) {
        #expect(Self.parse(text) == .success(job), "\(text)")
    }

    @Test("WATCH-01 accepts a team job URL typed by hand with spaces")
    func acceptsTypedJobURL() {
        let typedJobURL = Project(
            id: .main,
            team: TeamValues(jenkinsJobURL: Self.typedByHand.replacingOccurrences(of: "/job/feature%252Ffoo/3/", with: "")))
        #expect(WatchTarget.parse(Team.jobURL + "/job/develop/", project: typedJobURL) == .success("develop"))
    }

    @Test("WATCH-01 labels a branch job by its decoded name")
    func labelsBranchJobs() async throws {
        let stub = StubTransport()
        stub.answer(path: Team.rootPath + "/api/json", body: try Team.fixture("jobs.json"))
        stub.answer(path: Team.rootPath + "/job/feature%252Ffoo/api/json", body: #"{"actions": [{}, {"objectDisplayName": "feature/foo"}]}"#)
        let client = try Team.client(stub)

        // The list encodes a branch once; its URLs, and so the jobs, twice.
        let jobs = try await client.jobs()
        #expect(jobs.map(\.job) == ["develop", "1234-search-filters", "release%252F8.x", "MR-1", "MR-2", "MR-3", "MR-4", "MR-5"])
        #expect(jobs.map { Build.label(forJob: $0.job) }.prefix(4) == ["develop", "1234-search-filters", "release/8.x", "!1"])

        let job = try Self.parse(Team.jobURL + "/job/feature%252Ffoo/").get()
        let candidate = try await WatchTarget.confirm(job, client: .success(client), myJobs: []).get()
        #expect(candidate == WatchCandidate(job: "feature%252Ffoo", label: "feature/foo", title: "feature/foo"))
        #expect(stub.requests.last?.url.path(percentEncoded: true) == Team.rootPath + "/job/feature%252Ffoo/api/json")
    }

    @Test("WATCH-01 prefills the sheet from a copied link")
    func prefillsFromTheClipboard() {
        let build = Team.jobURL + "/job/MR-3/4/"
        let mergeRequest = "https://gitlab.example.com/team/product/-/merge_requests/9"
        #expect(WatchTarget.suggestion(fromClipboard: "  !12 \n", watchedJobs: []) == "!12")
        #expect(WatchTarget.suggestion(fromClipboard: "MR-12", watchedJobs: []) == "MR-12")
        #expect(WatchTarget.suggestion(fromClipboard: "12", watchedJobs: []) == "12")
        #expect(WatchTarget.suggestion(fromClipboard: build, watchedJobs: ["MR-1"]) == build)
        #expect(WatchTarget.suggestion(fromClipboard: mergeRequest, watchedJobs: ["MR-9"]) == mergeRequest)
        // Not something to watch, or a job watched already.
        #expect(WatchTarget.suggestion(fromClipboard: build, watchedJobs: ["MR-3"]) == nil)
        #expect(WatchTarget.suggestion(fromClipboard: "mr-12", watchedJobs: []) == nil)
        #expect(WatchTarget.suggestion(fromClipboard: "develop", watchedJobs: []) == nil)
        #expect(WatchTarget.suggestion(fromClipboard: "https://example.com/merge_requests/1", watchedJobs: []) == nil)
        #expect(WatchTarget.suggestion(fromClipboard: "", watchedJobs: []) == nil)
    }

    /// what the sheet refuses: text and why
    static let refused: [(String, WatchRefusal)] = {
        let gitLab = "https://gitlab.example.com/team/product"
        var cases: [(String, WatchRefusal)] = [
            ("https://gitlab.example.com/team/other/-/merge_requests/12", .otherProject("team/product")),
            (gitLab + "/sub/-/merge_requests/12", .otherProject("team/product")),
        ]
        for path in ["/-/pipelines/55", "/-/merge_requests", "/-/merge_requests/new", "/-/issues/3"] {
            cases.append((gitLab + path, .notAMergeRequest))
        }
        for link in [
            "https://other.example.com/jenkins/job/MR-12/5/", Team.jobURL + "/view/all", Team.jobURL + "/job/",
            "https://gitlab.example.com/team/product", "http://jenkins.example.com/job/MR-1/",
        ] {
            cases.append((link, .otherJenkins(jobURL: Team.jobURL)))
        }
        for text in ["", "   ", "develop", "feature/foo", "Mr-12", "!", "MR-", "12a", "!12 13", "ftp://jenkins.example.com/job/MR-1/"] {
            cases.append((text, .notUnderstood))
        }
        return cases
    }()

    @Test(
        "WATCH-02 refuses another GitLab project, a GitLab link that is no merge request, another Jenkins, and text that is no link or number",
        arguments: WatchTargetTests.refused)
    func refuses(text: String, refusal: WatchRefusal) {
        #expect(Self.parse(text) == .failure(refusal), "\(text)")
    }

    @Test("WATCH-02 refuses a job Jenkins does not have")
    func refusesUnknownJobs() async throws {
        let stub = StubTransport()
        stub.answer(path: Team.rootPath + "/job/MR-9/api/json", status: 404, body: try Team.fixture("error-404.html"))
        stub.answer(path: Team.rootPath + "/job/MR-8/api/json", status: 500, body: try Team.fixture("error-500.html"))
        stub.fail(path: Team.rootPath + "/job/MR-7/api/json", with: .noConnection(within: .seconds(5)))
        let client = try Team.client(stub)

        let missing = try await WatchTarget.confirm("MR-9", client: .success(client), myJobs: [])
        #expect(missing == .failure(.noJob(job: "MR-9")))
        let failing = try await WatchTarget.confirm("MR-8", client: .success(client), myJobs: [])
        #expect(failing == .failure(.problem(.httpStatus(.jenkins, status: 500))))
        let unreachable = try await WatchTarget.confirm("MR-7", client: .success(client), myJobs: [])
        #expect(unreachable == .failure(.problem(.unreachable(.jenkins))))
    }

    @Test("WATCH-02 refuses without a Jenkins token")
    func refusesWithoutToken() async throws {
        let stub = StubTransport()
        for token in [nil, ""] {
            let client = JenkinsClient.make(project: Team.project, token: token, transport: stub)
            let refusal = try await WatchTarget.confirm("MR-12", client: client, myJobs: [])
            #expect(refusal == .failure(.problem(.noToken(.jenkins))))
        }
        let noTeam = JenkinsClient.make(project: Project(id: .main, team: TeamValues()), token: Team.token, transport: stub)
        #expect(try await WatchTarget.confirm("MR-12", client: noTeam, myJobs: []) == .failure(.problem(.teamValuesMissing)))
        #expect(stub.requests.isEmpty)
    }

    @Test("WATCH-03 does not watch my own job")
    func refusesMyOwnJob() async throws {
        let stub = StubTransport()
        stub.answer(path: Team.rootPath + "/job/MR-2/api/json", body: try Team.fixture("job-finished.json"))
        let client = try Team.client(stub)

        let mine = try await WatchTarget.confirm("MR-1", client: .success(client), myJobs: ["MR-1", "MR-3"])
        #expect(mine == .failure(.mine(job: "MR-1")))
        #expect(stub.requests.isEmpty)

        let someoneElses = try await WatchTarget.confirm("MR-2", client: .success(client), myJobs: ["MR-1", "MR-3"])
        #expect(someoneElses == .success(WatchCandidate(job: "MR-2", label: "!2", title: #"#4711: Resolve "Update the reporting API version""#)))
    }
}

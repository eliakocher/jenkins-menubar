import Foundation
import Testing

@testable import MenubarCore

@Suite("RequestRecorder")
struct RequestRecorderTests {
    private static let jenkinsToken = "amRvZTpzZWNyZXQtYXBpLXRva2Vu"
    private static let gitLabToken = "glpat-SecretToken_123"
    private static let root = URL(string: "https://jenkins.example.com/job/project/job/mrs/")!

    @Test("LOG-01 logs the requests with time and outcome")
    func logsTheRequests() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let capture = RequestCapture(folder: folder.file("requests"))
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        stub.answer(path: "/job/project/job/mrs/job/MR-1/api/json", after: .milliseconds(250), body: "{}")
        stub.answer(path: "/job/project/job/mrs/api/json", status: 500)
        stub.fail(path: "/job/project/job/mrs/job/MR-2/api/json", with: .unknownHost)
        stub.fail(path: "/job/project/job/mrs/job/MR-3/api/json", with: .noAnswer(within: .seconds(20)))
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: capture, clock: clock, pathsRelativeTo: Self.root)

        let slow = Task { try await recorder.send(Self.jenkins("job/MR-1/api/json?tree=result")) }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        #expect(try await slow.value.status == 200)
        #expect(try await recorder.send(Self.jenkins("api/json")).status == 500)
        await #expect(throws: TransportError.unknownHost) {
            try await recorder.send(Self.jenkins("job/MR-2/api/json"))
        }
        await #expect(throws: TransportError.noAnswer(within: .seconds(20))) {
            try await recorder.send(Self.jenkins("job/MR-3/api/json"))
        }

        let entries = await log.entries()
        #expect(entries.map(\.message) == [
            "GET /job/MR-1/api/json in 0.25s",
            "GET /api/json: HTTP 500 in 0.00s",
            "GET /job/MR-2/api/json: unknown host (VPN?)",
            "GET /job/MR-3/api/json: no answer within 20 seconds",
        ])
        #expect(entries.map(\.level) == [.debug, .warning, .warning, .warning])
        #expect(entries.map { $0.outcome?.description } == ["ok:200", "failed:500", "failed:OFFLINE", "failed:TIMEOUT"])
        #expect(entries.allSatisfy { $0.source == .jenkins })

        let ids = entries.compactMap(\.requestID)
        try #require(ids.count == 4)
        let first = try #require(await capture.record(id: ids[0]))
        #expect(first.url == "https://jenkins.example.com/job/project/job/mrs/job/MR-1/api/json?tree=result")
        #expect(first.seconds == 0.25 && first.status == 200 && first.body == "{}")
        let failed = try #require(await capture.record(id: ids[2]))
        #expect(failed.status == nil && failed.error == "unknown host (VPN?)")
    }

    @Test("LOG-01 logs GitLab requests by operation name")
    func logsGitLabByOperation() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let stub = StubTransport()
        stub.answer(operation: "WorkItems", body: #"{"data":{}}"#)
        stub.answer(operation: "CurrentUser", status: 401)
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, clock: TestClock())

        _ = try await recorder.send(Self.gitLab("WorkItems"))
        _ = try await recorder.send(Self.gitLab("CurrentUser"))

        let entries = await log.entries()
        #expect(entries.map(\.message) == ["POST WorkItems in 0.00s", "POST CurrentUser: HTTP 401 in 0.00s"])
        #expect(entries.map { $0.outcome?.description } == ["ok:200", "failed:401"])
        #expect(entries.allSatisfy { $0.source == .gitlab && $0.requestID == nil })
    }

    @Test("ACC-01 no token in the log or the captured requests")
    func noTokenAnywhere() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let capture = RequestCapture(folder: folder.file("requests"))
        let stub = StubTransport()
        let cookies = ["Set-Cookie": "JSESSIONID=cookie-one", "set-cookie": "_gitlab_session=cookie-two"]
        stub.answer(path: "/job/project/job/mrs/api/json", headers: cookies, body: "{}")
        stub.answer(path: "/job/project/job/mrs/job/MR-1/api/json", status: 401, headers: cookies)
        stub.answer(operation: "WorkItems", headers: cookies, body: "{}")
        stub.fail(operation: "CurrentUser", with: .noConnection(within: .seconds(5)))
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: capture, clock: TestClock(), pathsRelativeTo: Self.root)

        _ = try await recorder.send(Self.jenkins("api/json"))
        _ = try await recorder.send(Self.jenkins("job/MR-1/api/json"))
        _ = try await recorder.send(Self.gitLab("WorkItems"))
        _ = try? await recorder.send(Self.gitLab("CurrentUser"))

        let files = folder.contents()
        #expect(files.filter { $0.hasPrefix("requests/") }.count == 4)
        for file in files {
            let text = try folder.read(file)
            for secret in [Self.jenkinsToken, Self.gitLabToken, "cookie-one", "cookie-two"] {
                #expect(!text.contains(secret), "\(file) holds \(secret)")
            }
        }
    }

    @Test("LOG-01 never logs a token")
    func neverLogsAToken() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let tokens = TokenStore(keychain: InMemoryKeychain(), log: log)
        let checks = CheckTimes(folder: folder.url, log: log)
        let problems = ProblemTracker(log: log)
        let stub = StubTransport()
        stub.answer(path: "/job/project/job/mrs/api/json", status: 401)
        stub.answer(operation: "CurrentUser", status: 401)
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, pathsRelativeTo: Self.root)

        try await tokens.store(Self.jenkinsToken, for: .jenkins)
        try await tokens.store(Self.gitLabToken, for: .gitlab)
        await checks.measure(.jenkins) {
            _ = try? await recorder.send(Self.jenkins("api/json"))
            _ = try? await recorder.send(Self.gitLab("CurrentUser"))
        }
        await problems.update("jenkins", to: .rejectedToken(.jenkins), source: .jenkins)
        try await tokens.remove(.gitlab)

        let text = try folder.read("menubar-monitor.log")
        #expect(text.split(separator: "\n").count == 7)
        #expect(!text.contains(Self.jenkinsToken) && !text.contains(Self.gitLabToken))
    }

    @Test("LOG-01 does not log a request whose task was cancelled")
    func cancelledIsNotLogged() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let recorder = RequestRecorder(wrapping: CancelledTransport(), log: log, capture: RequestCapture(folder: folder.file("requests")))

        await #expect(throws: CancellationError.self) {
            try await recorder.send(Self.jenkins("api/json"))
        }
        #expect(folder.contents().isEmpty)
    }

    @Test("LOG-01 logs a request that failed for another reason with its description")
    func otherErrors() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let stub = StubTransport()
        stub.fail(path: "/job/project/job/mrs/api/json", with: .other("The certificate is not trusted"))
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, pathsRelativeTo: Self.root)

        _ = try? await recorder.send(Self.jenkins("api/json"))

        let entry = try #require(await log.entries().first)
        #expect(entry.message == "GET /api/json: The certificate is not trusted")
        #expect(entry.outcome == .failed("ERROR"))
    }

    @Test("LOG-01 logs the whole path without a job URL, and without its query")
    func wholePath() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let stub = StubTransport()
        stub.answer(body: "{}")

        _ = try await RequestRecorder(wrapping: stub, log: log, capture: nil).send(Self.jenkins("job/MR-1/api/json?tree=result"))
        // A URL elsewhere on the host isn't cut, even when it starts like the job's.
        _ = try await RequestRecorder(wrapping: stub, log: log, capture: nil, pathsRelativeTo: Self.root)
            .send(HTTPRequest(url: URL(string: "https://jenkins.example.com/job/project/job/mrs-old/api/json")!, timeout: .seconds(20)))

        #expect(await log.entries().map(\.message) == [
            "GET /job/project/job/mrs/job/MR-1/api/json in 0.00s",
            "GET /job/project/job/mrs-old/api/json in 0.00s",
        ])
    }

    // MARK: - Helpers

    private static func jenkins(_ path: String) -> HTTPRequest {
        HTTPRequest(url: URL(string: path, relativeTo: root)!.absoluteURL, headers: ["Authorization": "Basic \(jenkinsToken)"], timeout: .seconds(20))
    }

    private static func gitLab(_ operation: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            url: URL(string: "https://gitlab.example.com/api/graphql")!,
            headers: ["Authorization": "Bearer \(gitLabToken)", "Content-Type": "application/json"],
            body: Data(#"{"query":"query \#(operation) { id }","variables":{}}"#.utf8),
            timeout: .seconds(30),
            graphQL: GraphQLOperation(name: operation, variables: "{}")
        )
    }

    /// A transport whose caller's task was cancelled while it waited.
    private struct CancelledTransport: HTTPTransport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            throw CancellationError()
        }
    }
}

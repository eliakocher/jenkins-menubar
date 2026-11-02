import Foundation
import Testing

@testable import MenubarCore

/// The values of the failed tests' tests, from the made-up names of `Tests/Fixtures/Jenkins/`.
private enum Values {
    static let jobURL = "https://jenkins.example.com/job/project"
    static let root = "/job/project"
    static let reportPath = root + "/job/MR-1/7/testReport/api/json"
    static let token = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    static let project = Project(
        id: .main,
        team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "team/product"))
    static let build = BuildID(job: "MR-1", number: 7)
}

@Suite("FailedTest")
struct FailedTestTests {
    private func client(_ stub: StubTransport) throws -> JenkinsClient {
        try JenkinsClient.make(project: Values.project, token: Values.token, transport: stub).get()
    }

    @Test("PIPE-03 reads the failed tests of a test report")
    func readsFailedTests() async throws {
        let stub = StubTransport()
        stub.answer(path: Values.reportPath, body: try FixtureFiles.string("Jenkins/test-report.json"))

        let tests = try await client(stub).failedTests(job: "MR-1", number: 7)

        // In the order of the report, across its suites.
        #expect(
            tests == [
                FailedTest(
                    className: "com.example.cart.CartServiceTest", name: "removesAnItem", status: .failed,
                    message: "expected: <2> but was: <1>"),
                FailedTest(
                    className: "com.example.cart.CartServiceTest", name: "countsTheItems()", status: .regression,
                    message: "java.lang.AssertionError: Expecting size of:\n[\"Lamp\", \"Desk\"]"),
                FailedTest(className: "com.example.checkout.PaymentFormTest", name: "rejectsAnExpiredCard", status: .failed),
                FailedTest(className: "", name: "loadsTheStartPage", status: .failed, message: "Timed out after 30 seconds"),
            ])
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.url.query(percentEncoded: false) == "tree=suites[cases[className,name,status,errorDetails,age]]")
        #expect(request.headers == ["Authorization": "Basic \(Values.token)"])
    }

    @Test(
        "PIPE-03 a test counts as failed with the status FAILED or REGRESSION",
        arguments: [
            ("FAILED", true), ("REGRESSION", true), ("PASSED", false), ("SKIPPED", false), ("FIXED", false),
            ("failed", false), ("", false), (nil, false),
        ] as [(String?, Bool)])
    func statusRule(status: String?, failed: Bool) async throws {
        let field = status.map { #", "status": "\#($0)""# } ?? ""
        let stub = StubTransport()
        stub.answer(
            path: Values.reportPath,
            body: #"{"suites": [{"cases": [{"className": "a.B", "name": "c"\#(field)}]}]}"#)

        let tests = try await client(stub).failedTests(job: "MR-1", number: 7)

        #expect(tests.count == (failed ? 1 : 0), "status \(status ?? "missing")")
    }

    @Test("PIPE-03 keeps the first two lines of an error message, cut when long")
    func errorPreview() {
        #expect(FailedTest.preview(of: nil) == nil)
        #expect(FailedTest.preview(of: " \n \n") == nil)
        #expect(FailedTest.preview(of: "one\ntwo\nthree") == "one\ntwo")
        #expect(FailedTest.preview(of: "\n\n  first  \n\n  second\r\nthird") == "first\nsecond")
        let long = String(repeating: "x", count: 500)
        #expect(FailedTest.preview(of: long) == String(repeating: "x", count: 240) + "…")
    }

    @Test("PIPE-03 a build without a test report (404) has no failed tests, any other failed request is thrown", arguments: [404, 500])
    func missingOrFailedReport(status: Int) async throws {
        let stub = StubTransport()
        stub.answer(path: Values.reportPath, status: status, body: try FixtureFiles.string("Jenkins/error-\(status).html"))

        if status == 404 {
            #expect(try await client(stub).failedTests(job: "MR-1", number: 7) == [])
        } else {
            await #expect(throws: JenkinsError.self) { try await client(stub).failedTests(job: "MR-1", number: 7) }
        }
    }
}

@Suite("FailedTestsStore")
@MainActor
struct FailedTestsStoreTests {
    @MainActor
    private struct Harness {
        let folder: TemporaryFolder
        let stub = StubTransport()
        let store: FailedTestsStore

        init(token: String? = Values.token, details: DetailCache? = nil) throws {
            folder = try TemporaryFolder()
            let locations = FileLocations(root: folder.url)
            let team = TeamStore(folder: locations.applicationSupport, report: { _ in })
            try team.save(Values.project)
            let keychain = InMemoryKeychain(values: token.map { [TokenAccount.jenkins.rawValue: $0] } ?? [:])
            let services = PipelinesServices(
                transport: stub, clock: TestClock(), tokens: TokenStore(keychain: keychain), team: team,
                userStates: UserStateStore(folder: locations.applicationSupport, report: { _ in }),
                caches: CacheStore(folder: locations.caches, report: { _ in }), log: ActivityLog(folder: locations.logs),
                effects: FakeEffects(), details: details)
            store = FailedTestsStore(services: services)
        }

        func answerReport(job: String = "MR-1", number: Int = 7) throws {
            stub.answer(
                path: "\(Values.root)/job/\(job)/\(number)/testReport/api/json",
                body: try FixtureFiles.string("Jenkins/test-report.json"))
        }
    }

    @Test("PIPE-03 loads the failed tests of a build once")
    func loadsOncePerBuild() async throws {
        let harness = try Harness()
        try harness.answerReport()
        try harness.answerReport(number: 8)
        let store = harness.store

        #expect(store.state(of: Values.build) == .loading)
        await store.load(Values.build)
        await store.load(Values.build)
        guard case .loaded(let tests) = store.state(of: Values.build) else {
            Issue.record("expected the failed tests")
            return
        }
        #expect(tests.count == 4)
        #expect(harness.stub.requests.count == 1)

        // Another build asks for its own.
        await store.load(BuildID(job: "MR-1", number: 8))
        #expect(harness.stub.requests.count == 2)
        #expect(store.state(of: Values.build) == .loaded(tests))
    }

    @Test("OD-07 a finished build's failed tests are kept on disk and never asked again")
    func keptOnDisk() async throws {
        let disk = try TemporaryFolder()
        let details = DetailCache(folder: disk.file("details"))
        let first = try Harness(details: details)
        try first.answerReport()
        await first.store.load(Values.build)
        #expect(first.stub.requests.count == 1)

        // After a relaunch: shown at once, nothing asked.
        let second = try Harness(details: details)
        await second.store.load(Values.build)
        #expect(second.stub.requests.isEmpty)
        #expect(second.store.state(of: Values.build) == first.store.state(of: Values.build))
    }

    @Test("PIPE-03 a failed load shows as failed and asks again at the next selection")
    func failedLoadAsksAgain() async throws {
        let harness = try Harness()
        try harness.answerReport()
        // The newest route answers first: one failure, then the report.
        harness.stub.answer(path: Values.reportPath, times: 1, status: 500, body: "")
        let store = harness.store

        await store.load(Values.build)
        #expect(store.state(of: Values.build) == .failed)

        await store.load(Values.build)
        guard case .loaded = store.state(of: Values.build) else {
            Issue.record("expected the failed tests after the second request")
            return
        }
        #expect(harness.stub.requests.count == 2)
    }

    @Test("PIPE-03 without a Jenkins token nothing is asked and the load fails quietly")
    func noToken() async throws {
        let harness = try Harness(token: nil)

        await harness.store.load(Values.build)

        #expect(harness.store.state(of: Values.build) == .failed)
        #expect(harness.stub.requests.isEmpty)
    }
}

import Foundation
import Testing

@testable import MenubarCore

/// "Rebuild with Changes…" (PIPE-09): the job's parameter definitions, the form filled from a build's values, and the
/// request body of the edited form. Made-up values; no server.
@Suite("Rebuild form")
struct RebuildFormTests {
    private static let jobURL = "https://jenkins.example.com/job/project"
    private static let apiToken = "made-up-api-token-0123456789"
    private static let token = TokenStore.jenkinsToken(user: "jenkins-jdoe", apiToken: apiToken)

    private static func client(_ stub: StubTransport) throws -> JenkinsClient {
        let project = Project(
            id: .main,
            team: TeamValues(jenkinsJobURL: jobURL, gitLabURL: "https://gitlab.example.com", gitLabProject: "group/project"))
        return try JenkinsClient.make(project: project, token: token, transport: stub).get()
    }

    private static func definitionsStub(_ body: String) -> StubTransport {
        let stub = StubTransport()
        stub.answer(path: "/job/project/job/MR-1/api/json", body: body)
        return stub
    }

    // MARK: Decoding

    /// What the answer looks like: with the exported `type`, or with `_class` alone.
    enum Shape: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case withType
        case classOnly

        var testDescription: String { rawValue }
    }

    @Test("PIPE-09 the job's parameter definitions are read by type", arguments: Shape.allCases)
    func decodesDefinitions(_ shape: Shape) async throws {
        var body = try FixtureFiles.string("Jenkins/job-parameter-definitions-typed.json")
        if shape == .classOnly {
            body = body.split(separator: "\n").filter { !$0.contains("\"type\":") }.joined(separator: "\n")
        }
        let client = try Self.client(Self.definitionsStub(body))

        let definitions = try await client.parameterDefinitions(job: "MR-1")

        #expect(definitions.map(\.name) == [
            "TARGET_BRANCH", "SKIP_UI_TESTS", "ENVIRONMENT", "NOTES", "DEPLOY_PASSWORD", "UPSTREAM", "PLUGIN_TREE",
        ])
        #expect(definitions.map(\.kind) == [.string, .boolean, .choice, .text, .password, .unsupported, .unsupported])
        #expect(definitions[0].defaultValue == "main")
        #expect(definitions[0].details == "The branch to build")
        // A JSON `true` is read as the form's `true`; an empty description is none.
        #expect(definitions[1].defaultValue == "true")
        #expect(definitions[1].details == nil)
        #expect(definitions[2].choices == ["staging", "qa", "production"])
        #expect(definitions[3].defaultValue == "line one\nline two")
        #expect(definitions[4].defaultValue == nil)
    }

    @Test("PIPE-09 a job without parameters has no definitions, and a lenient answer doesn't throw")
    func decodesNothing() async throws {
        for body in [
            try FixtureFiles.string("Jenkins/job-without-parameter-definitions.json"), "{}",
            #"{"property":[null,{"parameterDefinitions":[null,{"name":7,"choices":"a"},{"name":"A","type":"StringParameterDefinition"}]}]}"#,
        ] {
            let definitions = try await Self.client(Self.definitionsStub(body)).parameterDefinitions(job: "MR-1")
            #expect(definitions.map(\.name).filter { $0 != "A" }.isEmpty)
        }
    }

    // MARK: The form

    private static let definitions = [
        ParameterDefinition(name: "BRANCH", kind: .string, defaultValue: "main"),
        ParameterDefinition(name: "SKIP", kind: .boolean, defaultValue: "true"),
        ParameterDefinition(name: "ENV", kind: .choice, choices: ["staging", "qa"], defaultValue: "staging"),
        ParameterDefinition(name: "PICK", kind: .choice, choices: ["a", "b"]),
        ParameterDefinition(name: "SECRET", kind: .password),
        ParameterDefinition(name: "RUN", kind: .unsupported),
    ]

    @Test("PIPE-09 the form shows the build's values, then the job's defaults")
    func fillsTheForm() {
        let build = [
            BuildParameter(name: "BRANCH", value: "release/8.x"), BuildParameter(name: "SKIP", value: "false"),
            BuildParameter(name: "ENV", value: "retired-env"), BuildParameter(name: "GONE", value: "x"),
        ]

        let form = RebuildForm(definitions: Self.definitions, original: build)

        #expect(form.isParameterized)
        #expect(form.fields.map(\.id) == ["BRANCH", "SKIP", "ENV", "PICK", "SECRET"])
        #expect(form.skipped == ["RUN"])
        #expect(form.fields.map(\.value) == ["release/8.x", "false", "retired-env", "a", ""])
        // A choice the job no longer offers stays one, so that Rebuild can send it unchanged.
        #expect(form.fields[2].definition.choices == ["staging", "qa", "retired-env"])
        // The job's defaults when the build has no value.
        let fresh = RebuildForm(definitions: Self.definitions, original: [])
        #expect(fresh.fields.map(\.value) == ["main", "true", "staging", "a", ""])
    }

    // MARK: The request

    @Test("PIPE-09 the edited values make the form body; a password is sent only when typed")
    func sendsTheEditedValues() async throws {
        var form = RebuildForm(
            definitions: Self.definitions, original: [BuildParameter(name: "BRANCH", value: "release/8.x")])
        form.fields[0].value = "feature/a & b"
        form.fields[1].isOn = false
        form.fields[3].value = "b"
        for typed in ["", "p@ss word&=1"] {
            form.fields[4].value = typed
            let stub = StubTransport()
            stub.answer(
                "POST", path: "/job/project/job/MR-1/buildWithParameters", status: 201,
                headers: ["Location": "https://jenkins.example.com/queue/item/42/"])

            let item = try await Self.client(stub).rebuild(job: "MR-1", form: form)

            #expect(item == QueueItem(id: 42))
            let post = try #require(stub.requests.first)
            let body = String(decoding: try #require(post.body), as: UTF8.self)
            var expected = "BRANCH=feature%2Fa%20%26%20b&SKIP=false&ENV=staging&PICK=b"
            if !typed.isEmpty {
                expected += "&SECRET=p%40ss%20word%26%3D1"
            }
            #expect(body == expected)
            #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded")
            // The token travels in its header only.
            #expect(!post.url.absoluteString.contains(Self.apiToken))
            #expect(!body.contains(Self.apiToken))
        }
    }

    @Test("PIPE-09 a job without parameters is built with build, without a body")
    func sendsNoBodyWithoutParameters() async throws {
        let form = RebuildForm(definitions: [], original: [])
        let stub = StubTransport()
        stub.answer(
            "POST", path: "/job/project/job/MR-1/build", status: 201,
            headers: ["Location": "https://jenkins.example.com/queue/item/7/"])

        _ = try await Self.client(stub).rebuild(job: "MR-1", form: form)

        #expect(!form.isParameterized)
        #expect(stub.requests.first?.body == nil)
    }

    @Test("PIPE-09 the form loads the definitions and the build's values together")
    func loadsTheForm() async throws {
        let stub = StubTransport()
        stub.answer(
            path: "/job/project/job/MR-1/7/api/json", body: try FixtureFiles.string("Jenkins/build-parameters.json"))
        stub.answer(
            path: "/job/project/job/MR-1/api/json",
            body: try FixtureFiles.string("Jenkins/job-parameter-definitions-typed.json"))

        let form = try await Self.client(stub).rebuildForm(job: "MR-1", number: 7)

        // TARGET_BRANCH and SKIP_UI_TESTS are the build's; NOTES and ENVIRONMENT are the job's defaults.
        #expect(form.fields.first { $0.id == "TARGET_BRANCH" }?.value == "release/8.x")
        #expect(form.fields.first { $0.id == "SKIP_UI_TESTS" }?.value == "false")
        #expect(form.fields.first { $0.id == "ENVIRONMENT" }?.value == "staging")
        #expect(form.skipped == ["UPSTREAM", "PLUGIN_TREE"])
    }
}

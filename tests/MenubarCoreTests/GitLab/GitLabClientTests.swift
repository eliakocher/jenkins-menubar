import Foundation
import Testing

@testable import MenubarCore

/// `GitLabClient` and its operations against the stub transport and the fixtures in `Tests/Fixtures/GitLab/`.
@Suite("GitLab client")
struct GitLabClientTests {
    private static let token = "glpat-secret-token"
    private let stub = StubTransport()

    private var client: GitLabClient {
        GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: Self.token)
    }

    private static func fixture(_ name: String) throws -> String {
        try FixtureFiles.string("GitLab/\(name)")
    }

    /// Sends an operation and returns the problem it failed with.
    private func problem<Value>(of operation: GitLabOperation<Value>) async throws -> Problem? {
        do {
            _ = try await client.send(operation)
            return nil
        } catch let error as GitLabError {
            return error.problem
        }
    }

    @Test("NET-02 GitLab requests use bearer auth and JSON")
    func bearerAndJSON() async throws {
        stub.answer(operation: "CurrentUser", body: try Self.fixture("current-user.json"))

        #expect(try await client.send(.currentUser) == "alex.doe")

        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gitlab.example.com/api/graphql")
        #expect(request.headers["Authorization"] == "Bearer \(Self.token)")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == Timeouts.standard.gitLab)
        #expect(request.graphQL == GraphQLOperation(name: "CurrentUser", variables: "{}"))
        let data = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["query", "variables"])
        #expect(body["query"] as? String == "query CurrentUser { currentUser { username } }")
        #expect((body["variables"] as? [String: Any])?.isEmpty == true)
    }

    @Test("NET-02 no token in a URL")
    func noTokenInURL() async throws {
        let item = WorkItem(reference: "acme/main/server/server#15706", title: "Item",
                            webURL: URL(string: "https://gitlab.example.com/acme/main/server/server/-/work_items/15706")!, updatedAt: .now)
        let variables = WorkItemQuery.variables(preferences: Preferences(), project: Project(id: .main, team: TeamValues()), me: "alex.doe")
        for (operation, file) in [("CurrentUser", "current-user"), ("MergedMergeRequests", "merged-merge-requests"),
                                  ("MergeRequests", "merge-requests"), ("WorkItems", "work-items"), ("Labels", "labels"),
                                  ("RelatedMergeRequests", "related-merge-requests"), ("Metadata", "metadata")] {
            stub.answer(operation: operation, body: try Self.fixture("\(file).json"))
        }

        // Every operation decodes its real or hand-written answer.
        #expect(try await client.send(.currentUser) == "alex.doe")
        #expect(try await client.send(.mergedMergeRequests(project: "acme/main/server/server", iids: [12436, 12346, 12000])) == [12346, 12436])
        #expect(try await client.send(.mergeRequests).mergeRequests.map(\.iid) == [12437])
        #expect(try await client.send(.workItems(variables)).all.count == 22)
        #expect(try await client.send(.labels(project: "acme/main/server/server", searchTerm: "uStatus::InVerification"))
            == [Label(title: "uStatus::InVerification", color: "#808080")])
        #expect(try await client.send(try #require(GitLabOperation.relatedMergeRequests(of: item))).map(\.iid) == [12346, 12436, 12301])
        #expect(try await client.send(.metadata) == "19.3.6-ee")

        #expect(stub.requests.count == 7)
        for request in stub.requests {
            #expect(request.url.absoluteString == "https://gitlab.example.com/api/graphql")
            #expect(!String(decoding: request.body ?? Data(), as: UTF8.self).contains(Self.token))
            #expect(request.headers.filter { $0.value.contains(Self.token) }.keys.sorted() == ["Authorization"])
        }
        #expect(stub.requests(operation: "MergedMergeRequests").first?.graphQL?.variables
            == #"{"path":"acme/main/server/server","iids":["12436","12346","12000"]}"#)
        #expect(stub.requests(operation: "RelatedMergeRequests").first?.graphQL?.variables
            == #"{"path":"acme/main/server/server","iid":"15706"}"#)
    }

    @Test("MR-05 reports a rejected token")
    func rejectedToken() async throws {
        // The real answer to an unknown token.
        stub.answer(operation: "CurrentUser", times: 1, status: 401, body: try Self.fixture("invalid-token.json"))
        stub.answer(operation: "MergeRequests", times: 1, status: 403, body: #"{"message": "403 Forbidden"}"#)
        #expect(try await problem(of: .currentUser) == .rejectedToken(.gitLab))
        #expect(try await problem(of: .mergeRequests) == .rejectedToken(.gitLab))

        // The real answer without a token: a 200 without currentUser.
        stub.answer(operation: "CurrentUser", body: try Self.fixture("current-user-null.json"))
        stub.answer(operation: "MergeRequests", body: try Self.fixture("current-user-null.json"))
        #expect(try await problem(of: .currentUser) == .rejectedToken(.gitLab))
        #expect(try await problem(of: .mergeRequests) == .rejectedToken(.gitLab))
        stub.answer(operation: "Metadata", body: try Self.fixture("metadata-null.json"))
        #expect(try await problem(of: .metadata) == .rejectedToken(.gitLab))
        #expect(Problem.rejectedToken(.gitLab).message == "GitLab rejected the token (expired, or without the api scope?)")

        // Not JSON at all, like a sign-in page in front of GitLab.
        stub.answer(operation: "MergeRequests", body: "<html>Sign in</html>")
        #expect(try await problem(of: .mergeRequests) == .rejectedToken(.gitLab))
    }

    @Test("MR-05 reports a token without the api scope")
    func missingScope() async throws {
        stub.answer(operation: "MergeRequests", times: 1, status: 403, body: try Self.fixture("insufficient-scope.json"))
        stub.answer(operation: "MergeRequests", times: 1, status: 401,
                    headers: ["WWW-Authenticate": #"Bearer realm="", error="insufficient_scope", scope="read_api""#])
        #expect(try await problem(of: .mergeRequests) == .missingScope)
        #expect(try await problem(of: .mergeRequests) == .missingScope)
        #expect(Problem.missingScope.message == "GitLab rejected the token: it needs the api scope")

        // GitLab's GraphQL endpoint answers a token without read_api as an unknown one: the copy names the scope.
        stub.answer(operation: "MergeRequests", status: 401, body: try Self.fixture("invalid-token.json"))
        #expect(try await problem(of: .mergeRequests) == .rejectedToken(.gitLab))
    }

    @Test("MR-05 reports GitLab unreachable and other HTTP statuses")
    func unreachable() async throws {
        stub.fail(operation: "MergeRequests", times: 1, with: .noConnection(within: .seconds(5)))
        stub.fail(operation: "CurrentUser", times: 1, with: .unknownHost)
        #expect(try await problem(of: .mergeRequests) == .unreachable(.gitLab))
        #expect(try await problem(of: .currentUser) == .unreachable(.gitLab))
        #expect(Problem.unreachable(.gitLab).message == "GitLab unreachable")

        stub.answer(operation: "MergeRequests", times: 1, status: 502, body: #"{"errors": [{"message": "Bad gateway"}]}"#)
        #expect(try await problem(of: .mergeRequests) == .httpStatus(.gitLab, status: 502))
        #expect(Problem.httpStatus(.gitLab, status: 502).message == "GitLab answered with HTTP 502")

        // An answer without data but with errors, for an operation other than the work items.
        stub.answer(operation: "Labels", body: #"{"errors": [{"message": "Field 'labels' doesn't exist"}]}"#)
        #expect(try await problem(of: .labels(project: "a/b", searchTerm: "x")) == .graphQLErrors(messages: ["Field 'labels' doesn't exist"]))

        // A cancelled load is no problem: the error goes through as it is.
        let clock = TestClock()
        let slow = StubTransport(clock: clock)
        slow.answer(operation: "CurrentUser", after: .seconds(10), body: try Self.fixture("current-user.json"))
        let client = GitLabClient(transport: slow, gitLab: URL(string: "https://gitlab.example.com")!, token: Self.token)
        let load = Task { try await client.send(.currentUser) }
        await clock.waitForSleepers()
        load.cancel()
        await #expect(throws: CancellationError.self) { try await load.value }
    }

    @Test("MR-05 reports a GraphQL error of the work items")
    func workItemsErrors() async throws {
        let variables = WorkItemQuery.variables(preferences: Preferences(), project: Project(id: .main, team: TeamValues()), me: "alex.doe")

        // The real answer to an unknown sort.
        stub.answer(operation: "WorkItems", times: 1, body: try Self.fixture("work-items-invalid-sort.json"))
        let sortProblem = try await self.problem(of: .workItems(variables))
        #expect(sortProblem == .graphQLErrors(messages: ["Variable $sort of type IssueSort was provided invalid value"]))
        #expect(sortProblem?.message == "Variable $sort of type IssueSort was provided invalid value")

        // Errors next to data still fail: a list could be missing.
        stub.answer(operation: "WorkItems", times: 1, body: #"{"data": {"committed": null}, "errors": [{"message": "Timeout"}, {"message": "other"}]}"#)
        #expect(try await self.problem(of: .workItems(variables)) == .graphQLErrors(messages: ["Timeout", "other"]))

        stub.answer(operation: "WorkItems", times: 1, status: 500)
        #expect(try await self.problem(of: .workItems(variables)) == .workItemsFailed(status: 500))
        #expect(Problem.workItemsFailed(status: 500).message == "Work items request failed (HTTP 500)")
        #expect(Problem.workItemsFailed(status: 500).server == .gitLab)
        #expect(!Problem.workItemsFailed(status: 500).marksStatusIcon)

        stub.answer(operation: "WorkItems", times: 1, status: 500, body: #"{"errors": [{"message": "Internal server error"}]}"#)
        #expect(try await self.problem(of: .workItems(variables)) == .graphQLErrors(messages: ["Internal server error"]))

        stub.answer(operation: "WorkItems", times: 1, body: #"{"data": null}"#)
        #expect(try await self.problem(of: .workItems(variables)) == .workItemsFailed(status: 200))

        // The new case round-trips like the others.
        let data = try JSONEncoder().encode(Problem.workItemsFailed(status: 503))
        #expect(try JSONDecoder().decode(Problem.self, from: data) == .workItemsFailed(status: 503))
    }
}

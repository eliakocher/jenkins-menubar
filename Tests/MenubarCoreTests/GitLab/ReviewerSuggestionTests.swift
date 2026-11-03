import Foundation
import Testing

@testable import MenubarCore

/// Suggesting reviewers for my merge request: GitLab's rules, `CODEOWNERS`, the squad, and adding them (MR-15).
@Suite("Reviewer suggestions")
@MainActor
struct ReviewerSuggestionTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private nonisolated static let source = DescriptionSource(
        kind: .mergeRequest, reference: "group/project!16", webURL: gitLab.appending(path: "group/project/-/merge_requests/16"),
        updatedAt: updatedAt)

    private nonisolated static var mergeRequest: MergeRequest {
        MergeRequest(
            iid: 16, title: "Add a retry", webURL: source.webURL, reference: source.reference,
            author: .init(username: "jdoe", name: "Jane Doe"), updatedAt: updatedAt, roles: [.authored])
    }

    private typealias Facts = ReviewerSuggestionFacts

    private static func person(_ username: String, active: Bool = true) -> Facts.Person {
        .init(username: username, name: username.uppercased(), isActive: active)
    }

    private static func codeOwnerRule(
        _ pattern: String, section: String? = nil, required: Int = 1, approvedBy: [String] = [], eligible: [String]
    ) -> Facts.Rule {
        .init(name: pattern, type: .codeOwner, section: section, approvalsRequired: required, approvedBy: approvedBy,
              eligible: eligible.map { person($0) })
    }

    private static func regularRule(_ name: String, required: Int = 1, eligible: [String]) -> Facts.Rule {
        .init(name: name, type: .regular, approvalsRequired: required, eligible: eligible.map { person($0) })
    }

    private static func facts(_ rules: [Facts.Rule] = [], reviewers: [String] = [], paths: [String] = []) -> Facts {
        .init(author: "jdoe", reviewers: reviewers, targetBranch: "main", changedPaths: paths, rules: rules)
    }

    private static let squads = SlotTeams("Alpha: jdoe, slee, tgreen, akim; Bravo: cnovak, pwu")

    // MARK: - Reading GitLab's answers

    @Test("MR-15 reads the evaluated rules with their type, section and eligible approvers, and the changed paths")
    func readsFacts() async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerSuggestionFacts", body: try FixtureFiles.string("GitLab/reviewer-suggestion-facts.json"))
        let operation = try #require(GitLabOperation.reviewerSuggestionFacts(of: Self.source))

        let facts = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t").send(operation)

        #expect(facts.author == "jdoe" && facts.reviewers == ["akim"] && facts.approvedBy == ["rmeyer"])
        #expect(facts.targetBranch == "main" && facts.changedPaths == ["core/src/Main.java", "docs/index.md"])
        #expect(facts.rules.map(\.type) == [.codeOwner, .regular, .anyApprover])
        #expect(facts.rules[0].section == "core" && facts.rules[0].eligible.map(\.username) == ["slee", "cnovak", "project_12_bot_abc"])
        #expect(facts.rules[0].eligible[1].isActive == false)
        #expect(facts.rules[1].approvedBy == ["rmeyer"] && facts.rules[1].approvalsRequired == 2)
    }

    @Test("MR-15 the ranking over GitLab's rules: the open ones first, then the squad; the author, reviewers, approvers, bots and blocked users are left out")
    func rankingOverFixture() async throws {
        let stub = StubTransport()
        stub.answer(operation: "ReviewerSuggestionFacts", body: try FixtureFiles.string("GitLab/reviewer-suggestion-facts.json"))
        stub.answer(operation: "ReviewerSuggestionUsers", body: try FixtureFiles.string("GitLab/reviewer-suggestion-users.json"))
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t")
        let facts = try await client.send(try #require(GitLabOperation.reviewerSuggestionFacts(of: Self.source)))
        let people = try await client.send(GitLabOperation.users(named: ["slee", "bkhan", "tgreen"]))
        let squads = SlotTeams("Alpha: jdoe, slee, tgreen, akim, bkhan, rmeyer")

        let list = ReviewerSuggester.suggest(facts: facts, people: people, peopleAreComplete: true, squads: squads)

        #expect(list.items.map(\.username) == ["slee", "pwu", "tgreen"])
        #expect(list.items.map(\.kind) == [.required, .required, .squad])
        #expect(list.items[0].reason == "Required code owner: `*.java` in core")
        #expect(list.items[0].otherReasons == ["Squad: Alpha"])
        // The Security rule needs 2 and rmeyer approved: one is left, and the only eligible person is pwu.
        #expect(list.items[1].reason == "Required by rule Security")
        #expect(list.items[2].reason == "Squad: Alpha")
        #expect(list.items.map(\.name) == ["Sam Lee", "Pat Wu", "Tess Green"])
    }

    // MARK: - The rules

    @Test("MR-15 a person who several sources name shows once, with the strongest reason and the others listed")
    func dedup() {
        let facts = Self.facts(
            [Self.codeOwnerRule("*.java", section: "core", eligible: ["slee"]), Self.regularRule("Backend Review", eligible: ["slee", "pwu"])],
            paths: ["A.java"])
        let owners = CodeOwnersFile(parsing: "*.java @slee\n")

        let list = ReviewerSuggester.suggest(facts: facts, codeOwners: owners, squads: Self.squads)

        let sam = list.items.filter { $0.username == "slee" }
        #expect(sam.count == 1)
        // CODEOWNERS isn't read when GitLab evaluated a code owner rule, so it isn't a reason here.
        #expect(sam[0].reason == "Required code owner: `*.java` in core")
        #expect(sam[0].otherReasons == ["Required by rule Backend Review (1 of 2 needed)", "Squad: Alpha"])
        #expect(sam[0].coveredRules.count == 2)
        // Covering two rules ranks before covering one.
        #expect(list.items.map(\.username).first == "slee")
    }

    @Test("MR-15 CODEOWNERS of the target branch counts only when GitLab's rules hold no code owner rule")
    func codeOwnersFallback() {
        let owners = CodeOwnersFile(parsing: "[core] @slee\n*.java\n/docs/ @tgreen\n")
        let paths = ["core/A.java", "core/B.java", "docs/x.md"]

        let without = ReviewerSuggester.suggest(facts: Self.facts(paths: paths), codeOwners: owners)
        #expect(without.items.map(\.username) == ["slee", "tgreen"])
        #expect(without.items.map(\.kind) == [.codeOwner, .codeOwner])
        // The one who owns more of the changed files ranks first.
        #expect(without.items[0].reason == "Code owner: `*.java` in core")

        let enforced = ReviewerSuggester.suggest(
            facts: Self.facts([Self.codeOwnerRule("*.java", eligible: ["pwu"])], paths: paths), codeOwners: owners)
        #expect(enforced.items.map(\.username) == ["pwu"])
    }

    @Test("MR-15 an optional or a group owner: optional is named, groups aren't expanded, roles and emails are skipped")
    func ownerKinds() {
        let owners = CodeOwnersFile(parsing: "^[Docs] @tgreen @group/docs @@maintainer jdoe@example.com\n/docs/\n")

        let list = ReviewerSuggester.suggest(facts: Self.facts(paths: ["docs/a.md"]), codeOwners: owners)

        #expect(list.items.map(\.username) == ["tgreen"])
        #expect(list.items[0].reason == "Optional code owner: `/docs/` in Docs")
    }

    @Test("MR-15 a rule the current reviewers can satisfy, a satisfied rule and an any-approver rule suggest nobody")
    func coveredRules() {
        let covered = Self.regularRule("Backend Review", eligible: ["akim", "pwu"])
        let done = Facts.Rule(name: "Docs Review", type: .regular, approvalsRequired: 1, isApproved: true, eligible: [Self.person("tgreen")])
        let anyone = Facts.Rule(name: "All Members", type: .anyApprover, approvalsRequired: 1, eligible: [Self.person("slee")])

        let list = ReviewerSuggester.suggest(facts: Self.facts([covered, done, anyone], reviewers: ["akim"]))
        #expect(list.items.isEmpty)

        // Needing two, one reviewer isn't enough.
        let two = Self.regularRule("Backend Review", required: 2, eligible: ["akim", "pwu"])
        #expect(ReviewerSuggester.suggest(facts: Self.facts([two], reviewers: ["akim"])).items.map(\.username) == ["pwu"])
    }

    @Test("MR-15 a rule of a big group suggests five of them, the squad's first, then the least loaded")
    func limitPerRule() {
        let group = ["u1", "u2", "u3", "u4", "u5", "u6", "u7", "tgreen"]
        let facts = Self.facts([Self.regularRule("Maintainers", eligible: group)])

        let list = ReviewerSuggester.suggest(
            facts: facts, squads: SlotTeams("Alpha: jdoe, tgreen"), load: ["u1": 5, "u3": 1])

        // tgreen is in the squad; then by load (an unknown load counts 0), then by name.
        #expect(list.items.map(\.username) == ["tgreen", "u2", "u4", "u5", "u6"])
        #expect(list.items.count == ReviewerSuggester.limitPerRule)
    }

    // MARK: - The exclusions

    @Test("MR-15 left out: the author, the current reviewers, those who approved, bots and inactive users", arguments: [
        "jdoe", "akim", "rmeyer", "project_7_bot_token", "group_4_bot_deploy", "ghost", "release-bot", "ci_bot", "dependabot[bot]", "bkhan",
    ])
    func exclusions(username: String) {
        var facts = Self.facts(reviewers: ["akim"], paths: ["a.txt"])
        facts.approvedBy = ["rmeyer"]
        let owners = CodeOwnersFile(parsing: "* @\(username) @slee\n")
        let people = [Self.person("bkhan", active: false), Self.person("slee")]

        let list = ReviewerSuggester.suggest(facts: facts, codeOwners: owners, people: people, peopleAreComplete: true)

        #expect(list.items.map(\.username) == ["slee"])
    }

    @Test("MR-15 a name GitLab doesn't know is dropped only when the users were asked")
    func unknownUsers() {
        let owners = CodeOwnersFile(parsing: "* @slee @typo\n")
        let facts = Self.facts(paths: ["a.txt"])

        #expect(ReviewerSuggester.suggest(facts: facts, codeOwners: owners, people: [Self.person("slee")], peopleAreComplete: true)
            .items.map(\.username) == ["slee"])
        #expect(ReviewerSuggester.suggest(facts: facts, codeOwners: owners).items.map(\.username) == ["slee", "typo"])
    }

    @Test("MR-15 the squad is the author's teams only, and the open reviews break a tie")
    func squadAndLoad() {
        let list = ReviewerSuggester.suggest(facts: Self.facts(), squads: Self.squads, load: ["slee": 4, "tgreen": 1])

        // Bravo isn't the author's team; akim has no open reviews, then tgreen, then slee.
        #expect(list.items.map(\.username) == ["akim", "tgreen", "slee"])
        #expect(list.items.allSatisfy { $0.kind == .squad })
        let noSquad = ReviewerSuggester.suggest(facts: Self.facts(), squads: SlotTeams("Bravo: cnovak, pwu"))
        #expect(noSquad.items.isEmpty)
    }

    // MARK: - Adding the required

    @Test("MR-15 the required reviewers to add are the fewest who satisfy the open rules")
    func minimalRequired() {
        let rules = [
            Self.regularRule("Backend Review", eligible: ["slee", "pwu", "tgreen"]),
            Self.regularRule("Security", eligible: ["pwu", "cnovak"]),
            Self.regularRule("Docs Review", required: 2, eligible: ["tgreen", "akim", "slee"]),
        ]

        let list = ReviewerSuggester.suggest(facts: Self.facts(rules))

        // Everyone is in 1 or 2 rules; the picks cover all three with the fewest people.
        let picks = list.minimalRequired
        var remaining = ["/Backend Review": 1, "/Security": 1, "/Docs Review": 2]
        for pick in picks {
            for key in pick.coveredRules { remaining[key, default: 0] -= 1 }
        }
        #expect(remaining.values.allSatisfy { $0 <= 0 })
        #expect(picks.count == 3)
        #expect(picks.count < list.items.count)
    }

    // MARK: - The write

    @Test("MR-15 the mutation appends the usernames to the merge request's reviewers, and the token is only in the header")
    func addMutation() async throws {
        let stub = StubTransport()
        stub.answer(
            operation: "MergeRequestAddReviewers",
            body: #"{"data":{"mergeRequestSetReviewers":{"errors":[],"mergeRequest":{"reviewers":{"nodes":[{"username":"akim"},{"username":"slee"}]}}}}}"#)

        let reviewers = try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "glpat-test").addReviewers(["slee"], to: Self.source)

        #expect(reviewers == ["akim", "slee"])
        let request = try #require(stub.requests(operation: "MergeRequestAddReviewers").first)
        #expect(request.method == "POST" && request.url.absoluteString == "https://gitlab.example.com/api/graphql")
        #expect(request.headers["Authorization"] == "Bearer glpat-test")
        let data = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["query"] as? String)?.contains("mergeRequestSetReviewers(input: $input)") == true)
        let input = try #require((body["variables"] as? [String: Any])?["input"] as? [String: Any])
        #expect(input["projectPath"] as? String == "group/project" && input["iid"] as? String == "16")
        #expect(input["reviewerUsernames"] as? [String] == ["slee"] && input["operationMode"] as? String == "APPEND")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("glpat-test") == false)
    }

    @Test("MR-15 an answer with errors is a failure with GitLab's words; nobody to add sends nothing")
    func addErrors() async throws {
        let stub = StubTransport()
        stub.answer(operation: "MergeRequestAddReviewers", body: #"{"data":{"mergeRequestSetReviewers":{"errors":["Too many reviewers"],"mergeRequest":null}}}"#)
        let client = GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t")

        await #expect(throws: GitLabError(.graphQLErrors(messages: ["Too many reviewers"]))) {
            try await client.addReviewers(["slee"], to: Self.source)
        }
        #expect(GitLabOperation<[String]>.addReviewers(of: Self.source, usernames: []) == nil)
    }

    // MARK: - The store

    private static func store(_ stub: StubTransport, folder: TemporaryFolder, token: String? = "glpat-test") throws -> ReviewerSuggestionStore {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project", slotTeams: "Alpha: jdoe, tgreen")))
        let values = token.map { [TokenAccount.gitlab.rawValue: $0] } ?? [:]
        return ReviewerSuggestionStore(services: GitLabServices(
            transport: stub, clock: ContinuousClock(), tokens: TokenStore(keychain: InMemoryKeychain(values: values)), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: ActivityLog(folder: folder.file("logs"))))
    }

    private static let basicFacts = """
        {"data":{"project":{"mergeRequest":{"targetBranch":"release/1.0","author":{"username":"jdoe"},
         "reviewers":{"nodes":[]},"approvedBy":{"nodes":[]},"diffStats":[{"path":"core/A.java"}],"approvalState":{"rules":[]}}}}}
        """

    @Test("MR-15 the store asks the rules, the branch's commit, CODEOWNERS and the users; CODEOWNERS is kept per commit")
    func storeFlow() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        stub.answer(operation: "ReviewerSuggestionFacts", body: Self.basicFacts)
        // The branch name's slash and the project's path are encoded in the URL.
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/repository/branches/release%2F1.0", body: #"{"commit":{"id":"abc123"}}"#)
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/repository/files/CODEOWNERS/raw", status: 404)
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/repository/files/docs%2FCODEOWNERS/raw", body: "*.java @slee\n")
        stub.answer(operation: "ReviewerSuggestionUsers", body: try FixtureFiles.string("GitLab/reviewer-suggestion-users.json"))
        let store = try Self.store(stub, folder: folder)

        await store.load(Self.mergeRequest)

        guard case .loaded(let list) = store.state(of: Self.mergeRequest) else {
            Issue.record("expected suggestions, got \(String(describing: store.state(of: Self.mergeRequest)))")
            return
        }
        #expect(list.items.map(\.username) == ["slee", "tgreen"])
        #expect(list.items.map(\.reason) == ["Code owner: `*.java`", "Squad: Alpha"])
        let ref = stub.requests.first { $0.url.path(percentEncoded: true).hasSuffix("/raw") }
        #expect(ref?.url.query == "ref=abc123")

        // Loading again for the same commit reads no file again.
        await store.load(Self.mergeRequest, force: true)
        #expect(stub.requests(operation: "CodeOwnersFile").count == 2)  // CODEOWNERS 404 and docs/CODEOWNERS, once
        #expect(stub.requests(operation: "TargetBranchHead").count == 2)
        #expect(stub.requests(operation: "ReviewerSuggestionFacts").count == 2)
    }

    @Test("MR-15 a failed read of CODEOWNERS leaves the squad and says so; without a token nothing is asked")
    func storeFailures() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        stub.answer(operation: "ReviewerSuggestionFacts", body: Self.basicFacts)
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/repository/branches/release%2F1.0", status: 500)
        stub.answer(operation: "ReviewerSuggestionUsers", body: try FixtureFiles.string("GitLab/reviewer-suggestion-users.json"))
        let store = try Self.store(stub, folder: folder)

        await store.load(Self.mergeRequest)

        guard case .loaded(let list) = store.state(of: Self.mergeRequest) else {
            Issue.record("expected suggestions")
            return
        }
        #expect(list.items.map(\.username) == ["tgreen"])
        #expect(list.notes.count == 1 && list.notes[0].hasPrefix("CODEOWNERS couldn't be read"))

        let quiet = StubTransport()
        let other = try TemporaryFolder()
        let withoutToken = try Self.store(quiet, folder: other, token: nil)
        await withoutToken.load(Self.mergeRequest)
        #expect(quiet.requests.isEmpty)
        #expect(withoutToken.state(of: Self.mergeRequest) == .failed(Problem.noToken(.gitLab).message))
    }

    @Test("MR-15 adding reviewers through the store loads the suggestions again, and a missing scope asks for a token")
    func storeAdd() async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        stub.answer(operation: "ReviewerSuggestionFacts", body: Self.basicFacts)
        stub.answer(operation: "ReviewerSuggestionUsers", body: try FixtureFiles.string("GitLab/reviewer-suggestion-users.json"))
        stub.answer("GET", path: "/api/v4/projects/group%2Fproject/repository/branches/release%2F1.0", status: 404)
        stub.answer(
            operation: "MergeRequestAddReviewers",
            body: #"{"data":{"mergeRequestSetReviewers":{"errors":[],"mergeRequest":{"reviewers":{"nodes":[{"username":"tgreen"}]}}}}}"#)
        let store = try Self.store(stub, folder: folder)

        let outcome = await store.add(["tgreen"], to: Self.mergeRequest)

        #expect(outcome.succeeded && outcome.reviewers == ["tgreen"])
        #expect(stub.requests(operation: "ReviewerSuggestionFacts").count == 1)

        stub.answer(operation: "MergeRequestAddReviewers", status: 403, body: #"{"error":"insufficient_scope"}"#)
        let refused = await store.add(["pwu"], to: Self.mergeRequest)
        #expect(!refused.succeeded && refused.needsToken)
    }
}

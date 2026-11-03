import Foundation
import Testing

@testable import MenubarCore

/// The project's members and the @-mention matching (CMT-07).
@Suite("Mentions")
struct ProjectMembersTests {
    private static let members = [
        ProjectMember(username: "jdoe", name: "Jane Doe"),
        ProjectMember(username: "slee", name: "Sam Lee"),
        ProjectMember(username: "dlopez", name: "Jane-Marie D\u{00F3}pez"),
        ProjectMember(username: "janitor", name: "Joe Clean"),
        ProjectMember(username: "bkhan", name: "Bilal Khan", isActive: false),
        ProjectMember(username: "project_12_bot_ab12", name: "Token"),
        ProjectMember(username: "release-bot", name: "Release"),
        ProjectMember(username: "ghost", name: "Ghost"),
    ]

    struct Case: Sendable, CustomTestStringConvertible {
        var typed: String
        var expected: [String]
        var testDescription: String { "@" + typed }
    }

    @Test(
        "CMT-07 matches by the start of the username, then of the name, then of a word of the name; case and accents don't count; inactive users and bots are left out",
        arguments: [
            Case(typed: "ja", expected: ["janitor", "dlopez", "jdoe"]),
            Case(typed: "JANE", expected: ["dlopez", "jdoe"]),
            Case(typed: "lee", expected: ["slee"]),
            Case(typed: "dop", expected: ["dlopez"]),
            Case(typed: "doe", expected: ["jdoe"]),
            Case(typed: "bk", expected: []),
            Case(typed: "ghost", expected: []),
            Case(typed: "rel", expected: []),
            Case(typed: "zzz", expected: []),
            Case(typed: "", expected: ["dlopez", "janitor", "jdoe", "slee"]),
        ])
    func matching(_ example: Case) {
        #expect(MentionMatcher.matches(example.typed, in: Self.members).map(\.username) == example.expected)
    }

    @Test("CMT-07 the limit cuts the list")
    func limit() {
        #expect(MentionMatcher.matches("", in: Self.members, limit: 2).map(\.username) == ["dlopez", "janitor"])
    }

    @Test(
        "CMT-07 a mention is being typed after an @ at the start or behind a space, not in an address",
        arguments: [
            ("@ja", 3, "ja"), ("Thanks @sl", 10, "sl"), ("Thanks @", 8, ""), ("(@jd", 4, "jd"), ("a\n@x", 4, "x"),
        ])
    func trigger(text: String, cursor: Int, query: String) {
        let index = text.index(text.startIndex, offsetBy: cursor)
        let found = MentionMatcher.trigger(in: text, cursor: index)

        #expect(found?.query == query)
        #expect(found.map { String(text[$0.range]) } == "@" + query)
    }

    @Test("CMT-07 no mention in an email address, a word, or behind a space after the name", arguments: [("jane@example.com", 16), ("no at sign", 10), ("@jane doe", 9), ("a@@b", 4)])
    func noTrigger(text: String, cursor: Int) {
        #expect(MentionMatcher.trigger(in: text, cursor: text.index(text.startIndex, offsetBy: cursor)) == nil)
    }

    @Test("CMT-07 choosing a member finishes the mention with a space and puts the cursor behind it")
    func complete() throws {
        let text = "Thanks @sl for the review"
        let trigger = try #require(MentionMatcher.trigger(in: text, cursor: text.index(text.startIndex, offsetBy: 10)))

        let result = MentionMatcher.complete(Self.members[1], replacing: trigger, in: text)

        #expect(result.text == "Thanks @slee  for the review")
        #expect(result.cursor == 13)
    }

    @Test("CMT-07 the members are read page by page, a member without a user is skipped, the token stays in the header")
    func readsPages() async throws {
        let stub = StubTransport()
        let first = try FixtureFiles.string("GitLab/project-members-page1.json")
        let second = try FixtureFiles.string("GitLab/project-members-page2.json")
        stub.add(
            .init(matches: { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("cursor-1") }) { _ in
                .success(HTTPResponse(status: 200, headers: [:], body: Data(second.utf8)))
            })
        stub.answer(operation: "ProjectMembers", times: 1, body: first)

        let members = try await GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: "glpat-x")
            .projectMembers(of: "group/project")

        #expect(members.map(\.username) == ["jdoe", "slee", "bkhan", "akim"])
        #expect(members.map(\.isActive) == [true, true, false, true])
        #expect(stub.requests.count == 2)
        #expect(stub.requests.allSatisfy { $0.headers["Authorization"] == "Bearer glpat-x" && !$0.url.absoluteString.contains("glpat") })
    }
}

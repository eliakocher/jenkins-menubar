import Foundation
import MenubarCore
import Testing

@testable import MenubarUI

/// The Reviewers card's suggested chips and what an add sends (MR-15).
@Suite("Suggested reviewers")
@MainActor
struct SuggestedReviewersTests {
    private typealias Facts = ReviewerSuggestionFacts

    private static func person(_ username: String, _ name: String) -> Facts.Person { .init(username: username, name: name) }

    /// two open rules (a code owner rule and a regular one) and a squad: Taylor and Morgan own the files, Lee and Dana
    /// are Backend Review, Avery is in the squad; Sam reviews already
    private static var list: ReviewerSuggestionList {
        let people = [
            person("tgreen", "Taylor Green"), person("mchen", "Morgan Chen"), person("lwu", "Lee Wu"),
            person("dbrown", "Dana Brown"), person("asingh", "")
        ]
        let facts = Facts(
            author: "jdoe", reviewers: ["slee"],
            rules: [
                .init(
                    name: "*.swift", type: .codeOwner, section: "Core", approvalsRequired: 1,
                    eligible: [person("tgreen", "Taylor Green"), person("mchen", "Morgan Chen")]),
                .init(
                    name: "Backend Review", type: .regular, approvalsRequired: 1,
                    eligible: [person("lwu", "Lee Wu"), person("dbrown", "Dana Brown")]),
            ])
        return ReviewerSuggester.suggest(
            facts: facts, people: people, peopleAreComplete: true, squads: SlotTeams("Alpha: jdoe, dbrown, asingh"))
    }

    @Test("MR-15 the chips: the required first, with the reason and the other reasons in the tooltip; the reviewers are left out")
    func chips() throws {
        let model = SuggestedReviewersModel(Self.list, current: ["slee"])

        #expect(model.chips.prefix(4).allSatisfy { $0.isRequired })
        let dana = try #require(model.chips.first { $0.username == "dbrown" })
        #expect(dana.name == "Dana Brown" && dana.isRequired)
        #expect(dana.help.hasPrefix("Add Dana Brown as a reviewer\nRequired by rule Backend Review"))
        #expect(dana.help.contains("\nAlso: Squad: Alpha"))
        // GitLab sent no name: "@username", and the avatar takes the initials of the username.
        let avery = try #require(model.chips.first { $0.username == "asingh" })
        #expect(avery.name == "@asingh" && avery.fullName.isEmpty && !avery.isRequired)

        // Whoever is a reviewer by now, also just added and in any case, leaves the chips.
        let later = SuggestedReviewersModel(Self.list, current: ["slee", "TGreen", "dbrown"])
        #expect(later.chips.map(\.username).contains("tgreen") == false)
        #expect(later.chips.map(\.username).contains("dbrown") == false)
    }

    @Test("MR-15 Add Required Reviewers names the fewest people, drops those added, and asks once for more than one")
    func addRequired() {
        let model = SuggestedReviewersModel(Self.list, current: [])
        #expect(model.required.count == 2)
        #expect(model.addRequiredTitle == "Add Required Reviewers (2)")
        #expect(model.requiredQuestion.hasPrefix("Add ") && model.requiredQuestion.hasSuffix(" as reviewers?"))

        // One of the two rules is met by the one just added: one person is left to add.
        let first = model.required[0].username
        let rest = SuggestedReviewersModel(Self.list, current: [first])
        #expect(rest.required.count == 1 && rest.addRequiredTitle == "Add Required Reviewer")

        let none = SuggestedReviewersModel(Self.list, current: Set(model.required.map(\.username)))
        #expect(none.required.isEmpty && none.addRequiredTitle == nil)
        #expect(!none.chips.isEmpty, "optional suggestions stay")
    }

    @Test("MR-15 more than eight chips fold behind Show More; the notes of the list come along")
    func folding() {
        let items = (1...12).map { ReviewerSuggestion(username: "u\($0)", name: "User \($0)", kind: .squad, reason: "Squad: Alpha") }
        let model = SuggestedReviewersModel(ReviewerSuggestionList(items: items, notes: ["CODEOWNERS couldn't be read"]), current: [])
        #expect(model.shown(showsAll: false).count == 8 && model.shown(showsAll: true).count == 12)
        #expect(model.notes == ["CODEOWNERS couldn't be read"])
        #expect(model.addRequiredTitle == nil)
    }

    @Test("MR-15 what a click on chips sends: an append of exactly their usernames, in one request")
    func addRequest() async throws {
        let people = SuggestedReviewersModel(Self.list, current: []).required
        let stub = StubTransport()
        stub.answer(
            operation: "MergeRequestAddReviewers",
            body: #"{"data":{"mergeRequestSetReviewers":{"errors":[],"mergeRequest":{"reviewers":{"nodes":[{"username":"slee"}]}}}}}"#)
        let url = try #require(URL(string: "https://gitlab.example.com/group/project/-/merge_requests/16"))
        let source = DescriptionSource(kind: .mergeRequest, reference: "group/project!16", webURL: url, updatedAt: .now)

        _ = try await GitLabClient(transport: stub, gitLab: #require(URL(string: "https://gitlab.example.com")), token: "glpat-test")
            .addReviewers(people.map(\.username), to: source)

        #expect(stub.requests.count == 1)
        let body = try #require(stub.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require((json["variables"] as? [String: Any])?["input"] as? [String: Any])
        #expect(input["reviewerUsernames"] as? [String] == people.map(\.username))
        #expect(input["operationMode"] as? String == "APPEND" && input["iid"] as? String == "16")
    }

    @Test("MR-15 the sentence after an add")
    func addedText() {
        let two = SuggestedReviewersModel(Self.list, current: []).required
        #expect(SuggestedReviewersModel.addedText([two[0]]).hasSuffix("added as a reviewer"))
        #expect(SuggestedReviewersModel.addedText(two).hasSuffix("added as reviewers"))
    }
}

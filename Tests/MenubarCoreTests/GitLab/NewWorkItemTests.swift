import Foundation
import Testing

@testable import MenubarCore

/// The links to GitLab's new issue page and the prefilled texts of the entry points (NEW-01, NEW-02, NEW-04).
@Suite("New work item")
struct NewWorkItemTests {
    private static let team = TeamValues(
        gitLabURL: "https://gitlab.example.com", gitLabProject: "group/subgroup/project", typeLabelPrefix: "type::")

    /// The query items of a link, decoded.
    private static func query(_ url: URL?) throws -> [String: String] {
        let components = try #require(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static let mergeRequest = MergeRequest(
        iid: 12, title: "Add the cart", webURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/merge_requests/12")!,
        reference: "group/subgroup/project!12", author: .init(username: "jdoe", name: "Jo Doe"),
        updatedAt: Date(timeIntervalSince1970: 1_792_800_000), roles: [.authored])

    @Test("NEW-01 a blank work item opens the new issue page with the type's template")
    func blankUsesTheTemplate() throws {
        let urls = try WorkItemKind.allCases.map { kind in
            try #require(NewWorkItem.link(for: NewWorkItemDraft(kind: kind), team: Self.team))
        }
        #expect(urls[0].absoluteString.hasPrefix("https://gitlab.example.com/group/subgroup/project/-/issues/new?"))
        let templates = try urls.map { try Self.query($0) }
        #expect(templates.map { $0["issuable_template"] } == ["Bug", "Task", "New feature", "Improvement"])
        #expect(templates.map { $0["description_template"] } == ["Bug", "Task", "New feature", "Improvement"])
        // A description would replace the template, so a blank link has none.
        #expect(templates.allSatisfy { $0["issue[description]"] == nil && $0["issue[title]"] == nil })

        // A link without the GitLab URL or the project is none.
        #expect(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug), team: TeamValues()) == nil)
        #expect(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug), team: TeamValues(gitLabURL: "https://gitlab.example.com")) == nil)
    }

    @Test("NEW-01 the text is percent-encoded, with + and & kept")
    func encodesTheText() throws {
        let draft = NewWorkItemDraft(kind: .task, title: "C++ & \"quotes\" é [x]", body: "a+b=c&d\nline 2")
        let url = try #require(NewWorkItem.link(for: draft, team: Self.team))
        let text = url.absoluteString
        #expect(text.contains("issue%5Btitle%5D=C%2B%2B%20%26%20%22quotes%22%20%C3%A9%20%5Bx%5D"))
        #expect(!text.dropFirst(10).contains("+"))
        let query = try Self.query(url)
        #expect(query["issue[title]"] == "C++ & \"quotes\" é [x]")
        #expect(query["issue[description]"]?.hasPrefix("a+b=c&d\nline 2\n\n") == true)
    }

    @Test("NEW-02 the description ends with the quick actions: assign to me and the type label")
    func quickActionsEndTheDescription() throws {
        for kind in WorkItemKind.allCases {
            let url = NewWorkItem.link(for: NewWorkItemDraft(kind: kind, title: "T", body: "Body"), team: Self.team)
            let description = try #require(Self.query(url)["issue[description]"])
            #expect(description == "Body\n\n/assign me\n/label ~\"type::\(kind.labelValue)\"")
        }
        #expect(WorkItemKind.newFeature.labelValue == "NewFeature")
        // No team prefix: no label line.
        #expect(NewWorkItem.quickActions(kind: .bug, typeLabelPrefix: " ") == ["/assign me"])
    }

    @Test("NEW-02 a link is cut at a line end to the length cap and keeps the quick actions")
    func capsTheLength() throws {
        let body = (1...400).map { "- Line \($0) of a long log excerpt é\u{00E9}" }.joined(separator: "\n")
        let url = try #require(NewWorkItem.link(for: NewWorkItemDraft(kind: .bug, title: String(repeating: "T", count: 500), body: body), team: Self.team))
        #expect(url.absoluteString.count <= NewWorkItem.linkLimit)
        let query = try Self.query(url)
        #expect(query["issue[title]"]?.count == NewWorkItem.titleLimit)
        let description = try #require(query["issue[description]"])
        #expect(description.hasSuffix("\(NewWorkItem.cutNote)\n\n/assign me\n/label ~\"type::Bug\""))
        #expect(description.contains("- Line 1 of"))
        #expect(!description.contains("- Line 400 of"))
        // A short body isn't cut.
        let short = NewWorkItem.link(for: NewWorkItemDraft(kind: .bug, title: "T", body: "short"), team: Self.team)
        #expect(try Self.query(short)["issue[description]"]?.contains(NewWorkItem.cutNote) == false)
    }

    @Test("NEW-04 a follow-up is a task that carries the link; of a work item it is related to it, of an epic only linked")
    func followUps() throws {
        // A follow-up of a merge request: /relate takes issues only, so the link is the connection.
        let mergeRequestDraft = NewWorkItemSource.followUp(Self.mergeRequest).draft
        #expect(mergeRequestDraft.kind == .task)
        #expect(mergeRequestDraft.body.contains("group/subgroup/project!12 (https://gitlab.example.com/group/subgroup/project/-/merge_requests/12)"))
        let mergeRequestLink = NewWorkItem.link(for: mergeRequestDraft, team: Self.team)
        let mergeRequestDescription = try #require(Self.query(mergeRequestLink)["issue[description]"])
        #expect(!mergeRequestDescription.contains("/relate"))
        #expect(mergeRequestDescription.hasSuffix("/assign me\n/label ~\"type::Task\""))
        #expect(NewWorkItemSource.blank(.improvement).draft.isBlank)

        // A follow-up of a work item.
        let item = WorkItem(
            reference: "group/subgroup/project#31", title: "[ABC-31] Rework the color tokens",
            webURL: URL(string: "https://gitlab.example.com/group/subgroup/project/-/issues/31")!, updatedAt: Date())
        let draft = NewWorkItemSource.followUpOfWorkItem(item).draft
        #expect(draft.kind == .task)
        #expect(draft.title == "Follow-up: Rework the color tokens")
        let url = NewWorkItem.link(for: draft, team: Self.team)
        let description = try #require(Self.query(url)["issue[description]"])
        #expect(description.contains("group/subgroup/project#31 (https://gitlab.example.com/group/subgroup/project/-/issues/31)"))
        #expect(description.hasSuffix("/relate group/subgroup/project#31\n\n/assign me\n/label ~\"type::Task\""))
        var epic = item
        epic.reference = "group/subgroup&12"
        #expect(!NewWorkItem.followUp(of: epic).body.contains("/relate"))
    }
}

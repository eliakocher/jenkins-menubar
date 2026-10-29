import Foundation
import Testing

@testable import MenubarCore

/// The remembered labels, their colors, the label search and the gone filter labels (WI-06).
@Suite("Labels")
struct LabelTests {
    private static let project = "acme/main/server/server"
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let clock = TestClock()
    private let stub = StubTransport()

    private var search: LabelSearch {
        LabelSearch(client: GitLabClient(transport: stub, gitLab: URL(string: "https://gitlab.example.com")!, token: "t"),
                    project: Self.project, clock: clock)
    }

    private static func item(labels: [Label]) -> WorkItem {
        WorkItem(reference: "\(project)#1", title: "Item", webURL: URL(string: "https://gitlab.example.com/\(project)/-/work_items/1")!,
                 labels: labels, updatedAt: now)
    }

    /// Runs a search through its pause on the test clock.
    private func searchLabels(_ text: String, memory: LabelMemory, filters: WorkItemFilters = WorkItemFilters(),
                              in search: LabelSearch? = nil) async throws -> LabelSearchResult {
        let search = search ?? self.search
        let task = Task { try await search.searchLabels(text, memory: memory, filters: filters) }
        if !text.isEmpty {
            await clock.waitForSleepers()
            clock.advance(by: LabelSearch.pause)
        }
        return try await task.value
    }

    /// Answers the Labels query for one search term.
    private func answerLabels(for term: String, with labels: [Label]) {
        let nodes = labels.map { #"{"title": "\#($0.title)", "color": \#($0.color.map { "\"\($0)\"" } ?? "null")}"# }.joined(separator: ",")
        let body = #"{"data": {"project": {"labels": {"nodes": [\#(nodes)]}}}}"#
        stub.add(StubTransport.Route(matches: { request in
            request.graphQL?.name == "Labels" && request.graphQL?.variables.contains(#""term":"\#(term)""#) == true
        }) { _ in .success(HTTPResponse(status: 200, body: Data(body.utf8))) })
    }

    @Test("WI-06 drops labels no work item had for 30 days")
    func dropsOldLabels() {
        var memory = LabelMemory(lastSeen: [
            "old::label": Self.now.addingTimeInterval(-31 * 86400),
            "edge::label": Self.now.addingTimeInterval(-30 * 86400),
            "recent::label": Self.now.addingTimeInterval(-86400),
        ])
        memory.remember([Self.item(labels: [Label(title: "type::bug", color: "#dc143c")])], filters: WorkItemFilters(), at: Self.now)
        #expect(memory.known == ["recent::label", "type::bug"])
        #expect(memory.lastSeen["type::bug"] == Self.now)
        #expect(LabelMemory.keptFor == 30 * 86400)
    }

    @Test("WI-06 remembers labels only without must-have labels")
    func remembersOnlyUnfiltered() {
        var memory = LabelMemory()
        memory.remember([Self.item(labels: [Label(title: "co::label", color: "#9400d3")])],
                        filters: WorkItemFilters(withLabels: ["must::have"]), at: Self.now)
        #expect(memory.known.isEmpty)
        // The colors are kept anyway.
        #expect(memory.colors == ["co::label": "#9400d3"])
    }

    @Test("WI-06 searches GitLab and my work items case-insensitively")
    func searchesCaseInsensitively() async throws {
        // The old tool's test: GitLab also finds Answered by its description.
        answerLabels(for: "STATUS", with: [Label(title: "uStatus::Todo", color: "#9400d3"), Label(title: "Answered", color: "#808080")])
        let memory = LabelMemory(lastSeen: ["uStatus::Seen": Self.now, "bug": Self.now])

        let result = try await searchLabels("STATUS", memory: memory)
        #expect(result.labels == ["uStatus::Seen", "uStatus::Todo"])
        #expect(result.colors == ["uStatus::Todo": "#9400d3"])
        #expect(result.problem == nil)
        #expect(result.found.count == 2)
        #expect(stub.requests(operation: "Labels").first?.graphQL?.variables == #"{"path":"acme/main/server/server","term":"STATUS"}"#)

        // The filter labels are offered too, and empty text gives the known labels without asking GitLab.
        let all = try await searchLabels("", memory: memory, filters: WorkItemFilters(withoutLabels: ["workflow::done"]))
        #expect(all.labels == ["bug", "uStatus::Seen", "workflow::done"])
        #expect(stub.requests.count == 1)

        // The picker groups them by scope, then the others.
        #expect(Label.groupedByScope(["uStatus::Todo", "bug", "area::web", "uStatus::Seen"])
            == [Label.Group(scope: "area", labels: ["area::web"]), Label.Group(scope: "uStatus", labels: ["uStatus::Todo", "uStatus::Seen"]),
                Label.Group(scope: nil, labels: ["bug"])])
        #expect(Label.Group(scope: nil, labels: []).title == "Other Labels")
    }

    @Test("WI-06 leaves out labels found only by description")
    func leavesOutDescriptionMatches() async throws {
        stub.answer(operation: "Labels", body: try FixtureFiles.string("GitLab/labels-search.json"))
        let result = try await searchLabels("bug", memory: LabelMemory())
        #expect(result.labels == ["bugfix::backport", "uIssueType::Bug"])
        #expect(result.colors == ["bugfix::backport": "#F0F0F0", "uIssueType::Bug": "#ed9121"])
    }

    @Test("WI-06 searches only my labels without a token")
    func noToken() async throws {
        let withoutToken = LabelSearch(client: nil, project: Self.project, clock: clock)
        let memory = LabelMemory(lastSeen: ["uStatus::Seen": Self.now], colors: ["uStatus::Seen": "#808080"])
        let result = try await searchLabels("seen", memory: memory, in: withoutToken)
        #expect(result.labels == ["uStatus::Seen"])
        #expect(result.colors == ["uStatus::Seen": "#808080"])
        #expect(result.problem == "No GitLab token: only the labels of your work items")
        #expect(try await searchLabels("", memory: memory, in: withoutToken).problem == nil)
        #expect(stub.requests.isEmpty)
    }

    @Test("WI-06 searches only my labels when GitLab does not answer")
    func noAnswer() async throws {
        stub.fail(operation: "Labels", with: .noConnection(within: .seconds(5)))
        let result = try await searchLabels("seen", memory: LabelMemory(lastSeen: ["uStatus::Seen": Self.now]))
        #expect(result.labels == ["uStatus::Seen"])
        #expect(result.problem == "GitLab did not answer: only the labels of your work items")

        // A newer search cancels this one during its pause, before it asks GitLab.
        let older = Task { [search] in try await search.searchLabels("old", memory: LabelMemory(), filters: WorkItemFilters()) }
        await clock.waitForSleepers()
        older.cancel()
        await #expect(throws: CancellationError.self) { try await older.value }
        #expect(stub.requests.count == 1)
    }

    @Test("WI-06 flags a filter label GitLab no longer has")
    func flagsGoneLabel() async throws {
        answerLabels(for: "uStatus::Done", with: [Label(title: "uStatus::Done", color: "#428bca"), Label(title: "uStatus::DoneSoon")])
        answerLabels(for: "uStatus::Gone", with: [Label(title: "uStatus::GoneToo", color: "#808080")])
        var filters = WorkItemFilters()
        for label in ["uStatus::Done", "uStatus::Gone", "type::bug"] {
            filters.setLabel(label, in: .without)
        }
        let items = [Self.item(labels: [Label(title: "type::bug")])]

        let check = try await search.checkFilterLabels(filters: filters, workItems: items, memory: LabelMemory())
        #expect(check.memory.missing == ["uStatus::Gone"])
        #expect(check.newlyMissing == ["uStatus::Gone"])
        #expect(check.memory.missingFilterLabels(of: filters) == ["uStatus::Gone"])
        #expect(check.memory.colors == ["uStatus::Done": "#428bca", "uStatus::GoneToo": "#808080"])
        // A label a loaded work item has isn't asked.
        #expect(stub.requests(operation: "Labels").count == 2)
        #expect(LabelMemory.missingMessage(label: "uStatus::Gone") == "The filter label uStatus::Gone is not in GitLab any more (renamed or removed?)")

        // Logged once: the next check flags it again, but not as new.
        let again = try await search.checkFilterLabels(filters: filters, workItems: items, memory: check.memory)
        #expect(again.memory.missing == ["uStatus::Gone"])
        #expect(again.newlyMissing.isEmpty)
    }

    @Test("WI-06 unflags a label taken out of the filters")
    func unflags() async throws {
        let memory = LabelMemory(missing: ["uStatus::Gone"])
        var filters = WorkItemFilters(withoutLabels: ["uStatus::Gone"])
        #expect(memory.missingFilterLabels(of: filters) == ["uStatus::Gone"])
        filters.setLabel("uStatus::Gone", in: nil)
        #expect(memory.missingFilterLabels(of: filters).isEmpty)

        let check = try await search.checkFilterLabels(filters: filters, workItems: [], memory: memory)
        #expect(check.memory.missing.isEmpty)
        #expect(stub.requests.isEmpty)
    }

    @Test("WI-06 does not flag when GitLab does not answer")
    func noFlagWithoutAnswer() async throws {
        stub.fail(operation: "Labels", with: .unknownHost)
        let filters = WorkItemFilters(withLabels: ["uStatus::Flagged"], withoutLabels: ["uStatus::New"])

        let check = try await search.checkFilterLabels(filters: filters, workItems: [], memory: LabelMemory(missing: ["uStatus::Flagged"]))
        #expect(check.memory.missing == ["uStatus::Flagged"])
        #expect(check.newlyMissing.isEmpty)

        // Without a token nothing is asked, and nothing new is flagged either.
        let withoutToken = LabelSearch(client: nil, project: Self.project, clock: clock)
        #expect(try await withoutToken.checkFilterLabels(filters: filters, workItems: [], memory: LabelMemory()).memory.missing.isEmpty)
    }

    @Test("WI-06 label text color by luminance")
    func textColor() {
        #expect(Label.textColor(onBackground: "#FFFFFF") == "#000000")
        #expect(Label.textColor(onBackground: "#F0F0F0") == "#000000")
        #expect(Label.textColor(onBackground: "#ed9121") == "#000000")
        #expect(Label.textColor(onBackground: "#808080") == "#FFFFFF")
        #expect(Label.textColor(onBackground: "#9400d3") == "#FFFFFF")
        #expect(Label.textColor(onBackground: "#000000") == "#FFFFFF")
        #expect(Label.textColor(onBackground: "#FFF") == nil)
        #expect(Label.textColor(onBackground: "red") == nil)
        #expect(Label.scopeAndValue(of: "uStatus::Sub::Deep")! == ("uStatus::Sub", "Deep"))
        #expect(Label.scopeAndValue(of: "bug") == nil)
    }
}

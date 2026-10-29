import Foundation
import Testing

@testable import MenubarCore

/// The work item query, its sections, the label rules, the slot, the related-MR markers and the links (WI-01 to WI-05,
/// WI-07, MR-04).
@Suite("Work items")
struct WorkItemTests {
    private static let projectPath = "acme/main/server/server"
    private static let committed = "cLevelOfCommitment::Committed"
    private static let gitLab = URL(string: "https://gitlab.example.com")!

    private static func project(committedLabel: String = committed) -> Project {
        Project(id: .main, team: TeamValues(gitLabURL: gitLab.absoluteString, gitLabProject: projectPath, committedLabel: committedLabel))
    }

    private static func variables(_ filters: WorkItemFilters, committedLabel: String = committed) -> WorkItemQuery.Variables {
        WorkItemQuery.variables(preferences: Preferences(workItems: filters), project: project(committedLabel: committedLabel), me: "alex.doe")
    }

    private static func item(_ reference: String = "\(projectPath)#1", title: String = "Item", labels: [String] = []) -> WorkItem {
        WorkItem(reference: reference, title: title, webURL: gitLab.appending(path: "\(projectPath)/-/work_items/1"),
                 labels: labels.map { Label(title: $0) }, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func list(_ count: Int, of shown: Int) -> WorkItemList {
        WorkItemList(count: count, items: (0..<shown).map { item("\(projectPath)#\($0 + 1)") })
    }

    /// The real answer of `work-items.json`, decoded by the client.
    private static func realWorkItems() async throws -> WorkItemLists {
        let stub = StubTransport()
        stub.answer(operation: "WorkItems", body: try FixtureFiles.string("GitLab/work-items.json"))
        return try await GitLabClient(transport: stub, gitLab: gitLab, token: "t").send(.workItems(variables(WorkItemFilters())))
    }

    // MARK: - WI-01

    @Test("WI-01 committed and not committed sections with counts")
    func committedSections() async throws {
        let lists = try await Self.realWorkItems()
        let sections = WorkItemSections(lists, committedLabel: Self.committed)
        #expect(sections.sections.map(\.title) == ["Committed (2)", "Not Committed (20 of 29)"])
        #expect(sections.sections.map(\.kind) == [.committed, .notCommitted])
        #expect(sections.header == "Work Items · 2 committed")
        let first = try #require(lists.committed?.items.first)
        #expect(first.reference == "\(Self.projectPath)#19017")
        #expect(first.labels.first == Label(title: "cDueSlot::2026.51", color: "#9400d3"))
        #expect(first.updatedAt == (try Date.ISO8601FormatStyle().parse("2026-10-26T08:39:25Z")))
        // The old query asked no type and state: they read as an open issue.
        #expect(first.type == .issue && first.state == .opened)
    }

    @Test("WI-01 single list without a committed label")
    func singleList() {
        let variables = Self.variables(WorkItemFilters(), committedLabel: "")
        #expect(!variables.withCommitted && variables.withOthers)
        #expect(variables.otherNot == nil)

        let sections = WorkItemSections(WorkItemLists(others: Self.list(3, of: 3)), committedLabel: "")
        #expect(sections.sections.map(\.title) == ["Work Items (3)"])
        #expect(sections.header == "Work Items (3)")
        // Without committed ones, the header counts the other list.
        let none = WorkItemSections(WorkItemLists(committed: Self.list(0, of: 0), others: Self.list(29, of: 20)), committedLabel: Self.committed)
        #expect(none.header == "Work Items (20 of 29)")
        #expect(none.sections.map(\.title) == ["Not Committed (20 of 29)"])
    }

    @Test("WI-01 limit never cuts committed items")
    func limitKeepsCommitted() {
        var filters = WorkItemFilters()
        filters.limit = 10
        #expect(Self.variables(filters).first == 10)
        let query = GitLabOperation.workItems(Self.variables(filters)).query
        #expect(query.contains("sort: $sort, first: 50) @include(if: $withCommitted)"))
        #expect(query.contains("sort: $sort, first: $first) @include(if: $withOthers)"))

        let sections = WorkItemSections(WorkItemLists(committed: Self.list(30, of: 30), others: Self.list(40, of: 10)),
                                        committedLabel: Self.committed)
        #expect(sections.sections.map(\.title) == ["Committed (30)", "Not Committed (10 of 40)"])
    }

    @Test("WI-01 count shows N of M")
    func countText() {
        #expect(WorkItemSections.Section(kind: .notCommitted, list: Self.list(29, of: 20)).countText == "20 of 29")
        #expect(WorkItemSections.Section(kind: .notCommitted, list: Self.list(3, of: 3)).countText == "3")
    }

    @Test("WI-01 committed label as must-not-have drops its section")
    func committedAsMustNotHave() {
        var filters = WorkItemFilters()
        filters.setLabel(Self.committed, in: .without)
        #expect(!Self.variables(filters).withCommitted)
        #expect(Self.variables(filters).withOthers)
        let sections = WorkItemSections(WorkItemLists(others: Self.list(2, of: 2)), committedLabel: Self.committed)
        #expect(sections.sections.map(\.kind) == [.notCommitted])

        // The other list is left out when the committed label is a must-have label in "all" mode, not in "any".
        filters.setLabel(Self.committed, in: .with)
        #expect(Self.variables(filters).withCommitted && !Self.variables(filters).withOthers)
        filters.setLabel("bug", in: .with)
        filters.setLabelsMatch(.any)
        #expect(Self.variables(filters).withOthers)
    }

    @Test("WI-01 says when no work item matches")
    func noneMatch() {
        let sections = WorkItemSections(WorkItemLists(committed: Self.list(0, of: 0), others: Self.list(0, of: 0)), committedLabel: Self.committed)
        #expect(sections.isEmpty)
        #expect(sections.header == "Work Items (0)")
        #expect(WorkItemSections.emptyText == "No work items match the filter")
    }

    // MARK: - WI-02

    @Test("WI-02 query variables for scope type state sort and limit")
    func queryVariables() throws {
        // The variables the old tool sent with work-items.json.
        var filters = WorkItemFilters()
        filters.setLabel("uStatus::InVerification", in: .without)
        let variables = Self.variables(filters)
        let expected = try JSONSerialization.jsonObject(with: try FixtureFiles.data("GitLab/work-items-variables.json")) as? NSDictionary
        let sent = try JSONSerialization.jsonObject(with: Data(variables.graphQLValue.json.utf8)) as? NSDictionary
        #expect(sent == expected)
        #expect(GitLabOperation.workItems(variables).variables == variables.graphQLValue.json)
        #expect(variables.graphQLValue.json.hasPrefix(#"{"assignee":["alex.doe"],"author":null,"types":null,"state":"opened","sort":"UPDATED_DESC","#))

        let other = Self.variables(WorkItemFilters(scope: .authored, type: .task, state: .all, sort: .title, limit: 50))
        #expect(other.assignee == nil && other.author == "alex.doe")
        #expect(other.types == ["TASK"] && other.state == "all" && other.sort == "TITLE_ASC" && other.first == 50)
        #expect(Self.variables(WorkItemFilters(type: .incident, state: .closed, sort: .priority)).types == ["INCIDENT"])
    }

    @Test("WI-02 sums up the filters")
    func summary() {
        #expect(WorkItemFilters().summary == "Assigned to me · Open")
        // The old tool's test.
        var filters = WorkItemFilters(scope: .authored, state: .all)
        filters.setLabel("type::bug", in: .with)
        filters.setLabel("workflow::done", in: .without)
        #expect(filters.summary == "Created by me · Open and closed · +bug · −done")

        filters = WorkItemFilters(type: .epic, state: .closed, withLabels: ["uStatus::Sub::Deep", "cGroup:SquadAlpha", "bug"])
        #expect(filters.summary == "Assigned to me · Epics · Closed · +Sub::Deep · +SquadAlpha · +bug")
    }

    @Test("WI-02 sums up any-of labels in parentheses")
    func summaryAny() {
        var filters = WorkItemFilters(labelsMatch: .any)
        filters.setLabel("type::bug", in: .with)
        #expect(filters.summary == "Assigned to me · Open · +bug")
        filters.setLabel("team::web", in: .with)
        #expect(filters.summary == "Assigned to me · Open · +(bug or web)")
    }

    // MARK: - WI-03

    @Test("WI-03 a label is in one list only")
    func oneList() {
        var filters = WorkItemFilters()
        filters.setLabel("type::bug", in: .with)
        filters.setLabel("workflow::done", in: .without)
        #expect(filters.withLabels == ["type::bug"] && filters.withoutLabels == ["workflow::done"])
        filters.setLabel("type::bug", in: .without)
        #expect(filters.withLabels.isEmpty && filters.withoutLabels == ["workflow::done", "type::bug"])
        #expect(filters.list(of: "type::bug") == .without)
        filters.setLabel("workflow::done", in: nil)
        #expect(filters.withoutLabels == ["type::bug"])
        #expect(filters.list(of: "workflow::done") == nil)

        #expect(WorkItemFilters.message(label: "X", putIn: .with) == "Work items must have the label X")
        #expect(WorkItemFilters.message(label: "X", putIn: .without) == "Work items must not have the label X")
        #expect(WorkItemFilters.message(label: "X", putIn: nil) == "The label X is out of the work item filters")
        #expect(WorkItemFilters.message(labelsMatch: .all) == "Work items need all of the must-have labels")
    }

    @Test("WI-03 keeps one must-have label per scope")
    func oneLabelPerScope() {
        var filters = WorkItemFilters()
        for (label, list) in [("uStatus::Todo", WorkItemFilters.LabelList.with), ("uStatus::Done", .without),
                              ("uStatus::Sub::Deep", .with), ("uStatus::InProgress", .with), ("bug", .with)] {
            filters.setLabel(label, in: list)
        }
        #expect(filters.withLabels == ["uStatus::Sub::Deep", "uStatus::InProgress", "bug"])
        #expect(filters.withoutLabels == ["uStatus::Done"])
    }

    @Test("WI-03 nested scope is its own scope")
    func nestedScope() {
        #expect(WorkItemFilters.scope(of: "uStatus::Sub::Deep") == "uStatus::Sub")
        #expect(WorkItemFilters.scope(of: "uStatus::Todo") == "uStatus")
        #expect(WorkItemFilters.scope(of: "cGroup:SquadAlpha") == nil)
        var filters = WorkItemFilters(withLabels: ["uStatus::Sub::Deep"])
        filters.setLabel("uStatus::Sub::Other", in: .with)
        #expect(filters.withLabels == ["uStatus::Sub::Other"])
        filters.setLabel("uStatus::Todo", in: .with)
        #expect(filters.withLabels == ["uStatus::Sub::Other", "uStatus::Todo"])
    }

    @Test("WI-03 switching to all keeps the last label of each scope")
    func switchToAll() {
        var filters = WorkItemFilters(labelsMatch: .any)
        for label in ["uStatus::Todo", "uStatus::InProgress", "bug"] {
            filters.setLabel(label, in: .with)
        }
        filters.setLabelsMatch(.all)
        #expect(filters.labelsMatch == .all)
        #expect(filters.withLabels == ["uStatus::InProgress", "bug"])

        filters = WorkItemFilters(withLabels: ["a::1", "b::1", "a::2"], labelsMatch: .any)
        filters.setLabelsMatch(.all)
        #expect(filters.withLabels == ["b::1", "a::2"])
    }

    @Test("WI-03 any keeps several labels of a scope")
    func anyKeepsSeveral() {
        var filters = WorkItemFilters()
        filters.setLabelsMatch(.any)
        for label in ["uStatus::Todo", "uStatus::InProgress", "bug"] {
            filters.setLabel(label, in: .with)
        }
        #expect(filters.withLabels == ["uStatus::Todo", "uStatus::InProgress", "bug"])
    }

    @Test("WI-03 query variables for all")
    func variablesForAll() {
        var filters = WorkItemFilters()
        filters.setLabel("type::bug", in: .with)
        filters.setLabel("team::web", in: .with)
        filters.setLabel("workflow::done", in: .without)
        let variables = Self.variables(filters, committedLabel: "Committed")
        // The old tool's test: labelName gets all of them, the committed list the committed label too.
        #expect(variables.committedLabels == ["Committed", "team::web", "type::bug"])
        #expect(variables.committedOr == nil && variables.otherOr == nil)
        #expect(variables.otherLabels == ["type::bug", "team::web"])
        #expect(variables.committedNot == ["workflow::done"])
        #expect(variables.otherNot == ["Committed", "workflow::done"])
        #expect(variables.graphQLValue.json.contains(#""committedNot":{"labelName":["workflow::done"]}"#))
    }

    @Test("WI-03 query variables for any")
    func variablesForAny() {
        var filters = WorkItemFilters(labelsMatch: .any)
        filters.setLabel("type::bug", in: .with)
        filters.setLabel("team::web", in: .with)
        let variables = Self.variables(filters, committedLabel: "Committed")
        #expect(variables.committedLabels == ["Committed"])
        #expect(variables.committedOr == ["type::bug", "team::web"])
        #expect(variables.otherLabels == nil)
        #expect(variables.otherOr == ["type::bug", "team::web"])
        #expect(variables.graphQLValue.json.contains(#""otherOr":{"labelNames":["type::bug","team::web"]}"#))
    }

    @Test("WI-03 clear all empties both lists")
    func clearAll() {
        var filters = WorkItemFilters(withLabels: ["a", "b"], withoutLabels: ["c"], labelsMatch: .any)
        filters.clearLabels()
        #expect(filters.withLabels.isEmpty && filters.withoutLabels.isEmpty)
        #expect(filters.labelsMatch == .any)
        #expect(WorkItemFilters.clearedLabelsMessage == "Cleared the work item label filters")
    }

    // MARK: - WI-04

    @Test("WI-04 shows the slot label value before the title")
    func slot() async throws {
        let item = Self.item(labels: ["bug", "slot::Q1", "slot::Q2"])
        #expect(item.slot(prefix: "slot::") == "Q1")

        let real = try #require(try await Self.realWorkItems().committed?.items.first)
        #expect(real.slot(prefix: "cScheduledSlot::") == "2026.51")
    }

    @Test("WI-04 no slot without a prefix")
    func noSlot() {
        #expect(Self.item(labels: ["slot::Q1"]).slot(prefix: "") == nil)
        #expect(Self.item(labels: ["bug"]).slot(prefix: "slot::") == nil)
    }

    @Test("WI-04 keeps labels with markup and shell syntax as plain text")
    func plainTextLabels() throws {
        let evil = "evil::$(touch pwned)"
        let injected = "slot::Q1 | bash=/usr/bin/touch param1=pwned\nInjected | bash=/usr/bin/touch"
        #expect(Self.item(labels: [injected]).slot(prefix: "slot::") == "Q1 | bash=/usr/bin/touch param1=pwned\nInjected | bash=/usr/bin/touch")

        var filters = WorkItemFilters()
        filters.setLabel(evil, in: .with)
        filters.setLabel("%@ %n {{x}}", in: .without)
        #expect(filters.withLabels == [evil] && filters.withoutLabels == ["%@ %n {{x}}"])
        #expect(filters.summary == "Assigned to me · Open · +$(touch pwned) · −%@ %n {{x}}")

        // The variables carry the labels as JSON strings, unchanged.
        let json = Self.variables(filters).graphQLValue.json
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(sent["otherLabels"] as? [String] == [evil])
        #expect((sent["otherNot"] as? [String: [String]])?["labelName"] == ["%@ %n {{x}}", Self.committed])
        let lineBreak = Self.variables(WorkItemFilters(withLabels: [injected])).graphQLValue.json
        #expect(!lineBreak.contains("\n"))
        #expect((try JSONSerialization.jsonObject(with: Data(lineBreak.utf8)) as? [String: Any])?["otherLabels"] as? [String] == [injected])
    }

    @Test("WI-04 short reference of another project")
    func shortReference() {
        #expect(Self.item("\(Self.projectPath)#12").shortReference(project: Self.projectPath) == "#12")
        #expect(Self.item("acme/web/client#12").shortReference(project: Self.projectPath) == "client#12")
        #expect(Self.item("acme/main&3").shortReference(project: Self.projectPath) == "main&3")
        #expect(Self.item("\(Self.projectPath)&3").shortReference(project: Self.projectPath) == "&3")
        #expect(Self.item("odd").shortReference(project: Self.projectPath) == "odd")
    }

    @Test(
        "WI-04 the displayed title drops the item's own key",
        arguments: [
            // The key with the item's own number goes, with a colon, a dash and spaces after it.
            ("[ABC-15003] Improve the difference", "15003", "Improve the difference"),
            ("[ABC-15003]: Improve the difference", "15003", "Improve the difference"),
            ("[ABC-15003] - Improve the difference", "15003", "Improve the difference"),
            ("[abc-15003] Improve the difference", "15003", "Improve the difference"),
            ("[A2-0015003]Improve", "15003", "Improve"),
            // Another number is a real reference; a key mid-title, no key, and a key alone stay.
            ("[ABC-14999] Improve the difference", "15003", "[ABC-14999] Improve the difference"),
            ("Improve [ABC-15003] the difference", "15003", "Improve [ABC-15003] the difference"),
            ("Improve the difference", "15003", "Improve the difference"),
            ("[ABC-15003]", "15003", "[ABC-15003]"),
            ("[2BC-15003] Improve", "15003", "[2BC-15003] Improve"),
            ("[ABC-15003] Improve", nil, "[ABC-15003] Improve"),
        ] as [(String, String?, String)])
    func displayTitle(title: String, iid: String?, shown: String) {
        #expect(WorkItem.displayTitle(of: title, iid: iid) == shown)
        let item = Self.item("\(Self.projectPath)#\(iid ?? "1")", title: title)
        #expect(item.title == title)
        #expect(item.displayTitle == (iid == nil ? title : shown))
    }

    // MARK: - WI-05

    /// The related MRs of `related-merge-requests.json`: one merged, one opened `[cascade]`, one closed.
    private static func related() async throws -> [RelatedMergeRequest] {
        let stub = StubTransport()
        stub.answer(operation: "RelatedMergeRequests", body: try FixtureFiles.string("GitLab/related-merge-requests.json"))
        let operation = try #require(GitLabOperation.relatedMergeRequests(of: item("\(projectPath)#15706")))
        return try await GitLabClient(transport: stub, gitLab: gitLab, token: "t").send(operation)
    }

    @Test("WI-05 marks a work item with an open MR")
    func openMarker() async throws {
        let related = try await Self.related()
        #expect(related.map(\.state) == [.merged, .opened, .closed])
        #expect(RelatedMergeRequestMarker.of(related, ignoredPrefix: "") == .open)
        #expect(RelatedMergeRequestMarker.open.symbol == "arrow.triangle.pull")
    }

    @Test("WI-05 marks a work item with only merged MRs")
    func mergedMarker() async throws {
        let related = try await Self.related()
        #expect(RelatedMergeRequestMarker.of(related, ignoredPrefix: "[cascade]") == .merged)
        #expect(RelatedMergeRequestMarker.merged.symbol == "flag.checkered")
        #expect(RelatedMergeRequestMarker.of(related.filter { $0.state == .closed }, ignoredPrefix: "") == nil)
        #expect(RelatedMergeRequestMarker.of([], ignoredPrefix: "") == nil)

        // The real answer of an item without related MRs.
        let stub = StubTransport()
        stub.answer(operation: "RelatedMergeRequests", body: try FixtureFiles.string("GitLab/related-merge-requests-none.json"))
        let operation = try #require(GitLabOperation.relatedMergeRequests(of: Self.item()))
        #expect(try await GitLabClient(transport: stub, gitLab: Self.gitLab, token: "t").send(operation).isEmpty)
    }

    @Test("WI-05 skips MRs with the ignored prefix")
    func ignoredPrefix() async throws {
        let cascade = try await Self.related().filter { $0.title.hasPrefix("[cascade]") }
        #expect(RelatedMergeRequestMarker.of(cascade, ignoredPrefix: "[cascade]") == nil)
        #expect(RelatedMergeRequestMarker.of(cascade, ignoredPrefix: "") == .open)
    }

    @Test("WI-05 ignores a broken cache entry")
    func brokenCacheEntry() async throws {
        let folder = try TemporaryFolder()
        let caches = CacheStore(folder: folder.url, report: { _ in })
        let good = Self.item("\(Self.projectPath)#1")
        let broken = Self.item("\(Self.projectPath)#2")
        let entry = RelatedMergeRequestsCache.Entry(workItemUpdatedAt: good.updatedAt, fetchedAt: .now, mergeRequests: try await Self.related())
        try caches.save(Cached(value: RelatedMergeRequestsCache(entries: [good.reference: entry, broken.reference: entry]), fetchedAt: .now),
                        as: .relatedMergeRequests, for: .main)

        // Half written, like a write cut short.
        let url = caches.url(of: CacheFile<RelatedMergeRequestsCache>.relatedMergeRequests, for: .main)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var value = try #require(json["value"] as? [String: Any])
        var entries = try #require(value["entries"] as? [String: Any])
        entries[broken.reference] = ["workItemUpdatedAt": "half", "mergeRequests": [["iid": "1"]]]
        value["entries"] = entries
        json["value"] = value
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let cache = try #require(caches.load(.relatedMergeRequests, for: .main)).value
        #expect(cache.entries.keys.sorted() == [good.reference])
        #expect(cache.marker(of: good, ignoredPrefix: "") == .open)
        #expect(cache.marker(of: broken, ignoredPrefix: "") == nil)
    }

    @Test("WI-05 asks nothing for epics")
    func noEpics() {
        #expect(GitLabOperation.relatedMergeRequests(of: Self.item("acme/main&3")) == nil)
        #expect(GitLabOperation.relatedMergeRequests(of: Self.item("no-iid")) == nil)
        #expect(GitLabOperation.relatedMergeRequests(of: Self.item("acme/web/client#12"))?.variables == #"{"path":"acme/web/client","iid":"12"}"#)
    }

    // MARK: - WI-07, MR-04

    @Test("WI-07 links to all merge requests")
    func mergeRequestsLink() {
        #expect(GitLabLinks.mergeRequests(gitLab: Self.gitLab).absoluteString == "https://gitlab.example.com/dashboard/merge_requests")
    }

    @Test("WI-07 links to all work items with scope and state")
    func workItemsLink() {
        #expect(GitLabLinks.workItems(gitLab: Self.gitLab, filters: WorkItemFilters(), me: "alex.doe").absoluteString
            == "https://gitlab.example.com/dashboard/issues?assignee_username=alex.doe&state=opened")
        #expect(GitLabLinks.workItems(gitLab: Self.gitLab, filters: WorkItemFilters(scope: .authored, state: .all), me: "alex.doe").absoluteString
            == "https://gitlab.example.com/dashboard/issues?author_username=alex.doe&state=all")
        #expect(GitLabLinks.workItems(gitLab: Self.gitLab, filters: WorkItemFilters(), me: nil).absoluteString
            == "https://gitlab.example.com/dashboard/issues")
    }

    @Test("MR-04 explains how to get a GitLab token")
    func tokenLink() {
        #expect(GitLabLinks.newToken(gitLab: Self.gitLab).absoluteString
            == "https://gitlab.example.com/-/user_settings/personal_access_tokens?name=menubar-monitor&scopes=api")
        #expect(Problem.noToken(.gitLab).message == "Needs a GitLab token with the api scope")
    }
}

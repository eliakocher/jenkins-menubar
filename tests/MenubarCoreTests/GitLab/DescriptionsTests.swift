import Foundation
import Testing

@testable import MenubarCore

/// The descriptions of the selected merge requests and work items (WIN-02).
@Suite("Descriptions")
@MainActor
struct DescriptionsTests {
    private nonisolated static let gitLab = URL(string: "https://gitlab.example.com")!
    private nonisolated static let updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// An item, the request its description takes, and GitLab's answer for a text.
    struct Case: Sendable, CustomTestStringConvertible {
        var source: DescriptionSource
        var operation: String
        var variables: String
        var answer: @Sendable (String) -> String
        /// GitLab's answer without the item: gone, or not visible to the token
        var missing: String
        var testDescription: String
    }

    nonisolated static let cases: [Case] = [
        Case(
            source: source(.mergeRequest, "group/project!12", page: "group/project/-/merge_requests/12"),
            operation: "MergeRequestDescription", variables: #"{"path":"group/project","iid":"12"}"#,
            answer: { #"{"data": {"project": {"mergeRequest": {"description": \#(json($0))}}}}"# },
            missing: #"{"data": {"project": {"mergeRequest": null}}}"#, testDescription: "merge request"),
        Case(
            source: source(.workItem, "group/project#31", page: "group/project/-/work_items/31"),
            operation: "WorkItemDescription", variables: #"{"path":"group/project","iid":"31"}"#,
            answer: { #"{"data": {"namespace": {"workItem": {"widgets": [{}, {"description": \#(json($0))}, {}]}}}}"# },
            missing: #"{"data": {"namespace": {"workItem": null}}}"#, testDescription: "work item"),
        Case(
            source: source(.workItem, "group/subgroup&7", page: "groups/group/subgroup/-/epics/7"),
            operation: "WorkItemDescription", variables: #"{"path":"group/subgroup","iid":"7"}"#,
            answer: { #"{"data": {"namespace": {"workItem": {"widgets": [{"description": \#(json($0))}]}}}}"# },
            missing: #"{"data": {"namespace": null}}"#, testDescription: "epic"),
    ]

    @Test("WIN-02 loads the description when the item is selected, once per update", arguments: cases)
    func loadsOnSelection(_ item: Case) async throws {
        let folder = try TemporaryFolder()
        let stub = StubTransport()
        let store = DescriptionsStore(services: try Self.services(stub: stub, folder: folder))
        stub.answer(operation: item.operation, times: 1, body: item.answer("### Summary\n\n- [ ] Tests"))

        #expect(store.description(of: item.source) == .loading)
        await store.load(item.source)
        #expect(store.description(of: item.source) == .loaded("### Summary\n\n- [ ] Tests"))
        #expect(stub.requests(operation: item.operation).map(\.graphQL?.variables) == [item.variables])

        // Selected again, unchanged: nothing is asked.
        await store.load(item.source)
        #expect(stub.requests.count == 1)

        // The item changed: the old text stays while the new one loads, and when that fails.
        var changed = item.source
        changed.updatedAt += 60
        #expect(store.description(of: changed) == ItemDescription(text: "### Summary\n\n- [ ] Tests", isCurrent: false))
        stub.answer(operation: item.operation, times: 1, body: item.missing)
        await store.load(changed)
        #expect(store.description(of: changed) == ItemDescription(text: "### Summary\n\n- [ ] Tests", isCurrent: false, failed: true))

        // Selected again after the failure: asked again.
        stub.answer(operation: item.operation, times: 1, body: item.answer(""))
        await store.load(changed)
        #expect(store.description(of: changed) == .loaded(""))
        #expect(stub.requests.count == 3)
    }

    // MARK: - Helpers

    private nonisolated static func source(_ kind: DescriptionSource.Kind, _ reference: String, page: String) -> DescriptionSource {
        DescriptionSource(kind: kind, reference: reference, webURL: gitLab.appending(path: page), updatedAt: updatedAt)
    }

    private nonisolated static func json(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    /// GitLab on the stub, a token in a fake keychain, and the team values of `group/project`.
    private static func services(stub: StubTransport, folder: TemporaryFolder) throws -> GitLabServices {
        let team = TeamStore(folder: folder.file("support"), report: { _ in })
        try team.save(Project(id: .main, team: TeamValues(
            jenkinsJobURL: "https://jenkins.example.com/job/project", gitLabURL: gitLab.absoluteString,
            gitLabProject: "group/project")))
        let log = ActivityLog(folder: folder.file("logs"))
        return GitLabServices(
            transport: stub, clock: ContinuousClock(),
            tokens: TokenStore(keychain: InMemoryKeychain(values: [TokenAccount.gitlab.rawValue: "glpat-test"])), team: team,
            caches: CacheStore(folder: folder.file("caches"), report: { _ in }), log: log)
    }
}

import Foundation
import Testing

@testable import MenubarCore

/// The Recently Merged section's data (MR-17): the merged aliases of the MergeRequests query, the window, the order and
/// the cap.
@Suite("Recently merged")
struct RecentlyMergedTests {
    private static let me = "alex.doe"
    private static let now = try! Date.ISO8601FormatStyle().parse("2026-11-03T12:00:00Z")
    private static let gitLab = URL(string: "https://gitlab.example.com")!

    private static func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private static func iso(_ date: Date) -> String {
        Date.ISO8601FormatStyle().format(date)
    }

    /// A generated node of the query's answer.
    private static func node(
        _ iid: Int, mergedHoursAgo: Double? = nil, target: String = "develop", mergedBy: String? = "alex.doe", author: String = "alex.doe"
    ) -> String {
        let merged = mergedHoursAgo.map {
            """
            , "targetBranch": "\(target)", "mergedAt": "\(iso(hoursAgo($0)))"
            \(mergedBy.map { ", \"mergeUser\": {\"username\": \"\($0)\", \"name\": \"Name of \($0)\"}" } ?? "")
            """
        } ?? ""
        return """
            {"iid": "\(iid)", "title": "Change \(iid)",
             "webUrl": "https://gitlab.example.com/acme/app/-/merge_requests/\(iid)", "draft": false,
             "reference": "acme/app!\(iid)", "updatedAt": "\(iso(hoursAgo(1)))",
             "author": {"username": "\(author)", "name": "Name of \(author)"}\(merged)}
            """
    }

    private static func nodes(_ items: [String]) -> String {
        "{\"nodes\": [\(items.joined(separator: ","))]}"
    }

    /// The answer of the open query (MR-01) or, with the merged lists, of the Recently Merged query.
    private static func answer(
        open: [String] = [], mergedAuthored: [String]? = nil, mergedAssigned: [String]? = nil, mergedReviewing: [String]? = nil
    ) -> String {
        var fields = ["\"username\": \"\(me)\""]
        if mergedAuthored == nil, mergedAssigned == nil, mergedReviewing == nil {
            fields += ["\"authored\": \(nodes(open))", "\"assigned\": \(nodes([]))", "\"reviewing\": \(nodes([]))"]
        }
        if let mergedAuthored { fields.append("\"mergedAuthored\": \(nodes(mergedAuthored))") }
        if let mergedAssigned { fields.append("\"mergedAssigned\": \(nodes(mergedAssigned))") }
        if let mergedReviewing { fields.append("\"mergedReviewing\": \(nodes(mergedReviewing))") }
        return "{\"data\": {\"currentUser\": {\(fields.joined(separator: ","))}}}"
    }

    private static func load(_ body: String, merged: Bool = false) async throws -> (list: MergeRequestList, stub: StubTransport) {
        let stub = StubTransport()
        let client = GitLabClient(transport: stub, gitLab: gitLab, token: "t")
        if merged {
            stub.answer(operation: "RecentlyMerged", body: body)
            return (try await client.send(.recentlyMerged(now: now)), stub)
        }
        stub.answer(operation: "MergeRequests", body: body)
        return (try await client.send(.mergeRequests), stub)
    }

    private static func mergeRequest(_ iid: Int, mergedHoursAgo: Double?) -> MergeRequest {
        MergeRequest(
            iid: iid, title: "Change \(iid)", webURL: URL(string: "https://gitlab.example.com/acme/app/-/merge_requests/\(iid)")!,
            reference: "acme/app!\(iid)", author: .init(username: me, name: "Alex Doe"), updatedAt: hoursAgo(1), roles: [.authored],
            mergedAt: mergedHoursAgo.map(hoursAgo))
    }

    @Test("MR-17 decodes the merged aliases, merges the roles, and asks them in a query of their own")
    func decodesMerged() async throws {
        let body = Self.answer(
            mergedAuthored: [Self.node(10, mergedHoursAgo: 5), Self.node(11, mergedHoursAgo: 2)],
            mergedAssigned: [Self.node(11, mergedHoursAgo: 2)],
            mergedReviewing: [Self.node(12, mergedHoursAgo: 30, mergedBy: "sam.lee", author: "sam.lee")])
        let (list, stub) = try await Self.load(body, merged: true)
        #expect(list.mergeRequests.isEmpty)
        // Newest merge first, each once with all its roles.
        #expect(list.merged.map(\.iid) == [11, 10, 12])
        #expect(list.merged.first { $0.iid == 11 }?.roles == [.authored, .assigned])
        #expect(list.merged.first { $0.iid == 12 }?.roles == [.reviewRequested])
        let twelve = try #require(list.merged.first { $0.iid == 12 })
        #expect(twelve.mergedBy == .init(username: "sam.lee", name: "Name of sam.lee") && twelve.targetBranch == "develop")
        #expect(twelve.mergedAt == Self.hoursAgo(30))

        // The window as a variable, and the three merged lists in the query of their own.
        #expect(stub.requests.count == 1)
        let request = try #require(stub.requests(operation: "RecentlyMerged").first)
        let sent = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(sent.contains("\"variables\":{\"mergedAfter\":\"\(Self.iso(Self.now.addingTimeInterval(-7 * 24 * 3600)))\"}"))
        for field in ["mergedAuthored: authoredMergeRequests", "mergedAssigned: assignedMergeRequests", "mergedReviewing: reviewRequestedMergeRequests"] {
            #expect(sent.contains(field + "(state: merged, mergedAfter: $mergedAfter, sort: MERGED_AT_DESC, first: 10)"), "\(field)")
        }
    }

    @Test("MR-17 an answer without the merged aliases, and a cache from before them, decode with none")
    func decodesWithoutMerged() async throws {
        let (list, _) = try await Self.load(Self.answer(open: [Self.node(1)]))
        #expect(list.mergeRequests.map(\.iid) == [1] && list.merged.isEmpty)

        // A cache file written before `merged`, `mergedAt`, `mergedBy` and `targetBranch` existed.
        let old = """
            {"username": "alex.doe", "mergeRequests": [{"iid": 1, "title": "Old", "webURL": "https://gitlab.example.com/acme/app/-/merge_requests/1",
             "reference": "acme/app!1", "isDraft": false, "author": {"username": "alex.doe", "name": "Alex Doe"}, "reviewers": [],
             "updatedAt": 783000000, "roles": ["authored"]}]}
            """
        let decoded = try JSONDecoder().decode(MergeRequestList.self, from: Data(old.utf8))
        #expect(decoded.merged.isEmpty && decoded.mergeRequests.first?.mergedAt == nil && decoded.mergeRequests.first?.targetBranch == nil)

        // The new list survives the cache's round trip.
        let (merged, _) = try await Self.load(Self.answer(mergedAuthored: [Self.node(10, mergedHoursAgo: 5)]), merged: true)
        let again = try JSONDecoder().decode(MergeRequestList.self, from: JSONEncoder().encode(merged))
        #expect(again == merged)
    }

    @Test("MR-17 shows the MRs merged within 7 days, newest merge first, at most 10", arguments: [true, false])
    func window(inside: Bool) {
        let hours: Double = inside ? 7 * 24 - 1 : 7 * 24 + 1
        let list = MergeRequestList(
            username: Self.me, mergeRequests: [],
            merged: [Self.mergeRequest(1, mergedHoursAgo: hours), Self.mergeRequest(2, mergedHoursAgo: nil)])
        // An MR without a merge time isn't merged as far as the list knows.
        let expected: [Int] = inside ? [1] : []
        #expect(MergeRequestSections(list, now: Self.now).merged.map(\.iid) == expected)
    }

    @Test("MR-17 Recently Merged is sorted by merge time and capped")
    func sortAndCap() {
        let many = (1...14).map { Self.mergeRequest($0, mergedHoursAgo: Double($0 % 7) * 10 + 1) }
        let shown = MergeRequestSections.recentlyMerged(many, now: Self.now)
        #expect(shown.count == 10)
        #expect(zip(shown, shown.dropFirst()).allSatisfy { ($0.mergedAt!, $0.iid) > ($1.mergedAt!, $1.iid) })
        // The newest merge is first, whatever the order they came in.
        #expect(shown.first?.iid == 7 || shown.first?.iid == 14)
        #expect(MergeRequestSections.recentlyMerged(many.reversed(), now: Self.now).map(\.iid) == shown.map(\.iid))
    }

    @Test("MR-17 the open sections never hold a merged MR, and the detail finds it")
    func openSectionsApart() {
        let list = MergeRequestList(
            username: Self.me, mergeRequests: [Self.mergeRequest(1, mergedHoursAgo: nil)],
            merged: [Self.mergeRequest(2, mergedHoursAgo: 3)])
        let sections = MergeRequestSections(list, now: Self.now)
        #expect(sections.yours.map(\.iid) == [1] && sections.merged.map(\.iid) == [2])
        #expect(sections.sections.map(\.kind) == [.yours] && !sections.isEmpty)
        #expect(list.mergeRequest(id: list.merged[0].id)?.iid == 2 && list.mergeRequest(id: list.mergeRequests[0].id)?.iid == 1)
        #expect(MergeRequestStatus.of(list.merged[0], me: Self.me).kind == .merged)
        #expect(MergeRequestStatus.of(list.mergeRequests[0]).kind != .merged)
    }
}

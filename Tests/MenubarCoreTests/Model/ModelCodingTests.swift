import Foundation
import Testing

@testable import MenubarCore

@Suite("Model coding")
struct ModelCodingTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000.123)

    private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: JSONCoding.encoder.encode(value))
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    }

    static let builds = [
        Build(job: "MR-1", number: 7, title: "Fix the login", gitLabURL: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/1"),
              author: "Jane Doe", kind: .watched, phase: .running, startedAt: date, estimatedDuration: 1500.5,
              stages: [Stage(name: "build", status: .inProgress, duration: 12.25)], testCounts: TestCounts(failed: 3, total: 1200)),
        Build(job: "feature%252Ffoo", number: 2, kind: .mine, phase: .finished(result: .success, duration: 60),
              startedAt: date),
        Build(job: "MR-2", number: 1, kind: .mine, phase: .finished(result: BuildResult(rawValue: "NOT_BUILT"), duration: 0),
              startedAt: date, stages: []),
    ]

    @Test("builds round-trip, including unknown results and empty stages", arguments: builds)
    func buildRoundTrip(build: Build) throws {
        #expect(try Self.roundTrip(build) == build)
    }

    @Test("results and statuses are stored as Jenkins and GitLab name them")
    func openStrings() throws {
        #expect(try Self.json(BuildResult.success) == #""SUCCESS""#)
        #expect(try Self.json(Stage.Status.inProgress) == #""IN_PROGRESS""#)
        #expect(try Self.json(MergeRequest.MergeStatus.needRebase) == #""NEED_REBASE""#)
        #expect(try JSONCoding.decoder.decode(BuildResult.self, from: Data(#""ABORTED""#.utf8)) == .aborted)
        #expect(try JSONCoding.decoder.decode(MergeRequest.MergeStatus.self, from: Data(#""BLOCKED_STATUS""#.utf8)).rawValue
            == "BLOCKED_STATUS")
    }

    @Test("a reviewer cached before the name was asked for still decodes (WIN-02)")
    func legacyReviewer() throws {
        let cached = Data(#"{"username": "me", "reviewState": "APPROVED", "approved": true}"#.utf8)
        #expect(try JSONCoding.decoder.decode(MergeRequest.Reviewer.self, from: cached)
            == MergeRequest.Reviewer(username: "me", reviewState: .approved, approved: true))
    }

    @Test("projects round-trip, and a dictionary keyed by project id is a JSON object")
    func projects() throws {
        let project = Project(id: .main, team: TeamValues(jenkinsJobURL: "https://jenkins.example.com/job/a%20b",
                                                          gitLabURL: "https://gitlab.example.com", gitLabProject: "g/p"))
        let byID: [ProjectID: Int] = [.main: 1]

        #expect(try Self.roundTrip(project) == project)
        #expect(try Self.json(byID).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
            == #"{"main":1}"#)
        #expect(try Self.roundTrip(byID) == byID)
    }

    @Test("a project id is safe as a folder name")
    func projectIDs() throws {
        #expect(ProjectID(rawValue: "main") == .main)
        #expect(ProjectID(rawValue: "p-1f0c.x_y") != nil)
        #expect(ProjectID.random() != ProjectID.random())
        for unsafe in ["", ".", "..", ".hidden", "a/b", "a b", "ä", String(repeating: "a", count: 65)] {
            #expect(ProjectID(rawValue: unsafe) == nil, "\(unsafe)")
        }
        #expect(throws: DecodingError.self) {
            try JSONCoding.decoder.decode(ProjectID.self, from: Data(#""../etc""#.utf8))
        }
    }
}

import Foundation
import Testing

@testable import MenubarCore

@Suite("ProblemTracker")
struct ProblemTrackerTests {
    @Test("LOG-01 logs a problem once and when resolved")
    func onceAndWhenResolved() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let tracker = ProblemTracker(log: log)

        for _ in 1...3 {
            await tracker.update("jenkins", to: .unreachable(.jenkins), source: .jenkins)
        }
        await tracker.update("jenkins", to: nil, source: .jenkins)
        await tracker.update("jenkins", to: nil, source: .jenkins)

        let entries = await log.entries()
        #expect(entries.map(\.message) == ["Jenkins unreachable (VPN?)", "Resolved: Jenkins unreachable (VPN?)"])
        #expect(entries.map(\.level) == [.error, .info])
        #expect(entries.map(\.outcome) == [.failed("PROBLEM"), .ok("RESOLVED")])
        #expect(entries.allSatisfy { $0.source == .jenkins })
        #expect(await tracker.problem("jenkins") == nil)
    }

    @Test("LOG-01 logs a problem again when its text changes")
    func whenTheTextChanges() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let tracker = ProblemTracker(log: log)

        await tracker.update("gitlab.workItems", to: .httpStatus(.gitLab, status: 500), source: .gitlab)
        await tracker.update("gitlab.workItems", to: .httpStatus(.gitLab, status: 502), source: .gitlab)
        await tracker.update("gitlab.workItems", to: .graphQLErrors(messages: ["Timeout", "first"]), source: .gitlab)
        // The same text, though the problem differs: not logged again.
        await tracker.update("gitlab.workItems", to: .graphQLErrors(messages: ["Timeout", "second"]), source: .gitlab)

        #expect(await log.entries().map(\.message) == [
            "GitLab answered with HTTP 500",
            "GitLab answered with HTTP 502",
            "Timeout",
        ])
        #expect(await tracker.problem("gitlab.workItems") == .graphQLErrors(messages: ["Timeout", "second"]))
    }

    @Test("LOG-01 keeps the problems of each check apart")
    func keysApart() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let tracker = ProblemTracker(log: log)

        await tracker.update("gitlab.mergeRequests", to: .unreachable(.gitLab), source: .gitlab)
        await tracker.update("gitlab.workItems", to: .unreachable(.gitLab), source: .gitlab)
        await tracker.update("gitlab.workItems", to: nil, source: .gitlab)

        #expect(await log.entries().map(\.message) == ["GitLab unreachable", "GitLab unreachable", "Resolved: GitLab unreachable"])
        #expect(await tracker.problem("gitlab.mergeRequests") == .unreachable(.gitLab))
    }

    @Test("LOG-01 doesn't log again a problem the caches still had at launch")
    func seededProblems() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let tracker = ProblemTracker(log: log, current: ["jenkins": (.rejectedToken(.jenkins), .jenkins)])

        await tracker.update("jenkins", to: .rejectedToken(.jenkins), source: .jenkins)
        await tracker.update("jenkins", to: nil, source: .jenkins)

        #expect(await log.entries().map(\.message) == ["Resolved: Jenkins rejected the token"])
    }
}

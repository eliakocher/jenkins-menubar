import Foundation
import Testing

@testable import MenubarCore

@Suite("CheckTimes")
struct CheckTimesTests {
    private static let time = Date(timeIntervalSince1970: 1_793_188_800)
    private static let root = URL(string: "https://jenkins.example.com/job/mrs/")!

    @Test("LOG-05 records each check with its requests and failures")
    func recordsTheCheck() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url, now: { Self.time })
        let checks = CheckTimes(folder: folder.url, log: log, now: { Self.time })
        let clock = TestClock()
        let stub = StubTransport(clock: clock)
        stub.answer(path: "/job/mrs/job/MR-1/api/json", after: .milliseconds(250), body: "{}")
        stub.answer(path: "/job/mrs/job/MR-2/api/json", after: .milliseconds(500), status: 500)
        stub.answer(path: "/job/mrs/job/MR-3/api/json", body: "{}")
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, clock: clock, pathsRelativeTo: Self.root)

        let check = Task {
            await checks.measure(.jenkins) {
                for job in ["MR-1", "MR-2", "MR-3"] {
                    _ = try? await recorder.send(Self.request("job/\(job)/api/json"))
                }
            }
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await check.value

        #expect(await checks.all() == [CheckTime(time: Self.time, source: .jenkins, seconds: 0.75, requests: 3, failed: 1)])
        let summary = try #require(await log.entries().last)
        #expect(summary.message == "Checked Jenkins: 3 requests, 0.75s together")
        #expect(summary.level == .debug && summary.source == .jenkins)
        #expect(summary.outcome == .failed("1 FAILED"))
    }

    @Test("LOG-01 logs a check summary")
    func logsTheSummary() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let checks = CheckTimes(folder: folder.url, log: log)
        let stub = StubTransport()
        stub.answer(body: "{}")
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, clock: TestClock())

        try await checks.measure(.gitlab) {
            _ = try await recorder.send(Self.request("api/json"))
        }

        let summary = try #require(await log.entries().last)
        #expect(summary.message == "Checked GitLab: 1 request, 0.00s together")
        #expect(summary.outcome == .ok("OK"))
    }

    @Test("LOG-05 records nothing without requests")
    func nothingWithoutRequests() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let checks = CheckTimes(folder: folder.url, log: log)

        let answer = await checks.measure(.gitlab) { 42 }

        #expect(answer == 42)
        #expect(await checks.all().isEmpty)
        #expect(folder.contents().isEmpty)
    }

    @Test("LOG-05 a GitLab load during a Jenkins check is recorded apart")
    func overlappingChecks() async throws {
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let checks = CheckTimes(folder: folder.url, log: log, now: { Self.time })
        let stub = StubTransport()
        stub.answer(body: "{}")
        stub.answer(path: "/job/mrs/job/MR-2/api/json", status: 404)
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, clock: TestClock())

        async let jenkins: Void = checks.measure(.jenkins) {
            // Child tasks count for the check that started them.
            await withTaskGroup(of: Void.self) { group in
                for job in ["MR-1", "MR-2"] {
                    group.addTask { _ = try? await recorder.send(Self.request("job/\(job)/api/json")) }
                }
            }
        }
        async let gitLab: Void = checks.measure(.gitlab) {
            _ = try? await recorder.send(Self.request("api/graphql"))
        }
        _ = await (jenkins, gitLab)

        let records = await checks.all().sorted { $0.source.rawValue < $1.source.rawValue }
        #expect(records == [
            CheckTime(time: Self.time, source: .gitlab, seconds: 0, requests: 1, failed: 0),
            CheckTime(time: Self.time, source: .jenkins, seconds: 0, requests: 2, failed: 1),
        ])
    }

    @Test("LOG-05 a check that fails is recorded with the requests it made")
    func failedCheck() async throws {
        struct Stop: Error {}
        let folder = try TemporaryFolder()
        let log = ActivityLog(folder: folder.url)
        let checks = CheckTimes(folder: folder.url, log: log, now: { Self.time })
        let stub = StubTransport()
        stub.fail(with: .unknownHost)
        let recorder = RequestRecorder(wrapping: stub, log: log, capture: nil, clock: TestClock())

        await #expect(throws: TransportError.unknownHost) {
            try await checks.measure(.jenkins) {
                _ = try await recorder.send(Self.request("api/json"))
            }
        }

        #expect(await checks.all() == [CheckTime(time: Self.time, source: .jenkins, seconds: 0, requests: 1, failed: 1)])
    }

    @Test("LOG-03 check times keep their newest half")
    func keepsTheNewestHalf() async throws {
        #expect(CheckTimes.defaultMaxBytes == 524_288)
        let folder = try TemporaryFolder()
        let checks = CheckTimes(folder: folder.url, maxBytes: 1000)

        for number in 1...40 {
            await checks.append(CheckTime(time: Self.time, source: .jenkins, seconds: Double(number), requests: 1, failed: 0))
        }

        let kept = await checks.all().map { Int($0.seconds) }
        #expect(kept.last == 40)
        #expect(kept == Array(kept[0]...40), "the newest, without gaps")
        #expect(kept.count < 40)
        #expect(await checks.totalBytes() < 1200)
    }

    @Test("LOG-04 clear deletes the check times")
    func clears() async throws {
        let folder = try TemporaryFolder()
        let checks = CheckTimes(folder: folder.url)
        await checks.append(CheckTime(time: Self.time, source: .gitlab, seconds: 1, requests: 1, failed: 0))

        await checks.clear()

        #expect(await checks.all().isEmpty)
        #expect(folder.contents().isEmpty)
    }

    private static func request(_ path: String) -> HTTPRequest {
        HTTPRequest(url: URL(string: path, relativeTo: root)!.absoluteURL, timeout: .seconds(20))
    }
}

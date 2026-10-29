import Foundation
import Testing

@testable import MenubarCore

@Suite("ActivityStore")
@MainActor
struct ActivityStoreTests {
    /// 2026-10-28 12:30:00 UTC
    private nonisolated static let now = Date(timeIntervalSince1970: 1_793_190_600)
    private nonisolated static let jenkinsToken = TokenStore.jenkinsToken(user: "jdoe", apiToken: "secret-api-token")
    private nonisolated static let gitLabToken = "glpat-SecretToken_123"

    /// The log, the kept requests and the check times in a temporary folder, and a store over them, in UTC.
    private struct Harness {
        let folder: TemporaryFolder
        let defaults = TemporaryDefaults()
        let log: ActivityLog
        let requests: RequestCapture
        let checks: CheckTimes
        let clock = TestClock()

        init() throws {
            folder = try TemporaryFolder()
            log = ActivityLog(folder: folder.url, now: { ActivityStoreTests.now })
            requests = RequestCapture(folder: folder.file("requests"))
            checks = CheckTimes(folder: folder.url, now: { ActivityStoreTests.now })
        }

        @MainActor
        func store() -> ActivityStore {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            return ActivityStore(
                log: log, requests: requests, checkTimes: checks, defaults: defaults.defaults, clock: clock,
                calendar: calendar, now: { ActivityStoreTests.now })
        }

        /// Adds an entry so many minutes before `now`.
        func add(
            _ level: ActivityEntry.Level, _ source: ActivityEntry.Source, _ message: String, detail: String? = nil,
            outcome: ActivityEntry.Outcome? = nil, minutesAgo: Double = 0
        ) async {
            await log.append(ActivityEntry(
                time: ActivityStoreTests.now.addingTimeInterval(-minutesAgo * 60), level: level, source: source,
                message: message, detail: detail, outcome: outcome))
        }

        /// Adds a check time so many minutes before `now`.
        func check(_ source: ActivityEntry.Source, seconds: Double, failed: Int = 0, minutesAgo: Double) async {
            await checks.append(CheckTime(
                time: ActivityStoreTests.now.addingTimeInterval(-minutesAgo * 60), source: source, seconds: seconds,
                requests: 2, failed: failed))
        }

        /// One entry of each level and source, oldest first.
        func addMixed() async {
            await add(.debug, .jenkins, "GET /job/MR-1/api/json in 0.01s", outcome: .ok("200"), minutesAgo: 5)
            await add(.info, .jenkins, "MR-1 #7 started: Fix the login", outcome: .running("RUNNING"), minutesAgo: 4)
            await add(.warning, .gitlab, "POST WorkItems: no answer within 20 seconds", outcome: .failed("TIMEOUT"), minutesAgo: 3)
            await add(.error, .gitlab, "GitLab unreachable", outcome: .failed("PROBLEM"), minutesAgo: 2)
            await add(.info, .settings, "alertStyle: window → banner", minutesAgo: 1)
            await add(.info, .alerts, "MR-1 #7 succeeded", detail: "Fix the login", outcome: .ok("SUCCESS"), minutesAgo: 0)
        }
    }

    @Test("LOG-04 filters by level")
    func filtersByLevel() async throws {
        let harness = try Harness()
        await harness.addMixed()
        let store = harness.store()
        await store.reload()

        #expect(store.levelFilter == .everything)
        #expect(store.matchingItems.count == 6)
        store.levelFilter = .events
        #expect(store.matchingItems.allSatisfy { $0.entry.level != .debug })
        #expect(store.matchingItems.count == 5)
        store.levelFilter = .problems
        #expect(store.matchingItems.map(\.entry.level) == [.error, .warning])
        #expect(store.countText == "2 entries")

        // The choice is remembered.
        let again = harness.store()
        await again.reload()
        #expect(again.levelFilter == .problems)
        #expect(again.matchingItems.count == 2)
    }

    @Test("LOG-04 filters by source")
    func filtersBySource() async throws {
        let harness = try Harness()
        await harness.addMixed()
        let store = harness.store()
        await store.reload()

        store.sourceFilter = .gitlab
        #expect(store.matchingItems.map(\.entry.message) == ["GitLab unreachable", "POST WorkItems: no answer within 20 seconds"])
        store.levelFilter = .problems
        store.sourceFilter = .settings
        #expect(store.matchingItems.isEmpty)
        #expect(store.emptyState == .nothingToShow)

        let again = harness.store()
        #expect(again.sourceFilter == .settings)
        again.sourceFilter = nil
        #expect(harness.store().sourceFilter == nil)
    }

    @Test("LOG-04 searches message detail source and outcome")
    func searches() async throws {
        let harness = try Harness()
        await harness.addMixed()
        let store = harness.store()
        await store.reload()

        func messages(_ search: String) -> [String] {
            store.searchText = search
            return store.matchingItems.map(\.entry.message)
        }
        #expect(messages("started") == ["MR-1 #7 started: Fix the login"])
        #expect(messages("FIX THE") == ["MR-1 #7 succeeded", "MR-1 #7 started: Fix the login"])
        #expect(messages("settings") == ["alertStyle: window → banner"])
        #expect(messages(" Jenkins ") == ["MR-1 #7 started: Fix the login", "GET /job/MR-1/api/json in 0.01s"])
        #expect(messages("timeout") == ["POST WorkItems: no answer within 20 seconds"])
        #expect(messages("problem") == ["GitLab unreachable"])
        #expect(store.countText == "1 entry")
        #expect(messages("nothing like this").isEmpty)
        #expect(store.emptyState == .noSearchResults("nothing like this"))
        #expect(messages("").count == 6)
    }

    @Test("LOG-04 copies entries oldest first")
    func copiesOldestFirst() async throws {
        let harness = try Harness()
        await harness.addMixed()
        let store = harness.store()
        await store.reload()

        #expect(store.copyText() == """
            2026-10-28 12:25:00  DEBUG  Jenkins  200  GET /job/MR-1/api/json in 0.01s
            2026-10-28 12:26:00  INFO  Jenkins  RUNNING  MR-1 #7 started: Fix the login
            2026-10-28 12:27:00  WARNING  GitLab  TIMEOUT  POST WorkItems: no answer within 20 seconds
            2026-10-28 12:28:00  ERROR  GitLab  PROBLEM  GitLab unreachable
            2026-10-28 12:29:00  INFO  Settings  alertStyle: window → banner
            2026-10-28 12:30:00  INFO  Alerts  SUCCESS  MR-1 #7 succeeded  Fix the login
            """)

        // A selection, in any order, still comes out oldest first; filters apply.
        let newest = store.matchingItems[0].id
        let oldest = store.matchingItems[5].id
        #expect(store.copyText(of: [newest, oldest]).split(separator: "\n").map { $0.prefix(19) } == [
            "2026-10-28 12:25:00", "2026-10-28 12:30:00",
        ])
        store.levelFilter = .problems
        #expect(store.copyText().split(separator: "\n").count == 2)
        #expect(store.copyText(of: [newest]).isEmpty)
    }

    @Test("LOG-04 clear leaves only the cleared entry")
    func clearLeavesOnlyTheClearedEntry() async throws {
        let harness = try Harness()
        await harness.addMixed()
        await harness.check(.jenkins, seconds: 0.4, minutesAgo: 10)
        _ = await harness.requests.save(RequestRecord(method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, seconds: 0.1))
        let store = harness.store()
        await store.reload()
        #expect(!store.chart.isEmpty)
        #expect(store.totalBytes > 0)

        await store.clear()

        #expect(store.items.map(\.entry.message) == ["Cleared the logs"])
        #expect(store.items.first?.entry.level == .info)
        #expect(store.items.first?.entry.source == .settings)
        #expect(store.chart.isEmpty)
        #expect(await harness.checks.all().isEmpty)
        #expect(await harness.requests.totalBytes() == 0)
        #expect(await harness.log.entries().map(\.message) == ["Cleared the logs"])
    }

    @Test("LOG-04 groups the chart by hour")
    func groupsTheChartByHour() async throws {
        let harness = try Harness()
        // 12:30 now: 12:25 and 12:05 fall in the 12:00 hour, 11:59 in the 11:00 hour; 25 hours ago is out.
        await harness.check(.jenkins, seconds: 1.0, minutesAgo: 5)
        await harness.check(.jenkins, seconds: 2.0, failed: 1, minutesAgo: 25)
        await harness.check(.gitlab, seconds: 0.5, minutesAgo: 20)
        await harness.check(.jenkins, seconds: 4.0, minutesAgo: 31)
        await harness.check(.jenkins, seconds: 9.0, minutesAgo: 25 * 60)
        let store = harness.store()
        await store.reload()

        let noon = Date(timeIntervalSince1970: 1_793_188_800)
        let eleven = noon.addingTimeInterval(-3600)
        #expect(store.chart.hours == [
            CheckTimesChart.Hour(start: eleven, source: .jenkins, checks: 1, averageSeconds: 4.0, failedRequests: 0),
            CheckTimesChart.Hour(start: noon, source: .jenkins, checks: 2, averageSeconds: 1.5, failedRequests: 1),
            CheckTimesChart.Hour(start: noon, source: .gitlab, checks: 1, averageSeconds: 0.5, failedRequests: 0),
        ])
        #expect(store.chart.since == Self.now.addingTimeInterval(-86400))
        #expect(store.chart.sources == [.jenkins, .gitlab])
        #expect(!store.chart.isEmpty)
    }

    @Test("LOG-04 groups the chart by the hours of the local time")
    func groupsByLocalHours() {
        // In India the hours start at :30 UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let checks = [
            CheckTime(time: Self.now.addingTimeInterval(-60), source: .jenkins, seconds: 1, requests: 1, failed: 0),
            CheckTime(time: Self.now.addingTimeInterval(60), source: .jenkins, seconds: 3, requests: 1, failed: 0),
        ]
        let chart = CheckTimesChart(checks: checks, now: Self.now.addingTimeInterval(120), calendar: calendar)

        #expect(chart.hours.map(\.start) == [Self.now.addingTimeInterval(-3600), Self.now])
    }

    @Test("LOG-04 averages and failed counts per source")
    func averagesAndFailedCounts() async throws {
        let harness = try Harness()
        await harness.check(.jenkins, seconds: 1.0, minutesAgo: 5)
        await harness.check(.jenkins, seconds: 2.0, failed: 1, minutesAgo: 25)
        await harness.check(.jenkins, seconds: 6.0, failed: 2, minutesAgo: 95)
        await harness.check(.gitlab, seconds: 0.25, minutesAgo: 20)
        let store = harness.store()
        await store.reload()

        // The 24 hours weigh each check alike: (1 + 2 + 6) / 3.
        let jenkins = store.chart.summary(of: .jenkins)
        #expect(jenkins.checks == 3 && jenkins.averageSeconds == 3.0 && jenkins.failedRequests == 3)
        #expect(jenkins.averageText == "avg 3.0 s")
        #expect(jenkins.failedText == "3 failed")
        let gitLab = store.chart.summary(of: .gitlab)
        #expect(gitLab.averageText == "avg 0.25 s")
        #expect(gitLab.failedText == nil)
        // The hour under the pointer.
        let noon = Date(timeIntervalSince1970: 1_793_188_800)
        let hour = store.chart.summary(of: .jenkins, hour: noon)
        #expect(hour.averageSeconds == 1.5 && hour.failedText == "1 failed")
        let empty = store.chart.summary(of: .alerts)
        #expect(empty.averageText == "–" && empty.failedText == nil)
        #expect(CheckTimesChart(checks: [], now: Self.now).isEmpty)
        #expect(CheckTimesChart.emptyMessage == "No checks in the last 24 hours yet.")
        #expect(CheckTimesChart.duration(12.4) == "12 s")
    }

    @Test("LOG-04 shows at most 1000 rows")
    func showsAtMost1000Rows() async throws {
        let harness = try Harness()
        for index in 0..<1005 {
            await harness.log.append(ActivityEntry(
                time: Self.now.addingTimeInterval(Double(index - 1005)), level: index.isMultiple(of: 2) ? .debug : .info,
                source: .jenkins, message: "entry \(index)"))
        }
        let store = harness.store()
        await store.reload()

        #expect(store.matchingItems.count == 1005)
        #expect(store.shownItems.count == 1000)
        #expect(store.shownItems.first?.entry.message == "entry 1004")
        #expect(store.truncationMessage == "The newest 1000 of 1005 entries: search or filter to see the older ones.")
        #expect(store.days.flatMap(\.items).count == 1000)
        store.levelFilter = .events
        #expect(store.truncationMessage == nil)
        #expect(store.shownItems.count == 502)
    }

    @Test("LOG-04 groups the list by day, newest first")
    func groupsByDay() async throws {
        let harness = try Harness()
        await harness.add(.info, .app, "three days ago", minutesAgo: 3 * 24 * 60)
        await harness.add(.info, .app, "yesterday", minutesAgo: 24 * 60)
        await harness.add(.info, .app, "this morning", minutesAgo: 6 * 60)
        await harness.add(.info, .app, "now")
        let store = harness.store()
        await store.reload()

        let days = store.days
        #expect(days.map { $0.items.map(\.entry.message) } == [["now", "this morning"], ["yesterday"], ["three days ago"]])
        #expect(days.prefix(2).map(\.title) == ["Today", "Yesterday"])
        #expect(days[2].title.contains("25"))
        #expect(store.oldestEntryTime == Self.now.addingTimeInterval(-3 * 86400))
        #expect(store.footerText.hasPrefix("Since "))
        #expect(store.footerText.hasSuffix(": the oldest entries go first"))
        #expect(store.maxBytes == 16_252_928)
    }

    @Test("LOG-04 copy as curl from the details leaves the token out")
    func curlFromTheDetails() async throws {
        let harness = try Harness()
        let stub = StubTransport()
        stub.answer(path: "/job/project/api/json", headers: ["Set-Cookie": "JSESSIONID=abc", "X-Jenkins": "2.500"], body: #"{"jobs":[]}"#)
        stub.answer(operation: "CurrentUser", body: #"{"data":{"currentUser":{"username":"alex.doe"}}}"#)
        let recorder = RequestRecorder(wrapping: stub, log: harness.log, capture: harness.requests, clock: harness.clock)
        _ = try await recorder.send(HTTPRequest(
            url: URL(string: "https://jenkins.example.com/job/project/api/json?tree=jobs%5Bname%5D")!,
            headers: ["Authorization": "Basic \(Self.jenkinsToken)"], timeout: .seconds(20)))
        let gitLab = GitLabClient(transport: recorder, gitLab: URL(string: "https://gitlab.example.com")!, token: Self.gitLabToken)
        _ = try await gitLab.send(.currentUser)
        let store = harness.store()
        await store.reload()

        let jenkins = try #require(await store.details(of: store.items[1]).request)
        #expect(jenkins.curlCommand == #"curl -H "Authorization: Basic $JENKINS_MCP_BASIC_AUTH" 'https://jenkins.example.com/job/project/api/json?tree=jobs%5Bname%5D'"#)
        #expect(jenkins.requestText == "GET https://jenkins.example.com/job/project/api/json?tree=jobs[name]\nAuthorization: Basic (not kept)")
        #expect(jenkins.responseText == "HTTP 200\n\n{\n  \"jobs\": []\n}")
        #expect(jenkins.headersText == "X-Jenkins: 2.500")
        let graphQL = try #require(await store.details(of: store.items[0]).request)
        #expect(graphQL.curlCommand.contains("$GITLAB_TOKEN"))
        #expect(graphQL.requestText.contains("query CurrentUser"))
        for text in [jenkins.curlCommand, jenkins.requestText, jenkins.responseText, jenkins.headersText, graphQL.curlCommand,
                     graphQL.requestText, graphQL.responseText, graphQL.headersText, store.copyText()] {
            #expect(!text.contains(Self.jenkinsToken) && !text.contains(Self.gitLabToken) && !text.contains("JSESSIONID"))
        }
    }

    @Test("LOG-02 the details tell when a request is gone, and show an entry without one whole")
    func detailsOfEntries() async throws {
        let harness = try Harness()
        await harness.add(.info, .settings, "Cleared the logs", minutesAgo: 1)
        await harness.log.append(ActivityEntry(
            time: Self.now, level: .warning, source: .jenkins, message: "GET /api/json: HTTP 500 in 0.20s",
            outcome: .failed("500"), requestID: "20261028-123000-000-deadbeef"))
        let store = harness.store()
        await store.reload()

        let gone = await store.details(of: store.items[0])
        #expect(gone.requestIsGone && gone.request == nil)
        #expect(ActivityDetails.goneMessage == "The request and its response are gone: only the newest requests keep theirs.")
        let plain = await store.details(of: store.items[1])
        #expect(!plain.requestIsGone)
        #expect(plain.item.fullText(in: .gmt) == "2026-10-28 12:29:00\n\ninfo · Settings\n\nCleared the logs")
    }

    @Test("LOG-02 the response tells why no answer came and what was cut")
    func responseTexts() {
        let url = URL(string: "https://jenkins.example.com/api/json")!
        #expect(RequestDetails(record: RequestRecord(method: "GET", url: url, error: "no answer within 20 seconds", seconds: 20))
            .responseText == "No answer within 20 seconds")
        #expect(RequestDetails(record: RequestRecord(method: "GET", url: url, error: "unknown host (VPN?)", seconds: 0))
            .responseText == "No answer: unknown host (VPN?)")
        let cut = RequestDetails(record: RequestRecord(
            method: "GET", url: url, status: 200, seconds: 1, responseBody: Data(String(repeating: "a", count: 300).utf8),
            bodyLimit: 100))
        #expect(cut.responseText.hasPrefix("HTTP 200\n\n" + String(repeating: "a", count: 100) + "\n\n… only the first "))
        #expect(cut.responseText.hasSuffix(" are kept"))
        #expect(RequestDetails(record: RequestRecord(method: "GET", url: url, error: "unknown host (VPN?)", seconds: 0))
            .headersText == "No headers: no answer.")
    }

    @Test("LOG-04 follows the log while shown")
    func followsTheLog() async throws {
        let harness = try Harness()
        let store = harness.store()
        #expect(store.emptyState == nil)

        store.startFollowing(every: .seconds(2))
        await harness.clock.waitForSleepers()
        #expect(store.isLoaded)
        #expect(store.emptyState == .noActivity)

        await harness.add(.info, .app, "Check now")
        harness.clock.advance(by: .seconds(2))
        await harness.clock.waitForSleepers()
        #expect(store.items.map(\.entry.message) == ["Check now"])
        let id = try #require(store.items.first?.id)

        // A newer entry keeps the id of the older one, so the selection stays.
        await harness.add(.info, .app, "Hid MR-1 #7")
        store.stopFollowing()
        await store.reload()
        #expect(store.items.map(\.entry.message) == ["Hid MR-1 #7", "Check now"])
        #expect(store.items.last?.id == id)
    }
}

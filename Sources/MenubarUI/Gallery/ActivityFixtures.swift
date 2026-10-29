#if DEBUG
import Foundation
import MenubarCore

/// The logs, check times and kept requests of `docs/design/activity.md`, States. Made up throughout: `jdoe`, the job
/// `https://jenkins.example.com/job/project`, `group/subgroup/project` on `gitlab.example.com`, the panel's titles.
/// Requests keep only "(not kept)" of their authorization. Now is 10:42 today (``Fixtures/now``).
struct ActivityFixtures {
    /// One state's log as the section shows it: the content's values and every entry, for the detail's lookup.
    struct Log {
        var data: ActivityContentData
        var items: [ActivityItem]

        /// the id of the entry whose message is this one, the newest such
        func id(of message: String) -> ActivityItem.ID {
            items.first { $0.entry.message == message }?.id ?? ""
        }
    }

    /// An entry without its time: what the generated parts of a log are made of.
    struct Line {
        var level: ActivityEntry.Level
        var source: ActivityEntry.Source
        var message: String
        var detail: String?
        var outcome: ActivityEntry.Outcome?
        var hasRequest = false
    }

    let now: Date
    let calendar = Calendar.current
    /// LOG-03's caps together: 5 log files of 1 MB, 512 KB of check times and 10 MB of requests
    private let maxBytes = 1_048_576 * 5 + 524_288 + 10_485_760

    init(_ fixtures: Fixtures) {
        now = fixtures.now
    }

    // MARK: - Times

    /// today at the given time
    func today(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        day(0, hour, minute, second)
    }

    /// so many days before today, at the given time
    func day(_ daysAgo: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return start.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    // MARK: - Entries

    func entry(
        _ time: Date, _ level: ActivityEntry.Level, _ source: ActivityEntry.Source, _ message: String,
        detail: String? = nil, outcome: ActivityEntry.Outcome? = nil, request: String? = nil
    ) -> ActivityEntry {
        ActivityEntry(time: time, level: level, source: source, message: message, detail: detail, outcome: outcome, requestID: request)
    }

    /// The top of `activity.table`'s log, as the spec's layout: the timeout and the problem at 10:41:07.
    var newestTwo: [ActivityEntry] {
        [
            entry(today(10, 41, 7), .warning, .jenkins, Self.timeoutMessage, outcome: .failed("TIMEOUT"), request: "r-timeout"),
            entry(today(10, 41, 7).addingTimeInterval(-0.2), .error, .jenkins, Self.unreachable, outcome: .failed("PROBLEM")),
        ]
    }

    /// The minutes before: every level and source, warnings and errors among them, newest first.
    var recent: [ActivityEntry] {
        [
            entry(today(10, 40, 1), .debug, .gitlab, "Checked GitLab: 2 requests, 0.82s together", outcome: .ok("OK")),
            entry(today(10, 40, 1).addingTimeInterval(-0.4), .debug, .gitlab, "POST WorkItems in 0.43s", outcome: .ok("200"), request: "r-workitems"),
            entry(today(10, 40, 0), .debug, .gitlab, "POST MergeRequests in 0.39s", outcome: .ok("200"), request: "r-graphql"),
            entry(today(10, 39, 58), .info, .settings, "alertStyle: window → banner"),
            entry(today(10, 39, 12), .info, .alerts, "❌ !16 #3 FAILURE (alert)", detail: "Add a retry to the export job · 12 min",
                  outcome: .failed("FAILURE")),
            entry(today(10, 39, 12).addingTimeInterval(-0.1), .info, .jenkins, "!16 #3 finished", detail: "Add a retry to the export job",
                  outcome: .failed("FAILURE")),
            entry(today(10, 39, 5), .debug, .jenkins, "Checked Jenkins: 3 requests, 0.54s together", outcome: .ok("OK")),
            entry(today(10, 39, 5).addingTimeInterval(-0.1), .debug, .jenkins, "GET /job/MR-16/api/json in 0.17s", outcome: .ok("200"), request: "r-mr16"),
            entry(today(10, 39, 4).addingTimeInterval(0.8), .debug, .jenkins, Self.jsonMessage, outcome: .ok("200"), request: "r-json"),
            entry(today(10, 39, 4), .debug, .jenkins, "GET /api/json in 0.19s", outcome: .ok("200"), request: "r-jobs"),
            entry(today(10, 38, 40), .info, .app, "Check now"),
            entry(today(10, 37, 2), .info, .jenkins, "!12 #7 started: Fix the login redirect after a timeout", outcome: .running("RUNNING")),
            entry(today(10, 36, 30), .warning, .gitlab, Self.offlineMessage, outcome: .failed("OFFLINE"), request: "r-offline"),
        ]
    }

    static let timeoutMessage = "GET /job/MR-12/api/json: no answer within 20 seconds"
    static let unreachable = "Jenkins unreachable (VPN?)"
    static let jsonMessage = "GET /job/MR-12/api/json in 0.18s"
    static let offlineMessage = "POST WorkItems: unknown host (VPN?)"
    static let httpErrorMessage = "GET /job/MR-12/api/json: HTTP 500 in 0.20s"

    // MARK: - Generated parts

    private static let jenkinsDebug = [
        Line(level: .debug, source: .jenkins, message: "GET /job/MR-12/api/json in 0.18s", outcome: .ok("200"), hasRequest: true),
        Line(level: .debug, source: .jenkins, message: "GET /job/MR-16/api/json in 0.17s", outcome: .ok("200"), hasRequest: true),
        Line(level: .debug, source: .jenkins, message: "GET /api/json in 0.19s", outcome: .ok("200"), hasRequest: true),
        Line(level: .debug, source: .jenkins, message: "Checked Jenkins: 3 requests, 0.54s together", outcome: .ok("OK")),
        Line(level: .debug, source: .jenkins, message: "Found 2 MR jobs of jdoe", detail: "MR-12 MR-16"),
    ]
    private static let gitLabDebug = [
        Line(level: .debug, source: .gitlab, message: "POST MergeRequests in 0.39s", outcome: .ok("200"), hasRequest: true),
        Line(level: .debug, source: .gitlab, message: "POST WorkItems in 0.43s", outcome: .ok("200"), hasRequest: true),
        Line(level: .debug, source: .gitlab, message: "Checked GitLab: 2 requests, 0.82s together", outcome: .ok("OK")),
    ]
    private static let jenkinsProblems = [
        Line(level: .warning, source: .jenkins, message: httpErrorMessage, outcome: .failed("500"), hasRequest: true),
        Line(level: .error, source: .jenkins, message: unreachable, outcome: .failed("PROBLEM")),
        Line(level: .warning, source: .jenkins, message: "Jenkins answers slowly: the job list took longer than 10 seconds",
             outcome: .warning("SLOW")),
    ]
    private static let gitLabProblems = [
        Line(level: .warning, source: .gitlab, message: "POST WorkItems: HTTP 502 in 0.31s", outcome: .failed("502"), hasRequest: true),
        Line(level: .error, source: .gitlab, message: "GitLab rejected the token", outcome: .failed("PROBLEM")),
    ]
    private static let jenkinsInfo = [
        Line(level: .info, source: .jenkins, message: "!14 #2 started: Show the merge status in the tooltip", outcome: .running("RUNNING")),
        Line(level: .info, source: .jenkins, message: "!14 #2 finished", detail: "Show the merge status in the tooltip",
             outcome: .ok("SUCCESS")),
        Line(level: .info, source: .jenkins, message: "Resolved: Jenkins unreachable (VPN?)", outcome: .ok("RESOLVED")),
        Line(level: .info, source: .jenkins, message: "Watching !2", detail: "Retry the upload when the connection drops"),
    ]
    private static let gitLabInfo = [
        Line(level: .info, source: .gitlab, message: "Signed in as jdoe", outcome: .ok("OK")),
    ]
    private static let otherInfo = [
        Line(level: .info, source: .alerts, message: "✅ !14 #2 SUCCESS (alert)", detail: "Show the merge status in the tooltip · 21 min",
             outcome: .ok("SUCCESS")),
        Line(level: .info, source: .settings, message: "checkInterval: 1 min → 2 min"),
        Line(level: .info, source: .app, message: "Hid !11 #9"),
        Line(level: .info, source: .alerts, message: "❌ !16 #2 FAILURE (banner)", detail: "Add a retry to the export job · 14 min",
             outcome: .failed("FAILURE")),
        Line(level: .info, source: .app, message: "Showed the hidden builds again"),
        Line(level: .info, source: .settings, message: "stageAlerts: off → on"),
        Line(level: .info, source: .jenkins, message: "!12 #6 started: Fix the login redirect after a timeout", outcome: .running("RUNNING")),
    ]

    /// Lines drawn from pools, so many from each, spread through each other in a fixed order.
    ///
    /// - Parameter counts: each pool with the number of lines it gives
    /// - Returns: the lines
    func lines(_ counts: [([Line], Int)]) -> [Line] {
        var all: [(key: Int, line: Line)] = []
        var seed: UInt32 = 7
        for (pool, count) in counts {
            for index in 0..<count {
                // A small linear congruential generator: the same order at every run.
                seed = seed &* 1_103_515_245 &+ 12345
                all.append((Int(seed >> 8), pool[index % pool.count]))
            }
        }
        return all.sorted { $0.key < $1.key }.map(\.line)
    }

    /// Gives lines their times, newest first, one every `step` seconds before `start`.
    func entries(_ lines: [Line], before start: Date, every step: TimeInterval) -> [ActivityEntry] {
        lines.enumerated().map { index, line in
            entry(
                start.addingTimeInterval(-step * Double(index + 1)), line.level, line.source, line.message, detail: line.detail,
                outcome: line.outcome, request: line.hasRequest ? "r-gen-\(index)" : nil)
        }
    }

    /// The 167 entries of today before `recent`: with it and `newestTwo`, 182 in all, 41 of them events, 12 problems
    /// and 64 GitLab's (the counts `activity.md` names).
    var earlierToday: [ActivityEntry] {
        entries(
            lines([
                (Self.jenkinsDebug, 80), (Self.gitLabDebug, 54), (Self.jenkinsProblems, 6), (Self.gitLabProblems, 3),
                (Self.jenkinsInfo, 9), (Self.gitLabInfo, 3), (Self.otherInfo, 12),
            ]),
            before: today(10, 35), every: 30)
    }

    /// `activity.table`'s 182 entries, with other entries in place of the newest two when given.
    func typicalEntries(top: [ActivityEntry]? = nil) -> [ActivityEntry] {
        (top ?? newestTwo) + recent + earlierToday
    }

    /// A long log over several days, mostly requests and checks: `count` entries, one every `step` seconds.
    func longLog(_ count: Int, every step: TimeInterval) -> [ActivityEntry] {
        let share = count / 20
        return entries(
            lines([
                (Self.jenkinsDebug, share * 9), (Self.gitLabDebug, share * 6), (Self.jenkinsProblems, share / 2),
                (Self.gitLabProblems, share / 2), (Self.jenkinsInfo, share), (Self.gitLabInfo, share / 2),
                (Self.otherInfo, count - share * 9 - share * 6 - share / 2 * 3 - share),
            ]),
            before: today(10, 41), every: step)
    }

    // MARK: - Check times

    /// Jenkins every 5 minutes for 24 hours, around 0.9 s; GitLab every 10 minutes while the window was open,
    /// yesterday 13:00–18:00 and today since 10:00.
    func checks(failedHours: [Int: Int] = [:], hour9Seconds: Double? = nil) -> [CheckTime] {
        let pattern = [0.6, 0.9, 1.2, 0.9, 0.7, 1.1]
        var checks: [CheckTime] = []
        for index in 0..<288 {
            let time = now.addingTimeInterval(-Double(index) * 300 - 30)
            let hour = calendar.component(.hour, from: time)
            let isToday = calendar.isDate(time, inSameDayAs: now)
            var seconds = pattern[index % pattern.count]
            if isToday, hour == 9, let hour9Seconds {
                seconds = hour9Seconds
            }
            // One failed request in the first check of a failed hour, the rest in the second.
            let minute = calendar.component(.minute, from: time)
            var failed = 0
            if isToday, let count = failedHours[hour], minute < 10 {
                failed = minute < 5 ? 1 : count - 1
            }
            checks.append(CheckTime(time: time, source: .jenkins, seconds: seconds, requests: 3, failed: failed))
        }
        for index in 0..<144 {
            let time = now.addingTimeInterval(-Double(index) * 600 - 60)
            let hour = calendar.component(.hour, from: time)
            let isToday = calendar.isDate(time, inSameDayAs: now)
            guard (isToday && hour >= 10) || (!isToday && (13..<18).contains(hour)) else { continue }
            checks.append(CheckTime(time: time, source: .gitlab, seconds: [0.8, 1.3, 0.9][index % 3], requests: 2, failed: 0))
        }
        return checks
    }

    /// Both sources every hour for 24 hours.
    var hourlyChecks: [CheckTime] {
        (0..<24).flatMap { index in
            let time = now.addingTimeInterval(-Double(index) * 3600 - 120)
            return [
                CheckTime(time: time, source: .jenkins, seconds: [0.7, 1.0, 0.8][index % 3], requests: 3, failed: 0),
                CheckTime(time: time.addingTimeInterval(30), source: .gitlab, seconds: [1.1, 0.9][index % 2], requests: 2, failed: 0),
            ]
        }
    }

    // MARK: - The section's values

    /// Builds a state's values as the store would: the filters and the search, the days, the cap, the empty state, the
    /// subtitle and the bottom bar.
    ///
    /// - Parameters:
    ///   - entries: the log, newest first
    ///   - checks: the check times
    ///   - level: the level filter
    ///   - source: the source filter
    ///   - search: the window's search
    ///   - isLoaded: false before the first read
    ///   - bytes: the size of the files together
    @MainActor
    func log(
        _ entries: [ActivityEntry], checks: [CheckTime] = [], level: ActivityLevelFilter = .everything,
        source: ActivityEntry.Source? = nil, search: String = "", isLoaded: Bool = true, bytes: Int = 1_240_000
    ) -> Log {
        // The store's ids: the time in milliseconds and the place among that millisecond's entries, oldest first.
        var seen: [Int64: Int] = [:]
        let oldestFirst = entries.reversed().enumerated().map { position, entry in
            let milliseconds = Int64((entry.time.timeIntervalSince1970 * 1000).rounded())
            let ordinal = seen[milliseconds, default: 0]
            seen[milliseconds] = ordinal + 1
            return ActivityItem(id: "\(milliseconds)-\(ordinal)", entry: entry, position: position)
        }
        let items = Array(oldestFirst.reversed())
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = items.filter { item in
            let entry = item.entry
            let text = [entry.message, entry.detail ?? "", entry.source.displayName, entry.outcome?.label ?? ""]
                .joined(separator: "\n").lowercased()
            return level.includes(entry.level) && (source == nil || entry.source == source)
                && (words.isEmpty || text.contains(words))
        }
        var emptyState: ActivityEmptyState?
        if isLoaded, matching.isEmpty {
            emptyState = items.isEmpty ? .noActivity : words.isEmpty ? .nothingToShow : .noSearchResults(words)
        }
        var footer: String?
        if let oldest = items.last?.entry.time {
            let size = "\(Self.size(bytes)) of at most \(Self.size(maxBytes)): the oldest entries go first"
            footer = "Since \(oldest.formatted(.dateTime.weekday().day().month().hour().minute())) · \(size)"
        }
        let data = ActivityContentData(
            isLoaded: isLoaded, days: isLoaded ? days(of: Array(matching.prefix(ActivityStore.shownAtMost))) : [],
            emptyState: emptyState, chart: CheckTimesChart(checks: isLoaded ? checks : [], now: now, calendar: calendar),
            matchingCount: matching.count, totalCount: items.count,
            isNarrowed: ActivityContentData.isNarrowed(level: level, source: source, search: search),
            truncationMessage: isLoaded && matching.count > ActivityStore.shownAtMost
                ? "The newest \(ActivityStore.shownAtMost) of \(matching.count) entries: search or filter to see the older ones."
                : nil,
            footerText: isLoaded ? footer : nil)
        return Log(data: data, items: isLoaded ? items : [])
    }

    /// The items by day, as `ActivityDay` groups them: "Today", "Yesterday", then the date.
    private func days(of items: [ActivityItem]) -> [ActivityDay] {
        var groups: [(day: Date, items: [ActivityItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.entry.time)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups.map { group in
            let title: String
            if calendar.isDate(group.day, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                calendar.isDate(group.day, inSameDayAs: yesterday)
            {
                title = "Yesterday"
            } else {
                title = group.day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            }
            return ActivityDay(day: group.day, title: title, items: group.items)
        }
    }

    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    // MARK: - Kept requests

    private var jenkinsHeaders: [String: String] {
        [
            "Content-Type": "application/json;charset=utf-8", "Date": "Thu, 29 Oct 2026 09:41:07 GMT",
            "Server": "Jetty(10.0.20)", "X-Jenkins": "2.462.3", "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-cache,no-store,must-revalidate",
        ]
    }

    private var jobURL: URL {
        URL(string: "https://jenkins.example.com/job/project/job/MR-12/api/json?tree=number,building,result,timestamp,duration,estimatedDuration,actions[causes[shortDescription]]")!
    }

    /// `GET /job/MR-12/api/json`: a running build, about 2 KB of JSON.
    var runningBuildRequest: RequestDetails {
        let body = #"""
            {"_class":"org.jenkinsci.plugins.workflow.job.WorkflowRun","actions":[{"_class":"hudson.model.CauseAction","causes":[{"_class":"jenkins.branch.BranchEventCause","shortDescription":"Merge request !12 updated by jdoe"}]},{"_class":"hudson.plugins.git.util.BuildData","buildsByBranchName":{"MR-12":{"_class":"hudson.plugins.git.util.Build","buildNumber":7,"buildResult":null,"marked":{"SHA1":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","branch":[{"SHA1":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","name":"MR-12"}]}}},"lastBuiltRevision":{"SHA1":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","branch":[{"SHA1":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","name":"MR-12"}]},"remoteUrls":["https://gitlab.example.com/group/subgroup/project.git"],"scmName":""},{"_class":"org.jenkinsci.plugins.workflow.libs.LibrariesAction"},{"_class":"org.jenkinsci.plugins.pipeline.modeldefinition.actions.RestartDeclarativePipelineAction","restartEnabled":false,"restartableStages":[]},{"_class":"org.jenkinsci.plugins.workflow.job.views.FlowGraphAction"}],"artifacts":[],"building":true,"description":null,"displayName":"#7","duration":0,"estimatedDuration":1500000,"executor":{"_class":"hudson.model.OneOffExecutor"},"fullDisplayName":"project » MR-12 #7","id":"7","keepLog":false,"number":7,"queueId":48213,"result":null,"timestamp":1793180227000,"url":"https://jenkins.example.com/job/project/job/MR-12/7/","changeSets":[{"_class":"hudson.plugins.git.GitChangeSetList","items":[{"_class":"hudson.plugins.git.GitChangeSet","affectedPaths":["Sources/Login/RedirectHandler.swift","Tests/Login/RedirectHandlerTests.swift"],"commitId":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","timestamp":1793179800000,"author":{"absoluteUrl":"https://jenkins.example.com/user/jdoe","fullName":"Jane Doe"},"authorEmail":"jdoe@example.com","comment":"Fix the login redirect after a timeout\n","date":"2026-10-29 10:30:00 +0100","id":"4f2a9c1e7d3b8a6f0c5e2d9b1a7f3c8e6d4b2a90","msg":"Fix the login redirect after a timeout"}],"kind":"git"}],"culprits":[{"absoluteUrl":"https://jenkins.example.com/user/jdoe","fullName":"Jane Doe"}],"inProgress":true,"nextBuild":null,"previousBuild":{"number":6,"url":"https://jenkins.example.com/job/project/job/MR-12/6/"}}
            """#
        return RequestDetails(record: RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/job/project/job/MR-12/api/json")!, authorization: .basic,
            status: 200, seconds: 0.18, responseHeaders: jenkinsHeaders, responseBody: Data(body.utf8)))
    }

    /// `POST MergeRequests`: the query, its variables and the answer.
    var mergeRequestsRequest: RequestDetails {
        let query = """
            query MergeRequests($fullPath: ID!, $username: String!) {
              project(fullPath: $fullPath) {
                mergeRequests(state: opened, first: 50, sort: UPDATED_DESC) {
                  nodes {
                    iid title webUrl draft detailedMergeStatus updatedAt
                    author { username name }
                    reviewers { nodes { username name mergeRequestInteraction { reviewState approved } } }
                    headPipeline { status }
                    diffStatsSummary { additions deletions fileCount }
                  }
                }
              }
              user(username: $username) { reviewRequestedMergeRequests(state: opened) { nodes { iid } } }
            }
            """
        let body = #"{"data":{"project":{"mergeRequests":{"nodes":[{"iid":"24","title":"Cache the label colors per project","webUrl":"https://gitlab.example.com/group/subgroup/project/-/merge_requests/24","draft":false,"detailedMergeStatus":"NOT_APPROVED","updatedAt":"2026-10-29T09:30:00Z","author":{"username":"slee","name":"Sam Lee"}}]}},"user":{"reviewRequestedMergeRequests":{"nodes":[{"iid":"24"}]}}}}"#
        return RequestDetails(record: RequestRecord(
            method: "POST", url: URL(string: "https://gitlab.example.com/api/graphql")!, authorization: .bearer,
            graphQL: GraphQLOperation(name: "MergeRequests", variables: #"{"fullPath":"group/subgroup/project","username":"jdoe"}"#),
            query: query, status: 200, seconds: 0.39,
            responseHeaders: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "max-age=0, private, must-revalidate"],
            responseBody: Data(body.utf8)))
    }

    /// `GET /api/json`: the job list, 330 KB, kept only for its first 2 KB so the note shows in the shot.
    var cutJobListRequest: RequestDetails {
        var body = #"{"_class":"com.cloudbees.hudson.plugins.folder.Folder","jobs":["#
        var number = 1
        while body.utf8.count < 330_000 {
            body += #"{"_class":"org.jenkinsci.plugins.workflow.job.WorkflowJob","name":"MR-\#(number)","color":"blue","lastBuild":{"number":\#(number % 9 + 1),"building":false,"result":"SUCCESS","timestamp":1793180227000,"duration":1260000}},"#
            number += 1
        }
        body.removeLast()
        body += "]}"
        return RequestDetails(record: RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/job/project/api/json?tree=jobs[name,color,lastBuild[number,building,result,timestamp,duration]]")!,
            authorization: .basic, status: 200, seconds: 0.62, responseHeaders: jenkinsHeaders, responseBody: Data(body.utf8),
            bodyLimit: 2048))
    }

    /// `GET /job/MR-12/api/json: HTTP 500`: Jetty's short HTML page, as it came.
    var httpErrorRequest: RequestDetails {
        let body = """
            <html>
            <head>
            <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
            <title>Error 500 Server Error</title>
            </head>
            <body><h2>HTTP ERROR 500 Server Error</h2>
            <table>
            <tr><th>URI:</th><td>/job/project/job/MR-12/api/json</td></tr>
            <tr><th>STATUS:</th><td>500</td></tr>
            <tr><th>MESSAGE:</th><td>Server Error</td></tr>
            </table>
            </body>
            </html>
            """
        return RequestDetails(record: RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/job/project/job/MR-12/api/json")!, authorization: .basic,
            status: 500, seconds: 0.20,
            responseHeaders: ["Content-Type": "text/html;charset=utf-8", "Server": "Jetty(10.0.20)", "X-Jenkins": "2.462.3"],
            responseBody: Data(body.utf8)))
    }

    /// `GET /job/MR-12/api/json`: no answer within 20 seconds.
    var timeoutRequest: RequestDetails {
        RequestDetails(record: RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/job/project/job/MR-12/api/json")!, authorization: .basic,
            error: "no answer within 20 seconds", seconds: 20))
    }

    /// `POST WorkItems`: unknown host.
    var offlineRequest: RequestDetails {
        RequestDetails(record: RequestRecord(
            method: "POST", url: URL(string: "https://gitlab.example.com/api/graphql")!, authorization: .bearer,
            graphQL: GraphQLOperation(name: "WorkItems", variables: #"{"fullPath":"group/subgroup/project","first":45}"#),
            query: "query WorkItems($fullPath: ID!, $first: Int) {\n  project(fullPath: $fullPath) { workItems(first: $first) { nodes { iid title } } }\n}",
            error: "unknown host (VPN?)", seconds: 0.01))
    }

    /// A Jenkins request with a 300-character URL, for `activity.long-messages`.
    var longURLRequest: RequestDetails {
        let url = URL(string: "https://jenkins.example.com/job/project/job/MR-12/api/json?tree=number,building,result,timestamp,duration,estimatedDuration,description,displayName,fullDisplayName,actions[causes[shortDescription,userId,userName],parameters[name,value]],changeSets[items[commitId,msg,author[fullName],affectedPaths]],culprits[fullName]")!
        return RequestDetails(record: RequestRecord(
            method: "GET", url: url, authorization: .basic, status: 200, seconds: 0.21, responseHeaders: jenkinsHeaders,
            responseBody: Data(#"{"number":7,"building":true,"result":null}"#.utf8)))
    }

    /// a 500-character detail
    static let longDetail = String(repeating: "The export job failed while writing the quarterly report to the shared folder; ", count: 7)
        .prefix(ActivityEntry.maxDetailLength).description

    /// a long GraphQL error, as GitLab words them
    static let longGraphQLError = "POST WorkItems: GitLab answered with an error: Field 'workItems' doesn't accept argument "
        + "'labelName' on type 'Project'; did you mean 'labelNames'? The query asked for 45 items of the type ISSUE, sorted "
        + "by UPDATED_DESC, with the labels workflow::committed and slot::Q1"
}

extension Fixtures {
    /// the logs and requests of the Activity section
    var activity: ActivityFixtures {
        ActivityFixtures(self)
    }
}
#endif

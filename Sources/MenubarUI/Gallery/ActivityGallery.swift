#if DEBUG
import MenubarCore
import SwiftUI

/// The main window with Activity selected, as the gallery shows it: lane R's shell from fixtures, the Activity section,
/// its inspector and its toolbar items from plain values, no actions. The hovered hour, the chart's expansion, the
/// inspector, the part and the confirmation are passed in, since people set them for real.
struct ActivityGalleryView: View {
    let fixtures: Fixtures
    let log: ActivityFixtures.Log
    var size = CGSize(width: 1120, height: 720)
    var selection: Set<ActivityItem.ID> = []
    /// whether the inspector shows the selection's details
    var inspectorShown = false
    /// the one selected entry's kept request; nil for none, or one that is gone
    var request: RequestDetails?
    /// whether the inspector is still reading the request
    var isReading = false
    var search = ""
    var level = ActivityLevelFilter.everything
    var source: ActivityEntry.Source?
    var chartExpanded = true
    var hoveredTime: Date?
    var tab = RequestDetailTab.response
    var isConfirmingClear = false

    var body: some View {
        let detail = ActivitySelection.detail(of: selection, in: log.items)
        MainWindowShell(
            model: MainWindowShellModel(fixtures.mainWindow().panel, section: .activity, activitySubtitle: log.data.subtitle),
            section: .constant(.activity), searchText: .constant(search), columnVisibility: .constant(.all), actions: .none
        ) {
            ActivityContent(
                data: log.data, selection: .constant(selection), level: .constant(level), source: .constant(source),
                chartExpanded: .constant(chartExpanded), hoveredTime: .constant(hoveredTime),
                isInspectorShown: .constant(inspectorShown), isConfirmingClear: .constant(isConfirmingClear), actions: .none
            ) {
                ActivityDetailPane(
                    detail: detail, details: details(of: detail), tab: .constant(tab),
                    isListEmpty: !log.data.isLoaded || log.data.emptyState != nil, now: fixtures.now, copyCurl: { _ in })
            }
        } detail: {
            EmptyView()
        } sectionToolbar: {
            ActivityToolbarItems(isInspectorShown: .constant(inspectorShown), showInFinder: {}, clear: {})
        }
        .frame(width: size.width, height: size.height)
        .environment(\.panelSpinnerDelay, .zero)
    }

    private func details(of detail: ActivitySelection.Detail) -> ActivityDetails? {
        guard case .one(let item) = detail, !isReading else { return nil }
        return ActivityDetails(item: item, request: request)
    }
}

extension GalleryCatalog {
    /// One entry per state of `docs/design/activity.md`.
    static var activityEntries: [GalleryEntry] {
        let window = CGSize(width: 1120, height: 720)
        return [
            GalleryEntry(screen: "activity", state: "table", size: window) { f in
                ActivityGalleryView(fixtures: f, log: f.activity.log(f.activity.typicalEntries(), checks: f.activity.checks()))
            },
            GalleryEntry(screen: "activity", state: "day-groups", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.threeDays, checks: a.checks()))
            },
            GalleryEntry(screen: "activity", state: "filter-events", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(), level: .events), level: .events)
            },
            GalleryEntry(screen: "activity", state: "filter-problems", size: window) { f in
                let a = f.activity
                ActivityGalleryView(
                    fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(), level: .problems), level: .problems)
            },
            GalleryEntry(screen: "activity", state: "filter-source", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(), source: .gitlab), source: .gitlab)
            },
            GalleryEntry(screen: "activity", state: "search-results", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.timeoutSearchLog, checks: a.checks(), search: "timeout"), search: "timeout")
            },
            GalleryEntry(screen: "activity", state: "search-no-results", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(), search: "zzz"), search: "zzz")
            },
            GalleryEntry(screen: "activity", state: "row-cap", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.longLog(4210, every: 120), checks: a.checks(), bytes: 6_900_000))
            },
            GalleryEntry(screen: "activity", state: "request-json", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.json]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.jsonMessage)], inspectorShown: true,
                    request: a.runningBuildRequest)
            },
            GalleryEntry(screen: "activity", state: "request-graphql", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.graphQL]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: "POST MergeRequests in 0.39s")], inspectorShown: true,
                    request: a.mergeRequestsRequest, tab: .request)
            },
            GalleryEntry(screen: "activity", state: "request-headers", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.json]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.jsonMessage)], inspectorShown: true,
                    request: a.runningBuildRequest, tab: .headers)
            },
            GalleryEntry(screen: "activity", state: "request-cut", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.jobList]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: "GET /api/json in 0.62s")], inspectorShown: true,
                    request: a.cutJobListRequest)
            },
            GalleryEntry(screen: "activity", state: "request-http-error", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.httpError]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.httpErrorMessage)], inspectorShown: true,
                    request: a.httpErrorRequest)
            },
            GalleryEntry(screen: "activity", state: "request-timeout", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.timeoutMessage)], inspectorShown: true,
                    request: a.timeoutRequest)
            },
            GalleryEntry(screen: "activity", state: "request-offline", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(top: [a.offline]), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.offlineMessage)], inspectorShown: true,
                    request: a.offlineRequest)
            },
            GalleryEntry(screen: "activity", state: "request-gone", size: window) { f in
                let a = f.activity
                let log = a.log(a.threeDays, checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.goneMessage)], inspectorShown: true)
            },
            GalleryEntry(screen: "activity", state: "entry-no-request", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: "!16 #3 finished")], inspectorShown: true)
            },
            GalleryEntry(screen: "activity", state: "problem-entry", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: [log.id(of: ActivityFixtures.unreachable)], inspectorShown: true)
            },
            GalleryEntry(screen: "activity", state: "multiple-selection", size: window) { f in
                let a = f.activity
                let log = a.log(a.typicalEntries(), checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, selection: Set(log.items[2..<5].map(\.id)), inspectorShown: true)
            },
            GalleryEntry(screen: "activity", state: "chart-failed", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(failedHours: [3: 2, 6: 1, 8: 1])))
            },
            GalleryEntry(screen: "activity", state: "chart-hover", size: window) { f in
                let a = f.activity
                ActivityGalleryView(
                    fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(hour9Seconds: 1.4)), hoveredTime: a.today(9, 30))
            },
            GalleryEntry(screen: "activity", state: "chart-collapsed", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks()), chartExpanded: false)
            },
            GalleryEntry(screen: "activity", state: "chart-empty", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.untilYesterday))
            },
            GalleryEntry(screen: "activity", state: "empty", size: window) { f in
                ActivityGalleryView(fixtures: f, log: f.activity.log([]))
            },
            GalleryEntry(screen: "activity", state: "nothing-to-show", size: window) { f in
                let a = f.activity
                ActivityGalleryView(
                    fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks(), level: .problems, source: .alerts),
                    level: .problems, source: .alerts)
            },
            GalleryEntry(screen: "activity", state: "clear-confirmation", size: window) { f in
                let a = f.activity
                ActivityGalleryView(fixtures: f, log: a.log(a.typicalEntries(), checks: a.checks()), isConfirmingClear: true)
            },
            GalleryEntry(screen: "activity", state: "cleared", size: window) { f in
                let a = f.activity
                ActivityGalleryView(
                    fixtures: f, log: a.log([a.entry(f.now, .info, .settings, ActivityStore.clearedMessage)], bytes: 160))
            },
            GalleryEntry(screen: "activity", state: "loading", size: window) { f in
                ActivityGalleryView(fixtures: f, log: f.activity.log([], isLoaded: false))
            },
            GalleryEntry(screen: "activity", state: "many-items", size: window) { f in
                let a = f.activity
                let log = a.log(a.longLog(950, every: 220), checks: a.hourlyChecks, bytes: 2_600_000)
                ActivityGalleryView(fixtures: f, log: log, selection: [log.items[470].id])
            },
            GalleryEntry(screen: "activity", state: "long-messages", size: CGSize(width: 820, height: 480)) { f in
                let a = f.activity
                let log = a.log(a.longMessages, checks: a.checks())
                ActivityGalleryView(
                    fixtures: f, log: log, size: CGSize(width: 820, height: 480),
                    selection: [log.id(of: ActivityFixtures.longURLMessage)], inspectorShown: true, request: a.longURLRequest,
                    tab: .request)
            },
        ]
    }
}

extension ActivityFixtures {
    /// the selected entry of `activity.request-json`, at 10:41:07
    var json: ActivityEntry {
        entry(today(10, 41, 7), .debug, .jenkins, Self.jsonMessage, outcome: .ok("200"), request: "r-json-top")
    }

    /// the selected entry of `activity.request-graphql`
    var graphQL: ActivityEntry {
        entry(today(10, 41, 7), .debug, .gitlab, "POST MergeRequests in 0.39s", outcome: .ok("200"), request: "r-graphql-top")
    }

    /// the selected entry of `activity.request-cut`
    var jobList: ActivityEntry {
        entry(today(10, 41, 7), .debug, .jenkins, "GET /api/json in 0.62s", outcome: .ok("200"), request: "r-jobs-top")
    }

    /// the selected entry of `activity.request-http-error`
    var httpError: ActivityEntry {
        entry(today(10, 41, 7), .warning, .jenkins, Self.httpErrorMessage, outcome: .failed("500"), request: "r-500")
    }

    /// the selected entry of `activity.request-offline`
    var offline: ActivityEntry {
        entry(today(10, 41, 7), .warning, .gitlab, Self.offlineMessage, outcome: .failed("OFFLINE"), request: "r-offline-top")
    }

    static let goneMessage = "GET /job/MR-9/api/json in 0.21s"
    static let longURLMessage = "GET /job/MR-12/api/json in 0.21s"

    /// `activity.day-groups`: three entries each on today, yesterday and the day before; the oldest request is gone.
    var threeDays: [ActivityEntry] {
        [
            entry(today(10, 41, 7), .warning, .jenkins, Self.timeoutMessage, outcome: .failed("TIMEOUT"), request: "r-timeout"),
            entry(today(10, 39, 12), .info, .jenkins, "!16 #3 finished", detail: "Add a retry to the export job",
                  outcome: .failed("FAILURE")),
            entry(today(9, 12, 3), .info, .settings, "alertStyle: window → banner"),
            entry(day(1, 18, 2, 11), .info, .alerts, "✅ !14 #2 SUCCESS (alert)", detail: "Show the merge status in the tooltip · 21 min",
                  outcome: .ok("SUCCESS")),
            entry(day(1, 17, 40, 2), .debug, .gitlab, "POST WorkItems in 0.43s", outcome: .ok("200"), request: "r-old-1"),
            entry(day(1, 9, 5, 30), .info, .app, "Check now"),
            entry(day(2, 16, 20, 45), .error, .jenkins, Self.unreachable, outcome: .failed("PROBLEM")),
            entry(day(2, 11, 3, 9), .debug, .jenkins, Self.goneMessage, outcome: .ok("200"), request: "r-dropped"),
            entry(day(2, 9, 12, 3), .info, .gitlab, "Signed in as jdoe", outcome: .ok("OK")),
        ]
    }

    /// `activity.search-results`: three entries match "timeout" (two by their outcome, one by its title), on two days.
    var timeoutSearchLog: [ActivityEntry] {
        [
            entry(today(10, 41, 7), .warning, .jenkins, Self.timeoutMessage, outcome: .failed("TIMEOUT"), request: "r-timeout"),
            entry(today(10, 40, 1), .debug, .gitlab, "Checked GitLab: 2 requests, 0.82s together", outcome: .ok("OK")),
            entry(today(10, 37, 2), .info, .jenkins, "!12 #7 started: Fix the login redirect after a timeout", outcome: .running("RUNNING")),
            entry(today(10, 30, 0), .info, .app, "Check now"),
            entry(day(1, 16, 5, 44), .warning, .gitlab, "POST WorkItems: no answer within 20 seconds", outcome: .failed("TIMEOUT"),
                  request: "r-old-timeout"),
            entry(day(1, 9, 12, 3), .info, .settings, "checkInterval: 1 min → 2 min"),
        ] + earlierToday.suffix(40).map { line in
            var line = line
            line.time = line.time.addingTimeInterval(-86_400 * 2)
            return line
        }
    }

    /// `activity.chart-empty`: the app was off for a day, so the newest entries are from yesterday morning.
    var untilYesterday: [ActivityEntry] {
        threeDays.dropFirst(5).map { $0 } + earlierToday.suffix(60).map { line in
            var line = line
            line.time = line.time.addingTimeInterval(-86_400 * 3)
            return line
        }
    }

    /// `activity.long-messages`: a long GraphQL error and 500-character details among the rows; the selected request
    /// has a 300-character URL.
    var longMessages: [ActivityEntry] {
        [
            entry(today(10, 41, 7), .debug, .jenkins, Self.longURLMessage, outcome: .ok("200"), request: "r-long-url"),
            entry(today(10, 40, 30), .warning, .gitlab, Self.longGraphQLError, detail: Self.longDetail, outcome: .failed("ERROR"),
                  request: "r-graphql-error"),
            entry(today(10, 39, 12), .info, .jenkins, "!16 #3 finished", detail: Self.longDetail, outcome: .failed("FAILURE")),
            entry(today(10, 38, 0), .info, .alerts, "❌ !16 #3 FAILURE (alert)", detail: Self.longDetail, outcome: .failed("FAILURE")),
        ] + recent
    }
}
#endif

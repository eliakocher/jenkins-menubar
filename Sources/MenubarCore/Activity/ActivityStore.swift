import Foundation
import Observation

/// The state of the Activity section: the log's entries with their filters and search, the check times chart, the
/// details of an entry, Copy and Clear (LOG-04).
///
/// It reads the Activity log, the kept requests and the check times off the main actor, and follows them while the
/// section shows (``startFollowing(every:)``). The filters are remembered in the UserDefaults it gets.
@Observable @MainActor
public final class ActivityStore {
    /// the most rows the list shows; more make it slow, and searching or filtering reaches the older ones
    public static let shownAtMost = 1000
    /// the entry Clear leaves in the log
    public static let clearedMessage = "Cleared the logs"

    /// the UserDefaults keys of the remembered filters
    enum DefaultsKey {
        static let level = "activity.levelFilter"
        static let source = "activity.sourceFilter"
    }

    @ObservationIgnored private let log: ActivityLog
    @ObservationIgnored private let requests: RequestCapture
    @ObservationIgnored private let checkTimes: CheckTimes
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// counts the reads, so that a read that started earlier but ended later doesn't win
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var following: Task<Void, Never>?
    /// the sizes of the files at the last read, to skip a read when nothing changed
    @ObservationIgnored private var signature: [Int]?

    /// whether the files were read once
    public private(set) var isLoaded = false
    /// every entry of the log, newest first
    public private(set) var items: [ActivityItem] = []
    /// the entries that pass the filters and the search, newest first
    public private(set) var matchingItems: [ActivityItem] = []
    /// every check time, oldest first
    public private(set) var checks: [CheckTime] = []
    /// the check times chart of the 24 hours before the last read
    public private(set) var chart: CheckTimesChart
    /// the bytes the log, the check times and the kept requests take together
    public private(set) var totalBytes = 0

    private var storedLevelFilter: ActivityLevelFilter
    private var storedSourceFilter: ActivityEntry.Source?
    private var storedSearchText = ""

    /// Creates the store. Nothing is read until ``reload()``.
    ///
    /// - Parameters:
    ///   - log: the Activity log
    ///   - requests: the kept requests
    ///   - checkTimes: the check times
    ///   - defaults: where the filters are remembered; nil remembers nothing
    ///   - clock: the clock of ``startFollowing(every:)``
    ///   - calendar: the calendar of the days and of the chart's hours
    ///   - now: the current time
    public init(
        log: ActivityLog,
        requests: RequestCapture,
        checkTimes: CheckTimes,
        defaults: UserDefaults? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.log = log
        self.requests = requests
        self.checkTimes = checkTimes
        self.defaults = defaults
        self.clock = clock
        self.calendar = calendar
        self.now = now
        chart = CheckTimesChart(checks: [], now: now(), calendar: calendar)
        storedLevelFilter = defaults?.string(forKey: DefaultsKey.level).flatMap(ActivityLevelFilter.init) ?? .everything
        storedSourceFilter = defaults?.string(forKey: DefaultsKey.source).flatMap(ActivityEntry.Source.init)
    }

    // MARK: - Filters and search

    /// the levels the list shows; remembered
    public var levelFilter: ActivityLevelFilter {
        get { storedLevelFilter }
        set {
            storedLevelFilter = newValue
            defaults?.set(newValue.rawValue, forKey: DefaultsKey.level)
            refilter()
        }
    }

    /// the one source the list shows; nil for all of them. Remembered.
    public var sourceFilter: ActivityEntry.Source? {
        get { storedSourceFilter }
        set {
            storedSourceFilter = newValue
            defaults?.set(newValue?.rawValue ?? "", forKey: DefaultsKey.source)
            refilter()
        }
    }

    /// the search, case-insensitive, over the message, the detail, the source's name and the outcome's label
    public var searchText: String {
        get { storedSearchText }
        set {
            storedSearchText = newValue
            refilter()
        }
    }

    /// the newest matching entries, at most ``shownAtMost``
    public var shownItems: ArraySlice<ActivityItem> {
        matchingItems.prefix(Self.shownAtMost)
    }

    /// the shown entries by day, newest first
    public var days: [ActivityDay] {
        ActivityDay.days(of: Array(shownItems), now: now(), calendar: calendar)
    }

    /// "1 entry" or "N entries": how many pass the filters and the search
    public var countText: String {
        matchingItems.count == 1 ? "1 entry" : "\(matchingItems.count) entries"
    }

    /// the line under a list cut at ``shownAtMost``; nil when every matching entry shows
    public var truncationMessage: String? {
        guard matchingItems.count > Self.shownAtMost else { return nil }
        return "The newest \(Self.shownAtMost) of \(matchingItems.count) entries: search or filter to see the older ones."
    }

    /// why the list is empty; nil when it shows entries, or before the first read
    public var emptyState: ActivityEmptyState? {
        guard isLoaded, matchingItems.isEmpty else { return nil }
        if items.isEmpty {
            return .noActivity
        }
        let search = storedSearchText.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? .nothingToShow : .noSearchResults(search)
    }

    // MARK: - Footer and files

    /// the time of the oldest entry the log keeps
    public var oldestEntryTime: Date? {
        items.last?.entry.time
    }

    /// the most bytes the log files, the check times and the kept requests take together (LOG-03)
    public var maxBytes: Int {
        log.maxBytes * log.keptFiles + checkTimes.maxBytes + requests.maxBytes
    }

    /// "Since Tue 28 Oct 09:12 · 1.2 MB of at most 16.3 MB: the oldest entries go first"
    public var footerText: String {
        let size = "\(Self.size(totalBytes)) of at most \(Self.size(maxBytes)): the oldest entries go first"
        guard let oldest = oldestEntryTime else { return size }
        var style = Date.FormatStyle.dateTime.weekday().day().month().hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "Since \(oldest.formatted(style)) · \(size)"
    }

    /// What Show in Finder shows: the log file, selected, or its folder when there is no file yet.
    ///
    /// - Returns: the URL, and whether it is the file to select
    public func finderTarget() -> (url: URL, selectsFile: Bool) {
        FileManager.default.fileExists(atPath: log.fileURL.path)
            ? (log.fileURL, true) : (log.fileURL.deletingLastPathComponent(), false)
    }

    // MARK: - Reading

    /// Reads the log, the check times and the sizes again.
    public func reload() async {
        generation += 1
        let generation = generation
        let snapshot = await Self.read(log: log, requests: requests, checkTimes: checkTimes)
        guard generation == self.generation else { return }
        apply(snapshot)
    }

    /// Reads the files again every `interval` while they change, until ``stopFollowing()``, so the list updates live
    /// while it shows. It reads once at once.
    ///
    /// - Parameter interval: the time between two looks at the files
    public func startFollowing(every interval: Duration = .seconds(2)) {
        guard following == nil else { return }
        following = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let store = self else { return }
                await store.reloadIfChanged()
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops following the files.
    public func stopFollowing() {
        following?.cancel()
        following = nil
    }

    private func reloadIfChanged() async {
        let signature = [await log.totalBytes(), await checkTimes.totalBytes(), await requests.totalBytes()]
        if signature != self.signature || !isLoaded {
            self.signature = signature
            await reload()
        } else {
            // The 24 hours move on even when nothing is written.
            let chart = CheckTimesChart(checks: checks, now: now(), calendar: calendar)
            if chart != self.chart {
                self.chart = chart
            }
        }
    }

    private struct Snapshot: Sendable {
        var items: [ActivityItem]
        var checks: [CheckTime]
        var totalBytes: Int
    }

    @concurrent
    private nonisolated static func read(log: ActivityLog, requests: RequestCapture, checkTimes: CheckTimes) async -> Snapshot {
        let entries = await log.entries()
        let checks = await checkTimes.all()
        let bytes = await log.totalBytes() + checkTimes.totalBytes() + requests.totalBytes()
        return Snapshot(items: Array(ActivityItem.items(of: entries).reversed()), checks: checks, totalBytes: bytes)
    }

    private func apply(_ snapshot: Snapshot) {
        items = snapshot.items
        checks = snapshot.checks
        totalBytes = snapshot.totalBytes
        chart = CheckTimesChart(checks: snapshot.checks, now: now(), calendar: calendar)
        isLoaded = true
        refilter()
    }

    private func refilter() {
        let level = storedLevelFilter
        let source = storedSourceFilter
        let words = storedSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        matchingItems = items.filter { item in
            level.includes(item.entry.level) && (source == nil || item.entry.source == source)
                && (words.isEmpty || item.searchText.contains(words))
        }
    }

    // MARK: - Copy, details, clear

    /// Returns the text Copy puts on the clipboard: one line per entry, oldest first (LOG-04).
    ///
    /// - Parameter ids: the selected entries; nil for all the entries that pass the filters and the search
    /// - Returns: the lines, joined by line breaks
    public func copyText(of ids: Set<ActivityItem.ID>? = nil) -> String {
        let chosen = ids.map { ids in matchingItems.filter { ids.contains($0.id) } } ?? matchingItems
        return chosen
            .sorted { $0.position < $1.position }
            .map { $0.line(in: calendar.timeZone) }
            .joined(separator: "\n")
    }

    /// Returns the details of an entry: its request and response when the capture still keeps them.
    ///
    /// - Parameter item: the entry
    /// - Returns: the details
    public func details(of item: ActivityItem) async -> ActivityDetails {
        guard let id = item.entry.requestID, !id.isEmpty, let record = await requests.record(id: id) else {
            return ActivityDetails(item: item, request: nil)
        }
        return ActivityDetails(item: item, request: RequestDetails(record: record))
    }

    /// Deletes the log, the check times and the kept requests, then logs "Cleared the logs" and reads again. The view
    /// asks to confirm first.
    public func clear() async {
        await log.clear()
        await checkTimes.clear()
        await requests.clear()
        await log.log(.info, .settings, Self.clearedMessage)
        signature = nil
        await reload()
    }

    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

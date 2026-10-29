import Foundation

/// The data of the check times chart: the last 24 hours, per hour and per source, the average seconds of a check and
/// the failed requests (LOG-04).
public struct CheckTimesChart: Hashable, Sendable {
    /// The checks of one source in one hour.
    public struct Hour: Identifiable, Hashable, Sendable {
        /// the start of the hour
        public let start: Date
        public let source: ActivityEntry.Source
        /// the checks recorded in the hour
        public let checks: Int
        /// the seconds of a check's requests together, on average
        public let averageSeconds: Double
        /// the requests that failed, over all the hour's checks; the chart marks the hour in red when there are any
        public let failedRequests: Int

        public var id: String { "\(source.rawValue) \(start.timeIntervalSince1970)" }

        public init(start: Date, source: ActivityEntry.Source, checks: Int, averageSeconds: Double, failedRequests: Int) {
            self.start = start
            self.source = source
            self.checks = checks
            self.averageSeconds = averageSeconds
            self.failedRequests = failedRequests
        }
    }

    /// What the chart says of one source, for the 24 hours or for the hour under the pointer.
    public struct Summary: Hashable, Sendable {
        public let source: ActivityEntry.Source
        public let checks: Int
        /// the seconds of a check on average; nil without checks
        public let averageSeconds: Double?
        public let failedRequests: Int

        public init(source: ActivityEntry.Source, checks: Int, averageSeconds: Double?, failedRequests: Int) {
            self.source = source
            self.checks = checks
            self.averageSeconds = averageSeconds
            self.failedRequests = failedRequests
        }

        /// "avg 1.2 s", or "–" without checks
        public var averageText: String {
            averageSeconds.map { "avg \(CheckTimesChart.duration($0))" } ?? "–"
        }

        /// "1 failed" or "N failed"; nil when no request failed
        public var failedText: String? {
            failedRequests == 0 ? nil : "\(failedRequests) failed"
        }
    }

    /// 24 hours
    public static let window: TimeInterval = 24 * 3600
    /// the text of an empty chart
    public static let emptyMessage = "No checks in the last 24 hours yet."

    /// the hours with checks, oldest first, and within an hour in the order of ``ActivityEntry/Source``
    public let hours: [Hour]
    /// the start of the 24 hours
    public let since: Date
    private let totals: [ActivityEntry.Source: (seconds: Double, checks: Int, failed: Int)]

    /// Groups the check times of the 24 hours before `now` by the hour of the calendar.
    ///
    /// - Parameters:
    ///   - checks: the check times, in any order
    ///   - now: the end of the 24 hours
    ///   - calendar: the calendar whose hours count, so an hour starts on the hour of the local time
    public init(checks: [CheckTime], now: Date, calendar: Calendar = .current) {
        since = now.addingTimeInterval(-Self.window)
        var sums: [String: (start: Date, source: ActivityEntry.Source, seconds: Double, checks: Int, failed: Int)] = [:]
        var totals: [ActivityEntry.Source: (seconds: Double, checks: Int, failed: Int)] = [:]
        for check in checks where check.time >= since && check.time <= now {
            let start = calendar.dateInterval(of: .hour, for: check.time)?.start ?? check.time
            let key = "\(check.source.rawValue) \(start.timeIntervalSince1970)"
            let sum = sums[key] ?? (start, check.source, 0, 0, 0)
            sums[key] = (start, check.source, sum.seconds + check.seconds, sum.checks + 1, sum.failed + check.failed)
            let total = totals[check.source] ?? (0, 0, 0)
            totals[check.source] = (total.seconds + check.seconds, total.checks + 1, total.failed + check.failed)
        }
        let order = ActivityEntry.Source.allCases
        hours = sums.values
            .map { Hour(start: $0.start, source: $0.source, checks: $0.checks, averageSeconds: $0.seconds / Double($0.checks), failedRequests: $0.failed) }
            .sorted { ($0.start, order.firstIndex(of: $0.source)!) < ($1.start, order.firstIndex(of: $1.source)!) }
        self.totals = totals
    }

    /// whether no check was recorded in the 24 hours
    public var isEmpty: Bool {
        hours.isEmpty
    }

    /// the sources with checks in the 24 hours, in the order of ``ActivityEntry/Source``
    public var sources: [ActivityEntry.Source] {
        ActivityEntry.Source.allCases.filter { totals[$0] != nil }
    }

    /// Returns what the chart says of a source: for the 24 hours, or for one hour.
    ///
    /// - Parameters:
    ///   - source: the source
    ///   - hour: the start of the hour under the pointer; nil for the 24 hours
    /// - Returns: the checks, their average seconds and the failed requests
    public func summary(of source: ActivityEntry.Source, hour: Date? = nil) -> Summary {
        if let hour {
            let match = hours.first { $0.source == source && $0.start == hour }
            return Summary(
                source: source, checks: match?.checks ?? 0, averageSeconds: match?.averageSeconds,
                failedRequests: match?.failedRequests ?? 0)
        }
        // Weighted by the checks, so a busy hour counts for more than a quiet one.
        let total = totals[source]
        return Summary(
            source: source, checks: total?.checks ?? 0, averageSeconds: total.map { $0.seconds / Double($0.checks) },
            failedRequests: total?.failed ?? 0)
    }

    public static func == (lhs: CheckTimesChart, rhs: CheckTimesChart) -> Bool {
        lhs.hours == rhs.hours && lhs.since == rhs.since
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hours)
        hasher.combine(since)
    }

    /// "1.2 s": no decimals for 0 and from 10 s, two below 1 s, else one, as the old tool's chart.
    public static func duration(_ seconds: Double) -> String {
        let digits = seconds == 0 || seconds >= 10 ? 0 : seconds < 1 ? 2 : 1
        let number = seconds.formatted(
            .number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        return "\(number) s"
    }
}

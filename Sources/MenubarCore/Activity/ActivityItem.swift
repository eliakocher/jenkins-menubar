import Foundation

/// Which levels the Activity list shows (LOG-04).
public enum ActivityLevelFilter: String, CaseIterable, Hashable, Sendable {
    /// every entry, each request and check too
    case everything
    /// all but debug: the builds, alerts, changes and problems
    case events
    /// warnings and errors
    case problems

    /// "Everything", "Events" or "Problems"
    public var title: String {
        switch self {
        case .everything: "Everything"
        case .events: "Events"
        case .problems: "Problems"
        }
    }

    /// Returns whether entries of a level pass the filter.
    ///
    /// - Parameter level: the entry's level
    /// - Returns: `true` when the list shows them
    public func includes(_ level: ActivityEntry.Level) -> Bool {
        switch self {
        case .everything: true
        case .events: level != .debug
        case .problems: level >= .warning
        }
    }
}

/// One row of the Activity list: an entry of the log, with an id that stays the same while the log grows, so the
/// selection survives the live updates.
public struct ActivityItem: Identifiable, Hashable, Sendable {
    /// the entry's time in milliseconds and its place among the entries of that millisecond, like `1761638400123-0`
    public let id: String
    public let entry: ActivityEntry
    /// the entry's place in the log, oldest first, so copies keep the order things happened in
    let position: Int
    /// the message, detail, source name and outcome label in lowercase, so a search over thousands of entries stays
    /// quick
    let searchText: String

    /// Creates an item; ``ActivityStore`` makes them from the log, the gallery from its fixtures.
    ///
    /// - Parameters:
    ///   - id: the id, unique among the items
    ///   - entry: the entry
    ///   - position: the entry's place in the log, oldest first
    public init(id: String, entry: ActivityEntry, position: Int) {
        self.id = id
        self.entry = entry
        self.position = position
        searchText = [entry.project ?? "", entry.message, entry.detail ?? "", entry.source.displayName, entry.outcome?.label ?? ""]
            .joined(separator: "\n")
            .lowercased()
    }

    /// whether the entry names a request, whose details the capture may still keep
    public var hasRequest: Bool {
        entry.requestID?.isEmpty == false
    }

    /// The message as the Activity view shows it: without the emoji an alert's headline starts with ("❌ !16 #3
    /// FAILURE (alert)"), since the outcome's pill says it. The stored text and Copy keep it.
    public var displayMessage: String {
        guard let project = entry.project, !project.isEmpty else {
            return shownMessage
        }
        // With several projects, the project comes first (plan Phase 13).
        return "\(project) · \(shownMessage)"
    }

    private var shownMessage: String {
        let message = entry.message
        guard let first = message.unicodeScalars.first, first.value > 0x2000, first.properties.isEmoji else {
            return message
        }
        // The emoji is one character, maybe with a variation selector; a space follows it.
        guard let space = message.firstIndex(of: " "), message[..<space].count == 1 else { return message }
        let rest = message[message.index(after: space)...]
        return rest.isEmpty ? message : String(rest)
    }

    /// Makes the items of the log's entries, keeping their order.
    ///
    /// - Parameter entries: the entries, oldest first
    /// - Returns: one item per entry, oldest first
    static func items(of entries: [ActivityEntry]) -> [ActivityItem] {
        var seen: [Int64: Int] = [:]
        return entries.enumerated().map { position, entry in
            let milliseconds = Int64((entry.time.timeIntervalSince1970 * 1000).rounded())
            let ordinal = seen[milliseconds, default: 0]
            seen[milliseconds] = ordinal + 1
            return ActivityItem(id: "\(milliseconds)-\(ordinal)", entry: entry, position: position)
        }
    }

    /// Returns the line Copy puts on the clipboard: "time  LEVEL  Source  outcome  message  detail", empty parts left
    /// out (LOG-04).
    ///
    /// - Parameter timeZone: the time zone of the time
    /// - Returns: the line, like `2026-10-28 09:12:03  INFO  Settings  Cleared the logs`
    public func line(in timeZone: TimeZone = .current) -> String {
        [
            Self.time(of: entry.time, in: timeZone), entry.level.rawValue.uppercased(), entry.source.displayName,
            entry.outcome?.label ?? "", entry.message, entry.detail ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "  ")
    }

    /// Returns the whole entry, as the details show an entry without a request.
    ///
    /// - Parameter timeZone: the time zone of the time
    /// - Returns: the time, the level, source and outcome, the message and the detail, a blank line between them
    public func fullText(in timeZone: TimeZone = .current) -> String {
        // The outcome's label, not its stored `failed:FAILURE` form: that is the file's syntax, not for reading.
        let facts = [entry.level.rawValue, entry.source.displayName, entry.outcome?.label ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return [Self.time(of: entry.time, in: timeZone), facts, displayMessage, entry.detail ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// `2026-10-28 09:12:03`, in the given time zone.
    static func time(of date: Date, in timeZone: TimeZone) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: timeZone)
                .year().month().day().time(includingFractionalSeconds: false))
    }
}

/// The shown rows of one day, newest first, under a heading like "Today" (LOG-04).
public struct ActivityDay: Identifiable, Hashable, Sendable {
    /// the start of the day
    public let day: Date
    /// "Today", "Yesterday", or the date, like "Monday 27 October"
    public let title: String
    public let items: [ActivityItem]

    public var id: Date { day }

    public init(day: Date, title: String, items: [ActivityItem]) {
        self.day = day
        self.title = title
        self.items = items
    }

    /// Groups items by the day of their time.
    ///
    /// - Parameters:
    ///   - items: the items, newest first
    ///   - now: the time "Today" and "Yesterday" are relative to
    ///   - calendar: the calendar whose days count
    /// - Returns: the days, newest first, each with its items in the given order
    static func days(of items: [ActivityItem], now: Date, calendar: Calendar) -> [ActivityDay] {
        var groups: [(day: Date, items: [ActivityItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.entry.time)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups.map { ActivityDay(day: $0.day, title: title(of: $0.day, now: now, calendar: calendar), items: $0.items) }
    }

    private static func title(of day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }
}

/// Why the Activity list is empty, for its empty state (LOG-04).
public enum ActivityEmptyState: Hashable, Sendable {
    /// the log has no entry at all: "No Activity Yet"
    case noActivity
    /// the filters leave nothing: "Nothing to Show"
    case nothingToShow
    /// the search finds nothing
    case noSearchResults(String)
}

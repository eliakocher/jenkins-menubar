import Foundation

/// A release slot's name, the part of its label after the slot prefix: `2026.51` is ISO week 51 of 2026 (SLOT-01).
public struct SlotName: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// the ISO week-numbering year
    public var year: Int
    /// the ISO week, 1 to 53
    public var week: Int

    /// Creates the name of a week.
    ///
    /// - Parameters:
    ///   - year: the ISO year, four digits
    ///   - week: the ISO week, 1 to 53; whether the year has a week 53 shows when the dates are computed
    public init?(year: Int, week: Int) {
        guard (1000...9999).contains(year), (1...53).contains(week) else { return nil }
        self.year = year
        self.week = week
    }

    /// Reads a name like `2026.51`: a four-digit year, a dot and a one- or two-digit week, nothing else.
    ///
    /// - Parameter value: the text after the slot prefix
    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, (1...2).contains(parts[1].count),
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let year = Int(parts[0]), let week = Int(parts[1])
        else { return nil }
        self.init(year: year, week: week)
    }

    /// Reads the slot out of a label.
    ///
    /// - Parameters:
    ///   - label: the label's title, like `slot::2026.51`
    ///   - prefix: the slot label prefix from Team; empty means no slots
    public init?(label: String, prefix: String) {
        guard !prefix.isEmpty, label.hasPrefix(prefix) else { return nil }
        self.init(String(label.dropFirst(prefix.count)))
    }

    /// like `2026.51`
    public var description: String { "\(year).\(String(format: "%02d", week))" }

    public static func < (left: SlotName, right: SlotName) -> Bool {
        (left.year, left.week) < (right.year, right.week)
    }
}

/// The three dates of a slot, each the start of its day (SLOT-01).
public struct SlotDates: Hashable, Sendable {
    public var release: Date
    public var codeFreeze: Date
    public var earlyAccess: Date

    public init(release: Date, codeFreeze: Date, earlyAccess: Date) {
        self.release = release
        self.codeFreeze = codeFreeze
        self.earlyAccess = earlyAccess
    }

    /// The dates a slot counts down to.
    public enum Milestone: String, Hashable, Sendable, CaseIterable {
        case codeFreeze
        case earlyAccess
        case release

        /// "Code freeze", "Early access" or "Release"
        public var title: String {
            switch self {
            case .codeFreeze: "Code freeze"
            case .earlyAccess: "Early access"
            case .release: "Release"
            }
        }
    }

    public func date(of milestone: Milestone) -> Date {
        switch milestone {
        case .codeFreeze: codeFreeze
        case .earlyAccess: earlyAccess
        case .release: release
        }
    }

    /// Returns the next milestone that isn't past: the earliest date from today on.
    ///
    /// - Parameters:
    ///   - today: any time of today
    ///   - calendar: the calendar whose days count
    /// - Returns: the milestone and the days until it (0 for today); `nil` when all are past
    public func next(from today: Date, calendar: Calendar) -> (milestone: Milestone, days: Int)? {
        let start = calendar.startOfDay(for: today)
        return Milestone.allCases
            .map { ($0, SlotRules.days(from: start, to: date(of: $0), calendar: calendar)) }
            .filter { $0.1 >= 0 }
            .min { $0.1 < $1.1 }
            .map { (milestone: $0.0, days: $0.1) }
    }

    /// Returns the countdown: "Code freeze in 3 days", "Early access tomorrow", "Release today", or "Released 5 days
    /// ago" once the release is past (SLOT-02).
    ///
    /// - Parameters:
    ///   - today: any time of today
    ///   - calendar: the calendar whose days count
    public func countdown(from today: Date, calendar: Calendar) -> String {
        guard let (milestone, days) = next(from: today, calendar: calendar) else {
            let ago = -SlotRules.days(from: calendar.startOfDay(for: today), to: release, calendar: calendar)
            return ago == 1 ? "Released yesterday" : "Released \(ago) days ago"
        }
        switch days {
        case 0: return "\(milestone.title) today"
        case 1: return "\(milestone.title) tomorrow"
        default: return "\(milestone.title) in \(days) days"
        }
    }
}

/// How a slot's name becomes its dates, from the team values (SLOT-01).
///
/// The slot `2026.51` is ISO week 51 of 2026 (weeks start on Monday; week 1 holds the year's first Thursday): the week
/// of its release, which is on the release weekday of that week. The code freeze is the Nth weekday before the release
/// and so is early access, the way the team's planning tool computes them: by default the 4th Friday and the 2nd
/// Monday before it, so `2026.51` releases on Mon 14 Dec 2026, freezes on Fri 20 Nov and opens early access on Mon 30
/// Nov. Slots before 2026.30 released on Thursday; their dates are a few days off with the Monday default.
public struct SlotRules: Hashable, Sendable {
    /// a weekday before the release, counted back from it
    public struct Anchor: Hashable, Sendable {
        /// which one, 1 for the nearest before the release
        public var nth: Int
        /// the ISO weekday: 1 is Monday and 7 is Sunday
        public var weekday: Int

        public init(nth: Int, weekday: Int) {
            self.nth = nth
            self.weekday = weekday
        }
    }

    /// the release's weekday, ISO: 1 is Monday and 7 is Sunday
    public var releaseWeekday: Int
    public var codeFreeze: Anchor
    public var earlyAccess: Anchor
    /// how many days before the code freeze a committed work item without a merge request is flagged and the slot alert
    /// comes
    public var warnDays: Int
    /// how many upcoming slots show after the current one, 1 to 12
    public var upcomingShown: Int

    public static let defaultReleaseWeekday = 1
    public static let defaultCodeFreeze = Anchor(nth: 4, weekday: 5)
    public static let defaultEarlyAccess = Anchor(nth: 2, weekday: 1)
    public static let defaultWarnDays = 3
    public static let defaultUpcomingShown = 4

    public init(
        releaseWeekday: Int = defaultReleaseWeekday, codeFreeze: Anchor = defaultCodeFreeze,
        earlyAccess: Anchor = defaultEarlyAccess, warnDays: Int = defaultWarnDays,
        upcomingShown: Int = defaultUpcomingShown
    ) {
        self.releaseWeekday = releaseWeekday
        self.codeFreeze = codeFreeze
        self.earlyAccess = earlyAccess
        self.warnDays = warnDays
        self.upcomingShown = upcomingShown
    }

    /// Reads the rules from the team values; an empty or invalid value reads as its default.
    public init(team: TeamValues) {
        self.init(
            releaseWeekday: Self.weekday(of: team.slotReleaseWeekday) ?? Self.defaultReleaseWeekday,
            codeFreeze: Anchor(
                nth: Self.nth(of: team.slotCodeFreezeNth) ?? Self.defaultCodeFreeze.nth,
                weekday: Self.weekday(of: team.slotCodeFreezeWeekday) ?? Self.defaultCodeFreeze.weekday),
            earlyAccess: Anchor(
                nth: Self.nth(of: team.slotEarlyAccessNth) ?? Self.defaultEarlyAccess.nth,
                weekday: Self.weekday(of: team.slotEarlyAccessWeekday) ?? Self.defaultEarlyAccess.weekday),
            warnDays: Self.days(of: team.slotWarnDays) ?? Self.defaultWarnDays,
            upcomingShown: Self.nth(of: team.slotUpcomingShown) ?? Self.defaultUpcomingShown)
    }

    /// Reads a weekday: its English name or its first three letters, or a number from 1 (Monday) to 7.
    ///
    /// - Parameter text: the typed value
    /// - Returns: the ISO weekday; `nil` for an empty or unknown text
    public static func weekday(of text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let number = Int(text) {
            return (1...7).contains(number) ? number : nil
        }
        guard text.count >= 3 else { return nil }
        let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        return names.firstIndex { $0.hasPrefix(text) }.map { $0 + 1 }
    }

    /// Reads a number of days from 0 to 365.
    ///
    /// - Parameter text: the typed value
    /// - Returns: the days; `nil` for an empty or invalid text
    public static func days(of text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let days = Int(text), days <= 365 else { return nil }
        return days
    }

    /// Reads which weekday before the release, or how many upcoming slots show: a number from 1 to 12.
    ///
    /// - Parameter text: the typed value
    /// - Returns: the number; `nil` for an empty or invalid text
    public static func nth(of text: String) -> Int? {
        days(of: text).flatMap { (1...12).contains($0) ? $0 : nil }
    }

    /// Returns the calendar slot dates are computed in: ISO weeks, in the time zone of the given calendar.
    static func isoCalendar(like calendar: Calendar) -> Calendar {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso
    }

    /// Returns the dates of a slot.
    ///
    /// - Parameters:
    ///   - name: the slot
    ///   - calendar: the calendar whose time zone counts
    /// - Returns: the dates; `nil` when the year has no such week, like 2027.53
    public func dates(of name: SlotName, calendar: Calendar = .current) -> SlotDates? {
        let iso = Self.isoCalendar(like: calendar)
        // Calendar's weekday counts from Sunday = 1.
        let weekday = releaseWeekday % 7 + 1
        guard let date = iso.date(from: DateComponents(weekday: weekday, weekOfYear: name.week, yearForWeekOfYear: name.year))
        else { return nil }
        // A week the year doesn't have rolls over into the next year.
        let back = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard back.yearForWeekOfYear == name.year, back.weekOfYear == name.week else { return nil }
        let release = iso.startOfDay(for: date)
        guard let freeze = Self.date(of: codeFreeze, before: release, releaseWeekday: releaseWeekday, in: iso),
            let early = Self.date(of: earlyAccess, before: release, releaseWeekday: releaseWeekday, in: iso)
        else { return nil }
        return SlotDates(release: release, codeFreeze: freeze, earlyAccess: early)
    }

    /// Returns the Nth weekday strictly before the release: the 1st is the nearest one, a week back for a release on that
    /// weekday itself.
    private static func date(of anchor: Anchor, before release: Date, releaseWeekday: Int, in calendar: Calendar) -> Date? {
        var back = (releaseWeekday - anchor.weekday + 7) % 7
        if back == 0 { back = 7 }
        back += 7 * (anchor.nth - 1)
        return calendar.date(byAdding: .day, value: -back, to: release)
    }

    /// Returns the days from one day to another, negative when the second is earlier.
    static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }
}

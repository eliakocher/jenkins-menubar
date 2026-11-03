import Foundation

/// A season of the year in which the alert's butler wears a hat of the season (`docs/easter-eggs.md`, the fun layer).
///
/// The cases are in the order they win when two overlap: carnival, Easter, Halloween, New Year, then Santa. The dates:
///
/// - ``carnival``: only the exact days of ``carnivalRanges``, inclusive; a year that isn't in the table has none.
/// - ``easter``: Palm Sunday to Easter Monday (Western Easter, computed), every year.
/// - ``halloween``: October 17 to November 7, every year (two weeks before, one week after).
/// - ``newYear``: December 31 to January 14, every year.
/// - ``santa``: all of December, up to the 30th, since New Year's Eve belongs to ``newYear``.
///
/// Carnival, Easter, Halloween and New Year need the fun level Normal or Party; Santa shows at every level, as it always did.
public enum ButlerSeason: String, Hashable, Sendable, CaseIterable {
    case carnival
    case easter
    case halloween
    case newYear
    case santa

    /// A calendar day, ordered by year, month and day.
    public struct Day: Comparable, Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(_ year: Int, _ month: Int, _ day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    /// The days of Carnival, one range a year, both ends included. Add a line here for a new year; a year without a
    /// line has no Carnival.
    public static let carnivalRanges: [ClosedRange<Day>] = [
        Day(2027, 2, 10)...Day(2027, 2, 20),
        Day(2028, 3, 3)...Day(2028, 3, 13),
        Day(2029, 2, 15)...Day(2029, 2, 26),
        Day(2030, 3, 5)...Day(2030, 3, 20),
    ]

    /// Returns the date of Western Easter Sunday of a year, by the Gregorian computus (the anonymous algorithm, also
    /// known as Meeus, Jones and Butcher's).
    ///
    /// - Parameter year: a Gregorian year
    public static func easterSunday(of year: Int) -> Day {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return Day(year, month, day)
    }

    /// Returns the days of Easter's season in a year: Palm Sunday (a week before Easter Sunday) to Easter Monday.
    ///
    /// - Parameter year: a Gregorian year
    public static func easterRange(of year: Int) -> ClosedRange<Day> {
        let easter = easterSunday(of: year)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: easter.year, month: easter.month, day: easter.day))!
        func day(_ offset: Int) -> Day {
            let parts = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: offset, to: date)!)
            return Day(parts.year!, parts.month!, parts.day!)
        }
        return day(-7)...day(1)
    }

    /// Returns the season of a day.
    ///
    /// - Parameters:
    ///   - date: the time
    ///   - calendar: the calendar, whose time zone says what the local date is
    ///   - level: the fun level; the seasons other than Santa need Normal or Party
    /// - Returns: the season that wins on that day, or `nil` for none
    public static func current(on date: Date, calendar: Calendar = .current, level: FunLevel) -> ButlerSeason? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let today = Day(parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return ButlerSeason.allCases.first { $0.contains(today, level: level) }
    }

    private func contains(_ today: Day, level: FunLevel) -> Bool {
        switch self {
        case .carnival: level.showsMoments && Self.carnivalRanges.contains { $0.contains(today) }
        case .easter: level.showsMoments && Self.easterRange(of: today.year).contains(today)
        case .halloween:
            level.showsMoments && ((today.month == 10 && today.day >= 17) || (today.month == 11 && today.day <= 7))
        case .newYear: level.showsMoments && ((today.month == 12 && today.day == 31) || (today.month == 1 && today.day <= 14))
        case .santa: today.month == 12
        }
    }

    /// the hat the alert's butler wears in this season
    public var hat: ButlerHat {
        switch self {
        case .carnival: .carnival
        case .easter: .easter
        case .halloween: .witch
        case .newYear: .newYear
        case .santa: .santa
        }
    }
}

import Foundation

/// How long a to-do sleeps (INBOX-04): an hour, tomorrow morning, next week, or until a date.
public enum InboxSnoozeChoice: Hashable, Sendable {
    case oneHour
    /// tomorrow at ``morningHour``
    case tomorrowMorning
    /// next Monday at ``morningHour``; on a Monday, the one after
    case nextWeek
    case until(Date)

    /// the hour a morning snooze wakes at
    public static let morningHour = 9

    /// the choices of the snooze menu, without a date
    public static let presets: [InboxSnoozeChoice] = [.oneHour, .tomorrowMorning, .nextWeek]

    /// the choice in the menu, in Title Style
    public var title: String {
        switch self {
        case .oneHour: "For an Hour"
        case .tomorrowMorning: "Until Tomorrow Morning"
        case .nextWeek: "Until Next Week"
        case .until: "Until a Date…"
        }
    }

    /// Returns when the to-do wakes.
    ///
    /// - Parameters:
    ///   - now: the time of the snooze
    ///   - calendar: the user's calendar, for the mornings and the weeks
    /// - Returns: the time it is back in the Inbox
    public func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .until(let date):
            return date
        case .tomorrowMorning:
            return morning(daysAfter: 1, now, calendar)
        case .nextWeek:
            // Sunday is 1, Monday 2.
            let weekday = calendar.component(.weekday, from: now)
            let days = (2 - weekday + 7) % 7
            return morning(daysAfter: days == 0 ? 7 : days, now, calendar)
        }
    }

    private func morning(daysAfter days: Int, _ now: Date, _ calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day) ?? day
    }
}

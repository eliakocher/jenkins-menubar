import Foundation

/// The lines that belong to the time: lunch at noon, the way home at 17:30, the Friday warning at 16:00, the yawn after
/// 22:00, a running build's birthday, and the app's anniversary. Each is a window of time, not an event, so the pane's footer
/// shows it while the window lasts. Pure: the time and the calendar come in, so each rule has a test.
public enum FunTimers {
    /// A timer line that is on now.
    public struct Active: Equatable, Sendable {
        /// which pool the line comes from
        public var key: FunKey
        /// the window it belongs to, like `lunch|2026-11-03`, so the same window draws one line
        public var window: String
        /// the tokens' values
        public var values: [String: String]
    }

    /// how long a build's birthday shows after the hour is full
    public static let birthdayWindow: TimeInterval = 10 * 60

    /// Returns the timer line that is on now. When several are, the first of: the anniversary, a build's birthday, the yawn
    /// after 22:00, the Friday warning, the way home, lunch.
    ///
    /// - Parameters:
    ///   - now: the time
    ///   - calendar: the calendar
    ///   - running: my running builds, whose start says how long they have run
    ///   - firstUse: when the app was first used, for the anniversary
    public static func active(now: Date, calendar: Calendar, running: [Build], firstUse: Date?) -> Active? {
        let day = EggMemory.dayKey(now, calendar)
        if let years = anniversaryYears(now: now, calendar: calendar, firstUse: firstUse) {
            return Active(key: .anniversary, window: "anniversary|\(day)", values: ["{y}": years == 1 ? "a year" : "\(years) years"])
        }
        if let birthday = birthday(running: running, now: now) {
            return Active(
                key: .birthday, window: "birthday|\(birthday.job)|\(birthday.number)|\(birthday.hours)",
                values: ["{h}": birthday.hours == 1 ? "1 hour" : "\(birthday.hours) hours"])
        }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let hour = parts.hour ?? 12
        let minutes = hour * 60 + (parts.minute ?? 0)
        let isWeekday = (2...6).contains(parts.weekday ?? 1)
        if hour >= 22 || hour < 4 {
            let time = String(format: "%02d:%02d", hour, parts.minute ?? 0)
            // One night is one window across midnight.
            let night = EggMemory.dayKey(now.addingTimeInterval(-5 * 3600), calendar)
            return Active(key: .midnightOil, window: "midnight|\(night)", values: ["{time}": time])
        }
        if parts.weekday == 6, (16 * 60..<17 * 60 + 30).contains(minutes) {
            return Active(key: .noDeploys, window: "no-deploys|\(day)", values: [:])
        }
        if isWeekday, (17 * 60 + 30..<19 * 60).contains(minutes) {
            return Active(key: .goHome, window: "go-home|\(day)", values: [:])
        }
        if isWeekday, (12 * 60..<13 * 60).contains(minutes) {
            return Active(key: .lunch, window: "lunch|\(day)", values: [:])
        }
        return nil
    }

    /// Returns a running build that has just run for a whole number of hours, 1 or more, in the last ten minutes.
    static func birthday(running: [Build], now: Date) -> (job: String, number: Int, hours: Int)? {
        for build in running where build.isRunning {
            let elapsed = now.timeIntervalSince(build.startedAt)
            guard elapsed >= 3600 else {
                continue
            }
            let hours = Int(elapsed / 3600)
            if elapsed - Double(hours) * 3600 < birthdayWindow {
                return (build.job, build.number, hours)
            }
        }
        return nil
    }

    /// Returns the years of the app's anniversary when today is its day: the day of the year of the first use, at least a
    /// year later.
    static func anniversaryYears(now: Date, calendar: Calendar, firstUse: Date?) -> Int? {
        guard let firstUse else {
            return nil
        }
        let then = calendar.dateComponents([.year, .month, .day], from: firstUse)
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let thenYear = then.year, let year = today.year, year > thenYear, then.month == today.month, then.day == today.day
        else {
            return nil
        }
        return year - thenYear
    }

    /// Returns whether today gets fireworks at Party: New Year's Eve, New Year's Day and the app's anniversary.
    public static func isFireworksDay(now: Date, calendar: Calendar, firstUse: Date?) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: now)
        if (parts.month == 12 && parts.day == 31) || (parts.month == 1 && parts.day == 1) {
            return true
        }
        return anniversaryYears(now: now, calendar: calendar, firstUse: firstUse) != nil
    }
}

import Foundation
import MenubarCore

/// The texts of times and durations that the rows and the alert show (PIPE-02, PIPE-03, PIPE-07). Numbers are plain
/// digits: an `Int` interpolated into a SwiftUI `Text` would get the locale's grouping (`docs/decisions.md`, Task 0.10).
public enum Formatting {
    /// Returns a duration as hours and two-digit minutes, rounded down, like `0h05m` or `1h05m` (PIPE-02).
    ///
    /// - Parameter seconds: the duration; below 0 counts as 0
    /// - Returns: the text
    public static func duration(_ seconds: TimeInterval) -> String {
        AlertContent.durationText(seconds)
    }

    /// Returns how long a running build has been running, like `0h05m elapsed` (PIPE-02).
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - now: the current time
    /// - Returns: the text
    public static func elapsed(_ build: Build, now: Date) -> String {
        "\(duration(build.elapsed(at: now))) elapsed"
    }

    /// Returns the time a running build still needs by Jenkins' estimate, like `~0h20m left`, never below
    /// `~0h00m left` (PIPE-02).
    ///
    /// - Parameters:
    ///   - build: the build
    ///   - now: the current time
    /// - Returns: the text; `nil` without an estimate
    public static func remaining(_ build: Build, now: Date) -> String? {
        build.remaining(at: now).map { "~\(duration($0)) left" }
    }

    /// Returns how long ago something happened: whole minutes under an hour (`30m`), whole hours under a day (`5h`),
    /// whole days otherwise (`3d`) (PIPE-03).
    ///
    /// - Parameters:
    ///   - date: when it happened
    ///   - now: the current time
    /// - Returns: the age, never below `0m`
    public static func age(since date: Date, now: Date) -> String {
        GitLabText.age(since: date, now: now)
    }

    /// Returns `Last checked 10:42`, in the user's short time format (PIPE-07, WI-07).
    ///
    /// - Parameters:
    ///   - date: the time of the last check or load
    ///   - locale: the locale of the time format
    ///   - timeZone: the time zone of the time
    /// - Returns: the text
    public static func lastChecked(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        GitLabText.lastChecked(date, locale: locale, timeZone: timeZone)
    }

    /// Returns `Failed tests: 3 of 1200` when tests failed (PIPE-03, ALERT-02).
    ///
    /// - Parameter counts: the test counts, when known
    /// - Returns: the text; `nil` when they aren't known or none failed
    public static func failedTests(_ counts: TestCounts?) -> String? {
        guard let counts, counts.failed > 0 else {
            return nil
        }
        return "Failed tests: \(String(counts.failed)) of \(String(counts.total))"
    }
}

import Foundation

/// The items of this app that go into the Inbox as local entries (Task 7.03): a Claude answer that landed while its
/// card wasn't on screen, the morning digest, and a failed build. Each has a stable id, so the same thing is added once.
extension InboxEvent {
    /// the most characters of an answer's first line kept for the row
    public static let excerptLength = 140

    /// Returns the entry of a Claude answer, or of a failure to answer.
    ///
    /// - Parameters:
    ///   - subjectKey: a stable key of what the answer is about, like `mr:group/project!12`
    ///   - useCase: the use case's name in Title Style, like "Why Did It Fail?"
    ///   - failed: whether Claude failed instead of answering
    ///   - title: the item's title, or its reference when the title isn't known
    ///   - reference: the item's full reference
    ///   - excerpt: the first line of the answer, or the reason for the failure
    ///   - url: where the answer is: the item's page, or a `megamonitor://` route
    ///   - at: when it landed
    /// - Returns: the local event
    public static func claudeAnswered(
        subjectKey: String, useCase: String, failed: Bool, title: String, reference: String?, excerpt: String?, url: URL?,
        at date: Date
    ) -> InboxEvent {
        InboxEvent(
            id: "claude|\(subjectKey)|\(Int(date.timeIntervalSince1970 * 1000))", kind: .claudeAnswered, source: .local,
            title: title, reference: reference, targetURL: url, occurredAt: date,
            headlineText: failed ? "Claude couldn't answer: \(useCase)" : "Claude answered: \(useCase)",
            excerpt: excerpt.flatMap(Self.firstLine))
    }

    /// Returns the entry of the digest, once a day.
    ///
    /// - Parameters:
    ///   - summary: the digest's summary line, or nothing
    ///   - url: the Digest section's link
    ///   - date: when it was written
    ///   - calendar: the calendar whose day it counts for
    /// - Returns: the local event
    public static func digestReady(summary: String?, url: URL, at date: Date, calendar: Calendar = .current) -> InboxEvent {
        return InboxEvent(
            id: "digest|" + dayText(of: date, calendar: calendar), kind: .digestReady,
            source: .local, title: "Your digest is ready", targetURL: url, occurredAt: date,
            headlineText: "Morning digest, written by Claude", excerpt: summary.flatMap(Self.firstLine))
    }

    /// Returns the entry of the daily coffee break, one per day.
    ///
    /// - Parameters:
    ///   - line: the line Haiku wrote, or one of the built-in lines
    ///   - date: when it comes
    ///   - calendar: the calendar whose day it counts for
    /// - Returns: the local event
    public static func coffeeBreak(line: String, at date: Date, calendar: Calendar = .current) -> InboxEvent {
        InboxEvent(
            id: coffeeIDPrefix + dayText(of: date, calendar: calendar), kind: .coffeeBreak, source: .local,
            title: "☕ Coffee break", occurredAt: date, headlineText: "Time for a break", excerpt: line)
    }

    /// the start of the coffee break entries' ids, for ``InboxStore/resolveLocal(kind:idPrefix:except:)``
    public static let coffeeIDPrefix = "coffee|"

    /// the id of the coffee break entry of a day
    public static func coffeeID(on date: Date, calendar: Calendar = .current) -> String {
        coffeeIDPrefix + dayText(of: date, calendar: calendar)
    }

    private static func dayText(of date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Returns the entry of a build that failed or went unstable, one per build.
    ///
    /// - Parameters:
    ///   - jobKey: the job's key among every project's (``BuildID/jobKey``)
    ///   - number: the build's number
    ///   - label: the build as the app names it, like `!12501 #5`
    ///   - isUnstable: whether it went unstable instead of failing
    ///   - title: the build's title, like the merge request's
    ///   - url: the build in Jenkins; the app opens it in its own views
    ///   - date: when it finished
    /// - Returns: the local event
    public static func buildFailed(
        jobKey: String, number: Int, label: String, isUnstable: Bool, title: String?, url: URL, at date: Date
    ) -> InboxEvent {
        InboxEvent(
            id: "\(buildIDPrefix(jobKey: jobKey))\(number)", kind: .buildFailed, source: .local,
            title: title ?? label, reference: label, targetURL: url, occurredAt: date,
            headlineText: "Build \(label) \(isUnstable ? "went unstable" : "failed")")
    }

    /// the start of the ids of a job's failed builds, for ``InboxStore/resolveLocal(kind:idPrefix:)``
    public static func buildIDPrefix(jobKey: String) -> String {
        "build|\(jobKey)|"
    }

    /// the first non-empty line, without the Markdown marks a heading or a list starts with, cut to ``excerptLength``
    static func firstLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            while let first = trimmed.first, "#>*-•".contains(first) {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if !trimmed.isEmpty {
                return trimmed.count > excerptLength ? String(trimmed.prefix(excerptLength - 1)) + "…" : trimmed
            }
        }
        return nil
    }
}

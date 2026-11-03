import Foundation

/// The daily coffee break (the user, 2026-11-03: "at 08.59 i want in the inbox a coffee notification, use haiku for a
/// little prompt every day"): on weekdays at its time, an Inbox entry "☕ Coffee break" with a short line.
///
/// - The line comes from Claude's Haiku (``AIStore/coffeeLine(on:calendar:)``); while Claude is off or doesn't answer,
///   one of ``fallbackLines`` stands in, so the entry always comes.
/// - It follows the digest's pattern: a sleep on the injected clock to the next time, and a window after it: a Mac that
///   wakes later than ``window`` after the time skips that day. A launch inside the window adds the entry too.
/// - One entry a day, across launches: the Inbox remembers the id (``InboxStore/wasAnnounced(_:)``), so neither a
///   second launch nor a second wake adds it, and spends no second Claude run. Today's entry replaces yesterday's.
@MainActor
public final class CoffeeBreak {
    /// how long after its time the entry still comes
    public static let window: TimeInterval = 30 * 60

    private let inbox: InboxStore
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let line: @MainActor (Date) async -> String?
    private var loop: Task<Void, Never>?
    private var rules = InboxNotificationRules()

    /// - Parameters:
    ///   - inbox: where the entries go
    ///   - clock: sleeps until the next time
    ///   - now: the time
    ///   - calendar: the calendar of the day and the weekday, local by default
    ///   - line: the line of the day, from Haiku; `nil` for the built-in ones
    public init(
        inbox: InboxStore, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current, line: @escaping @MainActor (Date) async -> String? = { _ in nil }
    ) {
        self.inbox = inbox
        self.clock = clock
        self.now = now
        self.calendar = calendar
        self.line = line
    }

    /// Follows the settings: starts the wait for the next coffee break, or stops it. A change of the time starts the wait
    /// again; the same settings change nothing.
    ///
    /// - Parameter rules: the Inbox's rules, which hold the switch and the time
    public func apply(_ rules: InboxNotificationRules) {
        let changed = rules.coffeeBreak != self.rules.coffeeBreak || rules.coffeeMinutes != self.rules.coffeeMinutes
        self.rules = rules
        guard changed || loop == nil else {
            return
        }
        loop?.cancel()
        loop = nil
        guard rules.coffeeBreak else {
            return
        }
        let minutes = rules.coffeeMinutes
        loop = Task { [weak self] in
            // A launch inside the window still brings today's.
            if let today = self?.occurrence(onOrBefore: self?.now() ?? Date(), minutes: minutes) {
                await self?.deliver(scheduledFor: today)
            }
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let date = self.now()
                guard let next = Self.next(after: date, minutes: minutes, calendar: self.calendar) else {
                    return
                }
                do {
                    try await self.clock.sleep(for: .seconds(max(next.timeIntervalSince(date), 1)))
                } catch {
                    return
                }
                await self.deliver(scheduledFor: next)
            }
        }
    }

    /// Stops the wait.
    public func stop() {
        loop?.cancel()
        loop = nil
        rules = InboxNotificationRules()
    }

    /// Adds the entry of a coffee break that was due at a time, unless the window passed or today's entry is there.
    ///
    /// - Parameter scheduled: when it was due
    func deliver(scheduledFor scheduled: Date) async {
        let date = now()
        guard date.timeIntervalSince(scheduled) < Self.window, date >= scheduled else {
            return
        }
        let id = InboxEvent.coffeeID(on: scheduled, calendar: calendar)
        guard !inbox.wasAnnounced(id) else {
            return
        }
        let text = await line(scheduled)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = text?.isEmpty == false ? text! : Self.fallbackLine(on: scheduled, calendar: calendar)
        inbox.addLocal(.coffeeBreak(line: chosen, at: date, calendar: calendar))
        // Yesterday's is done when today's arrives.
        inbox.resolveLocal(kind: .coffeeBreak, idPrefix: InboxEvent.coffeeIDPrefix, except: id)
    }

    /// today's time, when it is a weekday and has come
    private func occurrence(onOrBefore date: Date, minutes: Int) -> Date? {
        guard let today = Self.occurrence(on: date, minutes: minutes, calendar: calendar), today <= date else {
            return nil
        }
        return today
    }

    // MARK: - The time

    /// Returns the coffee break of a day: its time, on Monday to Friday.
    ///
    /// - Parameters:
    ///   - day: any time of the day
    ///   - minutes: the time, in minutes after midnight
    ///   - calendar: the calendar
    /// - Returns: the time; `nil` on a Saturday or a Sunday
    public static func occurrence(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: day)
        guard (2...6).contains(weekday) else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day))
    }

    /// Returns the next coffee break after a time.
    ///
    /// - Parameters:
    ///   - date: now
    ///   - minutes: the time, in minutes after midnight
    ///   - calendar: the calendar
    /// - Returns: the next weekday's time after `date`
    public static func next(after date: Date, minutes: Int, calendar: Calendar) -> Date? {
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                let candidate = occurrence(on: day, minutes: minutes, calendar: calendar), candidate > date
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    // MARK: - The lines

    /// the lines that stand in while Claude is off, not set up or didn't answer: one a day, in turn
    public static let fallbackLines = [
        "The coffee is brewing and the merge requests can wait ten minutes.",
        "Coffee break: the only deploy we trust before noon.",
        "Step away from the keyboard. The build will still be red when you're back.",
        "Time for coffee. Warm cups, cold pipelines, that's the plan.",
        "Break time! Bring your own mug and your worst pun.",
        "Whatever you're debugging, the coffee machine has seen worse.",
        "Coffee o'clock. Please do not push to main while holding a cup.",
        "A short break now saves a long stack trace later.",
        "The kettle is on. The flaky test can flake without you.",
        "Join the coffee break: zero story points, maximum morale.",
        "Fresh coffee, fresh rebase. One of them is optional.",
        "Pause the sprint, pour a cup, argue about tabs versus spaces.",
        "Your next commit will taste better after a coffee.",
        "Coffee break! Tell a colleague something that isn't about Jenkins.",
        "Ten minutes, one cup, no meetings. Doctor's orders.",
    ]

    /// Returns a day's built-in line, one after the other through the year.
    ///
    /// - Parameters:
    ///   - date: the day
    ///   - calendar: the calendar
    public static func fallbackLine(on date: Date, calendar: Calendar) -> String {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return fallbackLines[day % fallbackLines.count]
    }
}

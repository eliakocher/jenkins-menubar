import Foundation

extension ClaudePrompt {
    /// the system prompt of the coffee break's line
    static let coffeeBreakInstructions = """
        You write one short, funny line that invites a software team to its daily coffee break. One or two sentences, \
        under 140 characters, friendly and a little silly. No names, no hashtags, no quotes, no emoji at the start. \
        Answer with the line only.
        """

    /// the angles of the line, one a day in turn, so the lines don't repeat
    static let coffeeAngles = [
        "the coffee machine", "a pun about brewing", "pretending the coffee is a deployment", "a merge request that can wait",
        "the first sip", "a flaky test that will pass after coffee", "stepping away from the keyboard", "the office mug collection",
        "a rubber duck that wants a break", "a very small celebration", "the smell of coffee", "tabs versus spaces, over coffee",
    ]

    /// Returns the prompt of a day's coffee break line. It holds only the weekday and the angle: nothing of the user's
    /// data, so there is nothing to review or redact.
    ///
    /// - Parameters:
    ///   - date: the day
    ///   - calendar: the calendar
    /// - Returns: the prompt
    static func coffeeBreak(on date: Date, calendar: Calendar) -> ClaudePrompt {
        let weekday = date.formatted(Date.FormatStyle().weekday(.wide).locale(Locale(identifier: "en_US")))
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let angle = coffeeAngles[day % coffeeAngles.count]
        return ClaudePrompt(
            useCase: .coffeeBreak, instructions: coffeeBreakInstructions,
            text: "Today is \(weekday). The angle for today's line: \(angle).")
    }

    /// Cleans Claude's line: the first non-empty line, without quotes or asterisks around it, cut to 140 characters.
    ///
    /// - Parameter text: what Claude answered
    /// - Returns: the line; `nil` when there is none
    static func coffeeLine(from text: String?) -> String? {
        guard let first = text?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else {
            return nil
        }
        let line = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”*_ "))
        guard !line.isEmpty else {
            return nil
        }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }
}

extension AIStore {
    /// Asks Haiku for the line of a day's coffee break (``CoffeeBreak``): no tools, safe mode, a few cents at most, and
    /// nothing of the user's data in it. It runs without a review because there is nothing to review; the user turned the
    /// Claude features on, and the coffee break itself is on unless they turned it off.
    ///
    /// - Parameters:
    ///   - date: the day
    ///   - calendar: the calendar
    /// - Returns: the line; `nil` while the Claude features are off or `claude` isn't there, and when it didn't answer
    public func coffeeLine(on date: Date, calendar: Calendar = .current) async -> String? {
        guard settings.isEnabled else {
            return nil
        }
        await detect()
        guard isOffered else {
            return nil
        }
        let prompt = ClaudePrompt.coffeeBreak(on: date, calendar: calendar)
        do {
            let run = try await engine.run(prompt, model: .haiku)
            count(run, prompt: prompt, model: .haiku)
            outdatedClaude = nil
            return ClaudePrompt.coffeeLine(from: run.text)
        } catch {
            if let run = error.run {
                count(run, prompt: prompt, model: .haiku)
            } else {
                record("Claude: \(prompt.useCase.logName) failed, the built-in line stands in", level: .warning, source: .app)
            }
            noteOutdated(error)
            return nil
        }
    }
}

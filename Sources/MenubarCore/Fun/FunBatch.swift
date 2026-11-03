import Foundation

/// Haiku's daily batch of fresh lines for the fun layer: one call asks for a handful of lines of every ``FunKey``, and the
/// app draws from them all day, never waiting for Claude.
///
/// The prompt holds no data of the user's: the keys' fixed descriptions, the weekday and the season, nothing else. The
/// numbers of a moment (a streak, a duration) are tokens like `{d}` that the app fills in when it draws the line.
public enum FunBatch {
    /// how many lines of each key the prompt asks for
    public static let linesPerKey = 5

    /// the system prompt: fixed app text
    static let instructions = """
        You write short, funny, friendly lines for a software team's build monitor, which has a butler as its mascot. \
        Each line is one sentence, between 20 and 110 characters. Be kind: tease builds, tests, Fridays and the butler, \
        never a person. No names of people or companies, no hashtags, no quotes, no emoji at the start. Never write a \
        digit; where a description names a token in braces, like {d}, you may write that token itself. \
        Answer with one JSON object only: its keys are the given keys, each holds an array of exactly the asked number \
        of different lines. No markdown, no explanation.
        """

    /// Returns the prompt of a day's batch. It holds only the fixed key descriptions, the weekday and the season.
    ///
    /// - Parameters:
    ///   - date: the day
    ///   - calendar: the calendar
    static func prompt(on date: Date, calendar: Calendar) -> ClaudePrompt {
        let weekday = date.formatted(Date.FormatStyle().weekday(.wide).locale(Locale(identifier: "en_US")))
        var text = "Today is \(weekday), in \(season(of: date, calendar: calendar)). "
        text += "Write \(linesPerKey) fresh lines for each of these keys:\n"
        for key in FunKey.allCases {
            text += "- \(key.rawValue): \(key.promptHint)\n"
        }
        return ClaudePrompt(useCase: .funBatch, instructions: instructions, text: text)
    }

    /// the season of the northern hemisphere, in words
    static func season(of date: Date, calendar: Calendar) -> String {
        switch calendar.component(.month, from: date) {
        case 3...5: "spring"
        case 6...8: "summer"
        case 9...11: "autumn"
        default: "winter"
        }
    }

    /// Reads Haiku's answer: the JSON object, also when it came wrapped in a code fence or a sentence.
    ///
    /// - Parameter text: what Claude answered
    /// - Returns: the lines by key; `nil` when there is no JSON object of string arrays
    static func parse(_ text: String?) -> [String: [String]]? {
        guard let text, let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            return nil
        }
        let json = Data(text[open...close].utf8)
        return try? JSONDecoder().decode([String: [String]].self, from: json)
    }

    /// Returns a line cleaned and checked, or `nil` when it can't be used.
    ///
    /// A usable line is one line of 12 to 140 characters, with no digit and no brace except its key's tokens, no link and no
    /// `@`: a line that states a number would be wrong the next time it is drawn.
    ///
    /// - Parameters:
    ///   - raw: what Haiku wrote
    ///   - key: the key it is for
    static func usable(_ raw: String, for key: FunKey) -> String? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”*_ \n\t-•"))
        guard (12...140).contains(line.count), !line.contains("\n") else {
            return nil
        }
        var rest = line
        for token in key.tokens {
            rest = rest.replacingOccurrences(of: token, with: "")
        }
        let forbidden = rest.contains { $0.isNumber || $0 == "{" || $0 == "}" || $0 == "@" }
        guard !forbidden, !rest.lowercased().contains("http"), !rest.lowercased().contains("www.") else {
            return nil
        }
        return line
    }
}

extension AIStore {
    /// Asks Haiku for a day's batch of fresh lines: no tools, safe mode, a few cents, and nothing of the user's data in it.
    /// It runs without a review because there is nothing to review.
    ///
    /// - Parameters:
    ///   - date: the day
    ///   - calendar: the calendar
    /// - Returns: the lines by key; `nil` while the Claude features are off or `claude` isn't there, and when it didn't answer
    public func funBatch(on date: Date, calendar: Calendar = .current) async -> [String: [String]]? {
        guard settings.isEnabled else {
            return nil
        }
        await detect()
        guard isOffered else {
            return nil
        }
        let prompt = FunBatch.prompt(on: date, calendar: calendar)
        do {
            let run = try await engine.run(prompt, model: .haiku)
            count(run, prompt: prompt, model: .haiku)
            outdatedClaude = nil
            return run.decoded([String: [String]].self) ?? FunBatch.parse(run.text)
        } catch {
            if let run = error.run {
                count(run, prompt: prompt, model: .haiku)
            } else {
                record("Claude: \(prompt.useCase.logName) failed, the built-in lines stand in", level: .warning, source: .app)
            }
            noteOutdated(error)
            return nil
        }
    }
}

import Foundation

/// The Claude models the app offers (AI-01), Opus by default. The costs are the measured ones of `docs/decisions.md`
/// (one build explanation, 2026-10-29), shown in Settings so the choice is made with them in view.
public enum ClaudeModel: String, Codable, Hashable, Sendable, CaseIterable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    /// "Claude Opus 5.5"
    public var title: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    /// what an answer about costs, as measured: "about 2¢ an answer"
    public var typicalCost: String {
        switch self {
        case .opus: "about 2¢ an answer"
        case .sonnet: "about 1¢ an answer"
        case .haiku: "about 0.1¢ an answer"
        }
    }
}

/// What the app asks Claude for: one use case per AI feature (AI-02 to AI-05), named in the log and in the cost.
public enum AIUseCase: String, Codable, Hashable, Sendable, CaseIterable {
    case explainBuild
    case summarizeThreads
    case digest
    case openInClaudeCode

    /// the use case's name in the log: "explain a failed build"
    public var logName: String {
        switch self {
        case .explainBuild: "explain a failed build"
        case .summarizeThreads: "summarize a discussion"
        case .digest: "daily digest"
        case .openInClaudeCode: "open in Claude Code"
        }
    }
}

/// Settings → General's Claude section (AI-01): off by default, the model, the monthly cap and the morning digest.
///
/// Kept in the user's own preferences (`ai` in UserDefaults), never in the team file: each developer brings their own
/// Claude Code login and pays their own use.
public struct AISettings: Codable, Hashable, Sendable {
    /// whether the Claude features show at all; off until the user turns them on
    public var isEnabled: Bool
    public var model: ClaudeModel
    /// the most the reported costs may sum to in a calendar month, in US dollars, one of ``capOptions``
    public var monthlyCapUSD: Int
    /// whether the digest is written by itself each morning and posted as a notification; off by default
    public var morningDigest: Bool
    /// when the morning digest is written, in minutes after midnight, local time
    public var digestMinutes: Int
    /// the use cases whose prompt the user has seen and sent once; the others show what they send first
    public var confirmedUseCases: Set<AIUseCase>

    public init(
        isEnabled: Bool = false, model: ClaudeModel = .opus, monthlyCapUSD: Int = 10, morningDigest: Bool = false,
        digestMinutes: Int = 9 * 60, confirmedUseCases: Set<AIUseCase> = []
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.monthlyCapUSD = monthlyCapUSD
        self.morningDigest = morningDigest
        self.digestMinutes = digestMinutes
        self.confirmedUseCases = confirmedUseCases
    }

    /// $2, $5, $10 (default), $20, $50 or $100 a month
    public static let capOptions = [2, 5, 10, 20, 50, 100]

    private enum CodingKeys: String, CodingKey {
        case isEnabled, model, monthlyCapUSD, morningDigest, digestMinutes, confirmedUseCases
    }

    // A value written by another version, with fields this one doesn't know or lacks, still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        model = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? defaults.model
        monthlyCapUSD = (try? container.decodeIfPresent(Int.self, forKey: .monthlyCapUSD)) ?? defaults.monthlyCapUSD
        morningDigest = (try? container.decodeIfPresent(Bool.self, forKey: .morningDigest)) ?? defaults.morningDigest
        digestMinutes = (try? container.decodeIfPresent(Int.self, forKey: .digestMinutes)) ?? defaults.digestMinutes
        let confirmed = (try? container.decodeIfPresent([String].self, forKey: .confirmedUseCases)) ?? []
        confirmedUseCases = Set(confirmed.compactMap(AIUseCase.init(rawValue:)))
        if !Self.capOptions.contains(monthlyCapUSD) {
            monthlyCapUSD = defaults.monthlyCapUSD
        }
        digestMinutes = min(max(digestMinutes, 0), 24 * 60 - 1)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(model, forKey: .model)
        try container.encode(monthlyCapUSD, forKey: .monthlyCapUSD)
        try container.encode(morningDigest, forKey: .morningDigest)
        try container.encode(digestMinutes, forKey: .digestMinutes)
        try container.encode(confirmedUseCases.map(\.rawValue).sorted(), forKey: .confirmedUseCases)
    }

    // MARK: - Kept in UserDefaults

    /// the UserDefaults key, in the preferences' suite
    public static let defaultsKey = "ai"

    /// Reads the settings; none stored, or unreadable, reads as the defaults: off.
    public static func load(from defaults: UserDefaults) -> AISettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    /// Keeps the settings.
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// What Claude cost this calendar month, summed from the costs `claude` reports (AI-01). A new month starts at zero.
public struct AIUsage: Codable, Hashable, Sendable {
    /// the month, like `2026-10`
    public var month: String
    public var costUSD: Double
    public var answers: Int
    public var inputTokens: Int
    public var outputTokens: Int

    public init(month: String, costUSD: Double = 0, answers: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.month = month
        self.costUSD = costUSD
        self.answers = answers
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Returns the month of a date, local time: `2026-10`.
    public static func month(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Returns this usage for a month: itself in its own month, zero in another.
    public func current(in month: String) -> AIUsage {
        self.month == month ? self : AIUsage(month: month)
    }

    /// Returns the usage with one more answer added, in the month given; a new month starts from zero.
    public func adding(costUSD cost: Double, usage: ClaudeUsage, month: String) -> AIUsage {
        var next = current(in: month)
        next.costUSD += max(cost, 0)
        next.answers += 1
        next.inputTokens += usage.inputTokens
        next.outputTokens += usage.outputTokens
        return next
    }

    /// the UserDefaults key, in the preferences' suite
    public static let defaultsKey = "ai.usage"

    /// Reads the usage; none stored reads as nothing spent this month.
    public static func load(from defaults: UserDefaults, month: String) -> AIUsage {
        guard let data = defaults.data(forKey: defaultsKey), let usage = try? JSONDecoder().decode(AIUsage.self, from: data) else {
            return AIUsage(month: month)
        }
        return usage.current(in: month)
    }

    /// Keeps the usage.
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// The monthly cost cap (AI-01): the reported costs of the month are summed; at the cap, nothing more is sent until the
/// next month or a higher cap. Each answer may cost at most what is left, and at most ``perAnswerUSD``, which `claude`
/// enforces with `--max-budget-usd`.
public enum AICostCap {
    /// the most one answer may cost
    public static let perAnswerUSD = 1.0
    /// below this, nothing is left to spend
    public static let smallestBudgetUSD = 0.01

    /// What may still be spent.
    public enum Allowance: Hashable, Sendable {
        /// an answer may cost up to this much
        case allowed(budgetUSD: Double)
        /// the month's costs reached the cap
        case reached(spentUSD: Double, capUSD: Int)
    }

    /// Returns what the next answer may cost.
    ///
    /// - Parameters:
    ///   - usage: this month's usage
    ///   - capUSD: the monthly cap
    /// - Returns: the budget of the next answer, or that the cap is reached
    public static func allowance(usage: AIUsage, capUSD: Int) -> Allowance {
        let left = Double(capUSD) - usage.costUSD
        guard left >= smallestBudgetUSD else {
            return .reached(spentUSD: usage.costUSD, capUSD: capUSD)
        }
        return .allowed(budgetUSD: min(left, perAnswerUSD))
    }

    /// "This month's Claude answers reached the $10 cap ($10.02). Raise it in Settings → General."
    public static func reachedMessage(spentUSD: Double, capUSD: Int) -> String {
        "This month's Claude answers reached the $\(capUSD) cap (\(AIFormat.cost(spentUSD))). Raise it in Settings → "
            + "General, or wait for next month."
    }
}

/// How the AI features write costs and tokens.
public enum AIFormat {
    /// "$0.017", "$1.20", "$0.0008"
    public static func cost(_ usd: Double) -> String {
        if usd >= 1 {
            return String(format: "$%.2f", usd)
        }
        if usd >= 0.01 {
            return String(format: "$%.3f", usd)
        }
        return String(format: "$%.4f", usd)
    }

    /// "1,407 tokens in, 275 out · $0.017 · 4.5 s"
    public static func usageLine(_ usage: ClaudeUsage, costUSD: Double, seconds: Double?) -> String {
        let number = IntegerFormatStyle<Int>.number
        var parts = ["\(usage.inputTokens.formatted(number)) tokens in, \(usage.outputTokens.formatted(number)) out", cost(costUSD)]
        if let seconds {
            parts.append(String(format: "%.1f s", seconds))
        }
        return parts.joined(separator: " · ")
    }
}

import Foundation

/// The Claude models the app offers (AI-01), Opus by default.
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

    /// "Opus 5.5": the name on a card and in a menu
    public var shortName: String {
        String(title.dropFirst("Claude ".count))
    }

}

/// How long Claude thinks before it answers (`claude --effort`). `.standard` passes no flag: Claude's own default.
public enum ClaudeEffort: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case low
    case medium
    case high
    case xhigh
    case max

    /// "Default", "Low", "Medium", "High", "Extra High", "Max"
    public var title: String {
        switch self {
        case .standard: "Default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }

    /// the level `--effort` takes, or `nil` for Claude's own default
    public var level: String? {
        self == .standard ? nil : rawValue
    }

    /// the levels the `.command` script may pass, as its `case` pattern: `low|medium|high|xhigh|max`
    static var levelPattern: String {
        allCases.compactMap(\.level).joined(separator: "|")
    }
}

/// What the app asks Claude for: one use case per AI feature (AI-02 to AI-05), named in the log.
public enum AIUseCase: String, Codable, Hashable, Sendable, CaseIterable {
    case explainBuild
    case summarizeThreads
    case digest
    case openInClaudeCode
    /// a question about a merge request's code (AI-07)
    case askAboutCode
    /// a question about a work item (AI-08)
    case askAboutItem

    /// the use case's name in the log: "explain a failed build"
    public var logName: String {
        switch self {
        case .explainBuild: "explain a failed build"
        case .summarizeThreads: "summarize a discussion"
        case .digest: "daily digest"
        case .openInClaudeCode: "open in Claude Code"
        case .askAboutCode: "ask about code"
        case .askAboutItem: "ask about a work item"
        }
    }
}

/// Settings → General's Claude section (AI-01): off by default, the model, the effort and the morning digest.
///
/// Kept in the user's own preferences (`ai` in UserDefaults), never in the team file: each developer brings their own
/// Claude Code login.
public struct AISettings: Codable, Hashable, Sendable {
    /// whether the Claude features show at all; off until the user turns them on
    public var isEnabled: Bool
    public var model: ClaudeModel
    /// how long Claude thinks; Default passes no flag
    public var effort: ClaudeEffort
    /// whether the digest is written by itself each morning and posted as a notification; off by default
    public var morningDigest: Bool
    /// when the morning digest is written, in minutes after midnight, local time
    public var digestMinutes: Int
    /// the use cases whose prompt the user has seen and sent once; the others show what they send first
    public var confirmedUseCases: Set<AIUseCase>
    /// whether the chats load the user's own Claude Code setup (skills, plugins, commands, MCP servers) instead of
    /// `--safe-mode`, with reading tools only (AI-09); off by default
    public var useMySetup: Bool
    /// whether that setup includes the user's CLAUDE.md files; on by default
    public var useMyClaudeMd: Bool
    /// the user's own choice of MCP servers for the chats, by the server's tool-name prefix; a server not in it follows
    /// ``McpServerGroup/isOnByDefault`` (AI-09)
    public var mcpServerChoices: [String: Bool]

    public init(
        isEnabled: Bool = false, model: ClaudeModel = .opus, effort: ClaudeEffort = .standard, morningDigest: Bool = false,
        digestMinutes: Int = 9 * 60, confirmedUseCases: Set<AIUseCase> = [], useMySetup: Bool = false, useMyClaudeMd: Bool = true,
        mcpServerChoices: [String: Bool] = [:]
    ) {
        self.isEnabled = isEnabled
        self.model = model
        self.effort = effort
        self.morningDigest = morningDigest
        self.digestMinutes = digestMinutes
        self.confirmedUseCases = confirmedUseCases
        self.useMySetup = useMySetup
        self.useMyClaudeMd = useMyClaudeMd
        self.mcpServerChoices = mcpServerChoices
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, model, effort, morningDigest, digestMinutes, confirmedUseCases, useMySetup, useMyClaudeMd, mcpServerChoices
    }

    // A value written by another version, with fields this one doesn't know or lacks, still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? defaults.isEnabled
        model = (try? container.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? defaults.model
        effort = (try? container.decodeIfPresent(ClaudeEffort.self, forKey: .effort)) ?? defaults.effort
        morningDigest = (try? container.decodeIfPresent(Bool.self, forKey: .morningDigest)) ?? defaults.morningDigest
        digestMinutes = (try? container.decodeIfPresent(Int.self, forKey: .digestMinutes)) ?? defaults.digestMinutes
        let confirmed = (try? container.decodeIfPresent([String].self, forKey: .confirmedUseCases)) ?? []
        confirmedUseCases = Set(confirmed.compactMap(AIUseCase.init(rawValue:)))
        digestMinutes = min(max(digestMinutes, 0), 24 * 60 - 1)
        useMySetup = (try? container.decodeIfPresent(Bool.self, forKey: .useMySetup)) ?? defaults.useMySetup
        useMyClaudeMd = (try? container.decodeIfPresent(Bool.self, forKey: .useMyClaudeMd)) ?? defaults.useMyClaudeMd
        mcpServerChoices = (try? container.decodeIfPresent([String: Bool].self, forKey: .mcpServerChoices)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
        try container.encode(morningDigest, forKey: .morningDigest)
        try container.encode(digestMinutes, forKey: .digestMinutes)
        try container.encode(confirmedUseCases.map(\.rawValue).sorted(), forKey: .confirmedUseCases)
        try container.encode(useMySetup, forKey: .useMySetup)
        try container.encode(useMyClaudeMd, forKey: .useMyClaudeMd)
        try container.encode(mcpServerChoices, forKey: .mcpServerChoices)
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

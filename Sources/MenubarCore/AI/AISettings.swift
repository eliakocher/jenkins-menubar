import Foundation

/// The Claude models the app offers (AI-01), Sonnet by default.
///
/// The raw value is the CLI's own **alias** (`--model opus`): `claude` maps it to the newest model of that family it
/// knows, so an older Claude Code keeps working and an update brings the newer model by itself. A pinned id like
/// `claude-opus-5-5` made an older `claude` answer "does not support this model". Settings saved by earlier versions
/// hold such ids; they still decode, to the alias of their family.
public enum ClaudeModel: String, Codable, Hashable, Sendable, CaseIterable {
    case opus
    case sonnet
    case haiku

    /// Returns the model a name stands for: an alias (`opus`) or an id of its family (`claude-opus-5-5`, even with a
    /// date or a `[1m]` suffix); `nil` for anything else.
    ///
    /// - Parameter name: the alias or the model id
    public init?(modelName name: String) {
        let lowered = name.lowercased()
        if let alias = Self(rawValue: lowered) {
            self = alias
        } else if lowered.hasPrefix("claude"), let family = Self.allCases.first(where: { lowered.contains($0.rawValue) }) {
            self = family
        } else {
            return nil
        }
    }

    // A value saved by an earlier version holds a pinned id; one that is none of the families fails, so the setting reads as its default.
    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let model = Self(modelName: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown model \(name)"))
        }
        self = model
    }

    /// "Claude Opus": the name in the log
    public var title: String {
        "Claude \(shortName)"
    }

    /// "Opus": the name in a menu; the version is the CLI's newest, so it isn't named
    public var shortName: String {
        rawValue.capitalized
    }

    /// Returns the name of the model that answered, from the id `claude` reports: "Opus 5.5" for `claude-opus-5-5`, "Opus"
    /// for an alias, or the id as reported when it is none of the families.
    ///
    /// - Parameter id: the model id of an answer
    public static func displayName(ofModel id: String) -> String {
        let lowered = id.lowercased()
        let base = lowered.split(separator: "[", maxSplits: 1).first.map(String.init) ?? lowered
        let parts = base.split(separator: "-").map(String.init)
        if let alias = Self(rawValue: base) {
            return alias.shortName
        }
        guard parts.count >= 2, parts[0] == "claude", let family = Self(rawValue: parts[1]) else {
            return id
        }
        // The version is the one or two short numbers after the family; a longer number is a date.
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? family.shortName : "\(family.shortName) \(version.joined(separator: "."))"
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
    /// a question about a build, whatever its result: its log, stages, tests and changes
    case buildChat
    /// the daily coffee break's one line, written by Haiku (``CoffeeBreak``)
    case coffeeBreak
    /// the fun layer's daily batch of fresh lines, written by Haiku (``FunBatch``)
    case funBatch

    /// the use case's name in the log: "explain a failed build"
    public var logName: String {
        switch self {
        case .explainBuild: "explain a failed build"
        case .summarizeThreads: "summarize a discussion"
        case .digest: "daily digest"
        case .openInClaudeCode: "open in Claude Code"
        case .askAboutCode: "ask about code"
        case .askAboutItem: "ask about a work item"
        case .buildChat: "ask about a build"
        case .coffeeBreak: "coffee break line"
        case .funBatch: "fun lines"
        }
    }
}

/// Settings → Claude's section (AI-01): on by default (shown only while `claude` is installed), Sonnet, the effort and the
/// morning digest, also on by default.
///
/// Kept in the user's own preferences (`ai` in UserDefaults), never in the team file: each developer brings their own
/// Claude Code login.
public struct AISettings: Codable, Hashable, Sendable {
    /// whether the Claude features show at all; on unless the user turns them off, and offered only while `claude` is installed
    public var isEnabled: Bool
    public var model: ClaudeModel
    /// how long Claude thinks; Default passes no flag
    public var effort: ClaudeEffort
    /// whether the digest is written by itself each morning, and added to the Inbox while the Digest isn't on screen; on by default
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
        isEnabled: Bool = true, model: ClaudeModel = .sonnet, effort: ClaudeEffort = .standard, morningDigest: Bool = true,
        digestMinutes: Int = 8 * 60, confirmedUseCases: Set<AIUseCase> = [], useMySetup: Bool = false, useMyClaudeMd: Bool = true,
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

    /// Reads the settings; none stored, or unreadable, reads as the defaults: on, with Sonnet and the morning digest. A
    /// saved value keeps its own choices, and a field it lacks takes the default.
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

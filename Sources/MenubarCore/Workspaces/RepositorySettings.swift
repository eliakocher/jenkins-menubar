import Foundation

/// Where the user's git checkouts are, and how one opens in their IDE: Settings → Repositories (WS-01).
///
/// Kept in the user's own preferences, never in the team file: a shared file must never carry something the app runs
/// (the plan's rules for commands). No path is built in; a new user starts with none.
public struct RepositorySettings: Codable, Hashable, Sendable {
    /// the folders and patterns the checkouts are found in, in the user's order
    public var folders: [RepositoryFolder]
    /// the Open in IDE command line, like `code {path}`; empty for none (``LaunchCommand``)
    public var ideCommand: String

    public init(folders: [RepositoryFolder] = [], ideCommand: String = "") {
        self.folders = folders
        self.ideCommand = ideCommand
    }

    private enum CodingKeys: String, CodingKey {
        case folders, ideCommand
    }

    // A value written by a later version, with fields this one doesn't know, still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([RepositoryFolder].self, forKey: .folders) ?? []
        ideCommand = try container.decodeIfPresent(String.self, forKey: .ideCommand) ?? ""
    }

    // MARK: - Kept in UserDefaults

    /// the UserDefaults key, in the preferences' suite
    public static let defaultsKey = "repositories"

    /// Reads the settings.
    ///
    /// - Parameter defaults: the preferences' suite
    /// - Returns: the stored settings; none stored, or unreadable, reads as empty
    public static func load(from defaults: UserDefaults) -> RepositorySettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(RepositorySettings.self, from: data) else {
            return RepositorySettings()
        }
        return settings
    }

    /// Keeps the settings.
    ///
    /// - Parameter defaults: the preferences' suite
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// One entry of Settings → Repositories: a checkout's folder, or a pattern whose `*` stands for one folder level, like
/// `~/workspaces/*/project` for several full clones side by side (WS-01).
public struct RepositoryFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// an absolute path, `~` for the home folder; a component with `*` or `?` matches folders at that level
    public var path: String
    /// the branch tasks start from and merge into, `develop` by default; compared as `origin/<base>`
    public var baseBranch: String

    /// the base branch of a new entry
    public static let defaultBaseBranch = "develop"

    public init(id: UUID = UUID(), path: String, baseBranch: String = RepositoryFolder.defaultBaseBranch) {
        self.id = id
        self.path = path
        self.baseBranch = baseBranch
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, baseBranch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch) ?? Self.defaultBaseBranch
    }

    /// the base branch to compare with: the typed one without spaces, or `develop` when empty
    public var effectiveBaseBranch: String {
        let trimmed = baseBranch.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultBaseBranch : trimmed
    }
}

/// The branch names the app passes to `git`: a name that git could read as an option or a range is refused, so a
/// typo in Settings can never become a different git command (the plan's rules for commands).
public enum BranchNameRule {
    /// Returns whether a base branch name is safe to put into `origin/<base>...HEAD` and `<base>..origin/<base>`.
    ///
    /// - Parameter name: the name as typed
    /// - Returns: `false` for an empty name, one starting with `-` or `/`, or one with spaces, control characters,
    ///   `..`, `@{` or any of `~^:?*[\`
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("@{"), !name.contains("//") else {
            return false
        }
        let refused = Set("~^:?*[\\ ")
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value != 0x7F && !refused.contains(Character(scalar))
        }
    }
}

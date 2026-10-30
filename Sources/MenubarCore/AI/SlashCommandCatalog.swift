import Foundation

/// A slash command or skill of the user's Claude Code setup, for the "/" list in a chat (AI-09).
public struct SlashCommand: Hashable, Sendable, Identifiable {
    /// where it comes from
    public enum Source: Hashable, Sendable {
        /// the user's `~/.claude`
        case user
        /// the `.claude` folder of the checkout
        case project
        /// an installed plugin, by name
        case plugin(String)

        /// "Yours", "Project", or the plugin's name: the small label in the list
        public var label: String {
            switch self {
            case .user: "Yours"
            case .project: "Project"
            case .plugin(let name): name
            }
        }
    }

    /// whether it is a command (`commands/name.md`) or a skill (`skills/name/SKILL.md`)
    public enum Kind: Hashable, Sendable {
        case command
        case skill
    }

    /// the name as typed after the slash: `review-branch`, `acme-git:create-issue`
    public var name: String
    /// the one-line description; empty when the file has none
    public var summary: String
    public var source: Source
    public var kind: Kind
    /// whether it may ask the developer questions along the way, which a headless run can't answer: its text mentions
    /// `AskUserQuestion`, or it is for the developer's own invocation only (`disable-model-invocation`)
    public var mayNeedInteraction: Bool

    public var id: String { "\(source.label)/\(name)" }

    public init(name: String, summary: String, source: Source, kind: Kind, mayNeedInteraction: Bool = false) {
        self.name = name
        self.summary = summary
        self.source = source
        self.kind = kind
        self.mayNeedInteraction = mayNeedInteraction
    }
}

/// Finds the user's slash commands and skills and filters them for the "/" list (AI-09). Pure file reading: nothing here
/// starts `claude`.
///
/// Where Claude Code keeps them: `~/.claude/commands/**.md` and `~/.claude/skills/*/SKILL.md`; the same under a
/// checkout's `.claude/`; and for each installed plugin, listed in `~/.claude/plugins/installed_plugins.json` with its
/// `installPath`, `commands/**.md` and `skills/*/SKILL.md`, named `plugin:name`. A plugin turned off in
/// `~/.claude/settings.json` (`enabledPlugins`) is left out.
public enum SlashCommandCatalog {
    /// the largest part of a file read for its description and its check for questions
    static let readLimit = 200_000
    /// the longest summary kept, in characters
    static let summaryLimit = 160

    // MARK: - Reading the folders

    /// Reads every command and skill the setup has.
    ///
    /// - Parameters:
    ///   - home: the user's home folder
    ///   - project: a checkout whose own `.claude` counts too; `nil` for none
    ///   - fileManager: the file manager
    /// - Returns: the commands, the checkout's first, then the user's, then each plugin's, each group by name
    public static func scan(home: URL, project: URL? = nil, fileManager: FileManager = .default) -> [SlashCommand] {
        let claude = home.appending(path: ".claude", directoryHint: .isDirectory)
        var found: [SlashCommand] = []
        if let project {
            found += readFolder(project.appending(path: ".claude", directoryHint: .isDirectory), source: .project, prefix: nil, fileManager: fileManager)
        }
        found += readFolder(claude, source: .user, prefix: nil, fileManager: fileManager)
        for plugin in installedPlugins(claude: claude, fileManager: fileManager) {
            found += readFolder(plugin.folder, source: .plugin(plugin.name), prefix: plugin.name, fileManager: fileManager)
        }
        return found
    }

    /// the commands and skills of one `.claude`-like folder: its `commands` and `skills`
    static func readFolder(_ folder: URL, source: SlashCommand.Source, prefix: String?, fileManager: FileManager) -> [SlashCommand] {
        func named(_ name: String) -> String { prefix.map { "\($0):\(name)" } ?? name }
        var found: [SlashCommand] = []

        // `commands/dir/name.md` is `dir:name`.
        let commands = folder.appending(path: "commands", directoryHint: .isDirectory)
        if let files = fileManager.enumerator(at: commands, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files where file.pathExtension == "md" {
                guard let text = read(file) else { continue }
                let parts = commands.relativeComponents(of: file)
                guard let last = parts.last else { continue }
                let name = (parts.dropLast() + [String(last.dropLast(3))]).joined(separator: ":")
                let document = FrontMatter(text)
                found.append(
                    SlashCommand(
                        name: named(name), summary: document.summary(), source: source, kind: .command,
                        mayNeedInteraction: document.mayNeedInteraction))
            }
        }

        // `skills/name/SKILL.md`, called by its folder's name unless its front matter says another.
        let skills = folder.appending(path: "skills", directoryHint: .isDirectory)
        let entries = (try? fileManager.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            guard let text = read(entry.appending(path: "SKILL.md", directoryHint: .notDirectory)) else { continue }
            let document = FrontMatter(text)
            let name = document.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent
            found.append(
                SlashCommand(
                    name: named(name), summary: document.summary(), source: source, kind: .skill,
                    mayNeedInteraction: document.mayNeedInteraction))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// the installed plugins that are turned on, with their folders
    static func installedPlugins(claude: URL, fileManager: FileManager) -> [(name: String, folder: URL)] {
        guard let data = fileManager.contents(atPath: claude.appending(path: "plugins/installed_plugins.json").path(percentEncoded: false)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else {
            return []
        }
        // A plugin the settings turn off stays out; without the list, all count.
        var enabled: [String: Bool]?
        if let settings = fileManager.contents(atPath: claude.appending(path: "settings.json").path(percentEncoded: false)),
           let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] {
            enabled = object["enabledPlugins"] as? [String: Bool]
        }
        var found: [(name: String, folder: URL)] = []
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) {
            if let enabled, enabled[key] != true { continue }
            let installs = value as? [[String: Any]] ?? []
            guard let path = installs.last?["installPath"] as? String, path.hasPrefix("/") else { continue }
            let name = key.split(separator: "@", maxSplits: 1).first.map(String.init) ?? key
            found.append((name, URL(filePath: path, directoryHint: .isDirectory)))
        }
        return found
    }

    private static func read(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: readLimit) else {
            return nil
        }
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Front matter

    /// The front matter of a command or skill file: the `key: value` lines between two `---` lines, and the text after.
    struct FrontMatter {
        var fields: [String: String] = [:]
        var body: String

        init(_ text: String) {
            let lines = text.components(separatedBy: .newlines)
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
                  let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
                body = text
                return
            }
            body = lines[(end + 1)...].joined(separator: "\n")
            var key: String?
            var folded: [String] = []
            func close() {
                if let key { fields[key] = folded.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
                folded = []
            }
            for line in lines[1..<end] {
                if let first = line.first, first == " " || first == "\t" {
                    // A continuation of a folded or plain multi-line value.
                    folded.append(line.trimmingCharacters(in: .whitespaces))
                } else if let colon = line.firstIndex(of: ":"), !line.hasPrefix("#") {
                    close()
                    key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if value == ">" || value == "|" || value == ">-" || value == "|-" {
                        value = ""
                    }
                    folded = value.isEmpty ? [] : [unquoted(value)]
                }
            }
            close()
        }

        private func unquoted(_ value: String) -> String {
            guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
                return value
            }
            return String(value.dropFirst().dropLast())
        }

        /// the description's first sentence or line, cut to ``SlashCommandCatalog/summaryLimit``; with no description,
        /// the body's first line of words
        func summary() -> String {
            var text = fields["description"] ?? ""
            if text.isEmpty {
                text = body.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
                    .first { !$0.isEmpty && $0 != "---" } ?? ""
            }
            if text.count > SlashCommandCatalog.summaryLimit {
                text = String(text.prefix(SlashCommandCatalog.summaryLimit - 1)) + "…"
            }
            return text
        }

        /// whether it may need the developer's answers: it uses `AskUserQuestion`, or it is only for the developer
        var mayNeedInteraction: Bool {
            body.contains("AskUserQuestion")
                || fields["disable-model-invocation"]?.lowercased() == "true"
                || fields["allowed-tools"]?.contains("AskUserQuestion") == true
        }
    }

    // MARK: - Typing "/"

    /// Returns the command a message starts with, as typed after the slash: `/review-branch main` is
    /// `review-branch`. A path (`/Users/me/file`), a lone slash and a slash inside a word are not commands.
    ///
    /// - Parameter text: the message
    /// - Returns: the name, or `nil`
    public static func leadingCommand(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let first = name.first, first.isLetter || first.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || ":_.-".contains($0) }) else {
            return nil
        }
        return String(name)
    }

    /// Returns what the list filters by while the developer types the command's name: the text after the slash, when the
    /// whole field is a slash and the beginning of a name, with no space yet. After the space, the arguments are being
    /// typed and the list is closed.
    ///
    /// - Parameter text: the field's text
    /// - Returns: the query (empty right after the slash), or `nil` when the list isn't open
    public static func pendingQuery(in text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst())
    }

    /// Returns the text a pick puts in the field: the command and a space for its arguments.
    public static func insertion(for command: SlashCommand) -> String {
        "/\(command.name) "
    }

    /// Filters the commands by what is typed after the slash, case-insensitively. A name that starts with the query
    /// comes first (a plugin's `plugin:name` also by its `name`), then names that contain it, then descriptions that do;
    /// within a group the order stays. An empty query keeps everything.
    ///
    /// - Parameters:
    ///   - commands: the commands
    ///   - query: what was typed after the slash
    /// - Returns: the commands that match, best first
    public static func filter(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        var groups: [[SlashCommand]] = [[], [], []]
        for command in commands {
            let name = command.name.lowercased()
            let bare = name.split(separator: ":").last.map(String.init) ?? name
            if name.hasPrefix(query) || bare.hasPrefix(query) {
                groups[0].append(command)
            } else if name.contains(query) {
                groups[1].append(command)
            } else if command.summary.lowercased().contains(query) {
                groups[2].append(command)
            }
        }
        return groups.flatMap { $0 }
    }
}

private extension URL {
    /// the path components of `file` below this folder
    func relativeComponents(of file: URL) -> [String] {
        let base = standardizedFileURL.pathComponents
        let all = file.standardizedFileURL.pathComponents
        return Array(all.dropFirst(base.count))
    }
}

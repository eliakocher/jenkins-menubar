import Foundation

/// Finds the MCP servers the user's Claude Code config names, by file reading alone: nothing here starts `claude` (AI-09).
///
/// The server listing (``ClaudeInventory``) comes from a `claude` start that launches every MCP server, so it is made once
/// per app session. A server the user added since is not in it. Before a chat run the app reads the config's server names,
/// which is a few small files, and denies every name the listing doesn't know (``ClaudeSetup``).
///
/// Where Claude Code keeps servers, as `claude` names them in tool names (``McpServerGroup/key(ofServerNamed:)``):
/// - `~/.claude.json`: `mcpServers` (user scope), `projects.<folder>.mcpServers` (local scope), and
///   `claudeAiMcpEverConnected`, the claude.ai connectors it has seen (`claude.ai Name`);
/// - `.mcp.json` in the checkout and the folders above it (project scope);
/// - each installed plugin's `.mcp.json` and `.claude-plugin/plugin.json`, named `plugin:<plugin>:<server>`;
/// - the managed `managed-mcp.json`.
///
/// A connector added on claude.ai that no `claude` run has seen yet is in none of them; the listing's own refresh covers it.
public enum McpConfigScan {
    /// the folder of the managed MCP config (macOS)
    public static let managedFolder = URL(filePath: "/Library/Application Support/ClaudeCode", directoryHint: .isDirectory)

    /// What `~/.claude.json` names, parsed once and kept while the file doesn't change.
    public struct UserFile: Equatable, Sendable {
        /// the user-scope servers' names
        public var servers: [String] = []
        /// the claude.ai connectors' names
        public var connectors: [String] = []
        /// the local-scope servers' names by project folder
        public var projects: [String: [String]] = [:]

        public init(servers: [String] = [], connectors: [String] = [], projects: [String: [String]] = [:]) {
            self.servers = servers
            self.connectors = connectors
            self.projects = projects
        }
    }

    /// Reads `~/.claude.json`.
    ///
    /// - Parameters:
    ///   - home: the user's home folder
    ///   - fileManager: the file manager
    /// - Returns: what it names; nothing when the file is missing or unreadable
    public static func readUserFile(home: URL, fileManager: FileManager = .default) -> UserFile {
        guard let root = jsonObject(at: home.appending(path: ".claude.json", directoryHint: .notDirectory), fileManager) else {
            return UserFile()
        }
        var file = UserFile()
        file.servers = serverNames(in: root["mcpServers"])
        file.connectors = root["claudeAiMcpEverConnected"] as? [String] ?? []
        for (folder, value) in root["projects"] as? [String: Any] ?? [:] {
            let found = serverNames(in: (value as? [String: Any])?["mcpServers"])
            if !found.isEmpty { file.projects[folder] = found }
        }
        return file
    }

    /// Returns the keys of every server the config names that a run in `folder` could load.
    ///
    /// - Parameters:
    ///   - userFile: what `~/.claude.json` names
    ///   - home: the user's home folder
    ///   - folder: the folder the run starts in, the checkout; `nil` for none
    ///   - managed: the folder of the managed config
    ///   - fileManager: the file manager
    /// - Returns: the keys, as in the tools' names (`mcp__<key>__<tool>`)
    public static func serverKeys(
        userFile: UserFile, home: URL, folder: String?, managed: URL = managedFolder, fileManager: FileManager = .default
    ) -> Set<String> {
        var names = Set(userFile.servers + userFile.connectors)
        // The folder and the ones above it: a `.mcp.json` counts from any of them, and a project entry of `~/.claude.json`
        // is the folder's own.
        var url = folder.flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
        while let current = url, current.path(percentEncoded: false) != "/" {
            names.formUnion(userFile.projects[current.path(percentEncoded: false)] ?? [])
            names.formUnion(servers(inFile: current.appending(path: ".mcp.json", directoryHint: .notDirectory), fileManager))
            url = current.deletingLastPathComponent()
        }
        names.formUnion(servers(inFile: managed.appending(path: "managed-mcp.json", directoryHint: .notDirectory), fileManager))
        var keys = Set(names.map(McpServerGroup.key(ofServerNamed:)))
        let claude = home.appending(path: ".claude", directoryHint: .isDirectory)
        for plugin in SlashCommandCatalog.installedPlugins(claude: claude, fileManager: fileManager) {
            var inPlugin = Set(servers(inFile: plugin.folder.appending(path: ".mcp.json", directoryHint: .notDirectory), fileManager))
            let manifest = plugin.folder.appending(path: ".claude-plugin/plugin.json", directoryHint: .notDirectory)
            if let root = jsonObject(at: manifest, fileManager) {
                inPlugin.formUnion(serverNames(in: root["mcpServers"]))
            }
            keys.formUnion(inPlugin.map { McpServerGroup.key(ofServerNamed: "plugin:\(plugin.name):\($0)") })
        }
        keys.remove("")
        return keys
    }

    /// the server names of an `.mcp.json`: under `mcpServers`, or the file's own keys
    private static func servers(inFile url: URL, _ fileManager: FileManager) -> [String] {
        guard let root = jsonObject(at: url, fileManager) else { return [] }
        if let inner = root["mcpServers"] {
            return serverNames(in: inner)
        }
        return root.filter { $0.value is [String: Any] }.map(\.key).sorted()
    }

    private static func serverNames(in value: Any?) -> [String] {
        (value as? [String: Any])?.keys.sorted() ?? []
    }

    private static func jsonObject(at url: URL, _ fileManager: FileManager) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Reads the config's server keys for a run, off the main actor, and parses the big `~/.claude.json` again only when it
/// changed (AI-09).
public actor McpConfigReader {
    private let home: URL
    private let managed: URL
    private var cached: (stamp: Date?, size: Int, file: McpConfigScan.UserFile)?

    /// - Parameters:
    ///   - home: the user's home folder
    ///   - managed: the folder of the managed config
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, managed: URL = McpConfigScan.managedFolder) {
        self.home = home
        self.managed = managed
    }

    /// Returns the keys of the servers the config names for a run in `folder`.
    public func serverKeys(folder: String?) -> Set<String> {
        let path = home.appending(path: ".claude.json", directoryHint: .notDirectory).path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? Int) ?? 0
        if cached?.stamp != stamp || cached?.size != size || cached == nil {
            cached = (stamp, size, McpConfigScan.readUserFile(home: home))
        }
        return McpConfigScan.serverKeys(userFile: cached?.file ?? McpConfigScan.UserFile(), home: home, folder: folder, managed: managed)
    }
}

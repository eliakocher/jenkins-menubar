import Foundation

/// An MCP server of the user's Claude Code setup, as `claude` reports it when it starts.
public struct ClaudeMcpServer: Hashable, Sendable {
    public var name: String
    /// `connected`, `needs-auth`, `failed`…
    public var status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }

    /// whether the server's tools are available in a run
    public var isConnected: Bool {
        status == "connected"
    }
}

/// What the user's Claude Code setup offers a headless run (AI-09): the MCP tools of the connected servers, found once
/// per app session, and the servers behind them.
///
/// `claude` reports both in the first line of `--output-format stream-json --verbose`, the `init` event, before it
/// calls any model; ``ClaudeEngine/discoverSetup()`` reads that line.
public struct ClaudeInventory: Hashable, Sendable {
    /// the MCP tools' full names, `mcp__<server>__<tool>`, sorted
    public var mcpTools: [String]
    public var servers: [ClaudeMcpServer]

    public init(mcpTools: [String], servers: [ClaudeMcpServer] = []) {
        self.mcpTools = mcpTools.sorted()
        self.servers = servers
    }

    /// the tools Claude may use, and the ones kept off
    public var split: (reading: [String], changing: [String]) {
        McpToolClassifier.split(mcpTools)
    }

    /// the tools by server, in the order of the servers' keys
    public var serverGroups: [McpServerGroup] {
        var tools: [String: [String]] = [:]
        for name in mcpTools {
            if let key = McpServerGroup.key(of: name) {
                tools[key, default: []].append(name)
            }
        }
        return tools.keys.sorted().map { key in
            let names = tools[key] ?? []
            let server = servers.first { McpServerGroup.key(ofServerNamed: $0.name) == key }
            return McpServerGroup(
                key: key, name: McpServerGroup.friendlyName(of: server?.name, key: key), toolCount: names.count,
                readingCount: McpToolClassifier.split(names).reading.count)
        }
    }

    /// Reads the `init` event out of `claude`'s stream-json output.
    ///
    /// - Parameter output: the output, one JSON event per line
    /// - Returns: the inventory, or `nil` when there is no `init` event
    public static func parse(streamJSON output: Data) -> ClaudeInventory? {
        for line in output.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "system", event["subtype"] as? String == "init" else {
                continue
            }
            let tools = (event["tools"] as? [String] ?? []).filter { $0.hasPrefix("mcp__") }
            let servers = (event["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server -> ClaudeMcpServer? in
                guard let name = server["name"] as? String else { return nil }
                return ClaudeMcpServer(name: name, status: server["status"] as? String ?? "unknown")
            }
            return ClaudeInventory(mcpTools: tools, servers: servers)
        }
        return nil
    }
}

/// The tools of one MCP server of the user's setup, for the per-server choice in Settings (AI-09). Every tool of a server
/// the chats may use goes into each message's tool list, which is most of the 200,000 tokens a first message costs, so
/// the user picks the servers.
public struct McpServerGroup: Hashable, Sendable, Identifiable {
    /// the server's part of its tools' names, `mcp__<key>__<tool>`: `plugin_x_server`, `claude_ai_Name`
    public var key: String
    /// the server's name for the list
    public var name: String
    public var toolCount: Int
    /// how many of them only read
    public var readingCount: Int

    public var id: String { key }

    public init(key: String, name: String, toolCount: Int, readingCount: Int) {
        self.key = key
        self.name = name
        self.toolCount = toolCount
        self.readingCount = readingCount
    }

    /// what one tool adds to a message, in tokens, on average: measured as 200,000 tokens for 390 tools of 15 servers,
    /// 350 for a small server's tools, 900 for a design tool's. Rough on purpose.
    public static let tokensPerTool = 400

    /// about how many tokens the server's allowed tools add to every message: only the reading ones stay in the list
    public var estimatedTokens: Int {
        readingCount * Self.tokensPerTool
    }

    /// whether the chats use the server when the user hasn't chosen: only a GitLab or Jenkins server (the name says so)
    public var isOnByDefault: Bool {
        let lowered = key.lowercased()
        return lowered.contains("gitlab") || lowered.contains("jenkins")
    }

    /// Returns whether the user's choices turn the server on.
    ///
    /// - Parameter choices: the user's choices by server key; a server without one follows its default
    public func isOn(choices: [String: Bool]) -> Bool {
        choices[key] ?? isOnByDefault
    }

    /// Returns the server key of an MCP tool name, `plugin_x_server` for `mcp__plugin_x_server__get_y`; `nil` for a name
    /// that isn't an MCP tool or whose key couldn't go on the command line.
    public static func key(of toolName: String) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        let key = toolName.dropFirst(5).components(separatedBy: "__").first ?? ""
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { return nil }
        return key
    }

    /// Returns the key Claude Code gives a server in its tools' names: every character that is not a letter, digit,
    /// underscore or hyphen becomes an underscore (`claude.ai Name` is `claude_ai_Name`, `plugin:x:server` is
    /// `plugin_x_server`).
    public static func key(ofServerNamed name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") ? Character(scalar) : "_"
        })
    }

    /// the server's name for a list: `Gitlab MCP` for `claude.ai Gitlab MCP`, `jenkins (a-plugin)` for
    /// `plugin:a-plugin:jenkins`; without the server's own name, the key
    static func friendlyName(of serverName: String?, key: String) -> String {
        guard let serverName else { return key }
        if serverName.hasPrefix("claude.ai ") {
            return String(serverName.dropFirst("claude.ai ".count))
        }
        let parts = serverName.components(separatedBy: ":")
        if parts.count == 3, parts[0] == "plugin" {
            return parts[1] == parts[2] ? parts[2] : "\(parts[2]) (\(parts[1]))"
        }
        return serverName
    }
}

/// The user's Claude Code setup a chat run loads instead of `--safe-mode` (AI-09): their skills, plugins, commands and MCP
/// servers, and CLAUDE.md unless they turned it off. Claude may still only read: the MCP tools that read are allowed
/// by name, every other one is denied by name, and the built-in tools that write or run are denied too.
public struct ClaudeSetup: Hashable, Sendable {
    /// whether the user's CLAUDE.md files are loaded
    public var useClaudeMd: Bool
    /// the MCP tools allowed: the reading ones of the servers that are on
    public var readingTools: [String]
    /// the MCP tools denied by name: the changing ones of the servers that are on
    public var otherTools: [String]
    /// the servers that are off, by key: all their tools are denied at once with `mcp__<key>__*`, which also takes
    /// them out of every message's tool list
    public var blockedServers: [String]
    /// whether the MCP tools are not known yet: then every MCP tool is denied
    public var blocksAllMcp: Bool

    /// - Parameters:
    ///   - useClaudeMd: whether CLAUDE.md is loaded
    ///   - inventory: what the setup offers; `nil` while it isn't known, which keeps every MCP tool off
    ///   - serverChoices: the user's choice of servers by key; a server without one follows
    ///     ``McpServerGroup/isOnByDefault``
    public init(useClaudeMd: Bool, inventory: ClaudeInventory?, serverChoices: [String: Bool] = [:]) {
        self.useClaudeMd = useClaudeMd
        guard let inventory else {
            readingTools = []
            otherTools = []
            blockedServers = []
            blocksAllMcp = true
            return
        }
        let on = Set(inventory.serverGroups.filter { $0.isOn(choices: serverChoices) }.map(\.key))
        blockedServers = inventory.serverGroups.map(\.key).filter { !on.contains($0) }
        let sorted = McpToolClassifier.split(inventory.mcpTools.filter { McpServerGroup.key(of: $0).map(on.contains) == true })
        readingTools = sorted.reading
        otherTools = sorted.changing
        blocksAllMcp = false
    }
}

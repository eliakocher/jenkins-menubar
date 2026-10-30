import Foundation

/// Whether an MCP tool only reads or may change something (AI-09).
public enum McpToolAccess: Hashable, Sendable {
    /// it only looks things up: Claude may use it in the chats
    case reading
    /// it creates, changes, deletes, triggers or runs something, or the app can't tell: kept off
    case changing
}

/// Sorts the MCP tools of the user's Claude Code setup into reading and changing ones, by the verb their name starts
/// with (AI-09). A tool is reading only when its first word says so (`get_issue`, `listJobs`, `search_code`); every
/// other name, a verb the app doesn't know included, counts as changing: a wrong guess then keeps a harmless tool off
/// rather than letting a harmful one run.
///
/// Claude Code names an MCP tool `mcp__<server>__<tool>`. A tool that starts with its server's name again
/// (`mcp__x__twilio__retrieve`) is judged by the part after the last double underscore.
public enum McpToolClassifier {
    /// the first words of a reading tool: `get_*`, `list_*`, `search_*`, `find_*`, `read_*`, `fetch_*`, `show_*`,
    /// `describe_*`, `whoami`, `status`…
    static let readingVerbs: Set<String> = [
        "get", "list", "search", "find", "read", "fetch", "show", "describe", "whoami", "status", "retrieve", "query",
        "view", "lookup", "count", "check", "validate", "inspect", "browse", "compare", "diff", "is", "has",
    ]

    /// verbs that make a tool changing when they follow "and" or "or" in a name that starts with a reading verb
    /// (`get_or_create_label`, `listAndDelete`)
    static let changingVerbs: Set<String> = [
        "create", "update", "delete", "remove", "merge", "approve", "unapprove", "trigger", "rebuild", "replay", "cancel",
        "retry", "play", "publish", "resolve", "submit", "mark", "set", "run", "post", "upload", "share", "trash", "add",
        "send", "write", "edit", "apply", "reply", "close", "reopen", "revoke", "move", "rename", "copy", "start", "stop",
    ]

    /// Returns whether a tool only reads.
    ///
    /// - Parameter name: the tool's name, with or without the `mcp__<server>__` prefix
    /// - Returns: its access
    public static func access(of name: String) -> McpToolAccess {
        let words = words(of: toolPart(of: name))
        guard let first = words.first else {
            return .changing
        }
        // `whoAmI` splits into three words; the verb is the whole name.
        if words.joined() == "whoami" {
            return .reading
        }
        guard readingVerbs.contains(first) else {
            return .changing
        }
        for (index, word) in words.enumerated() where index >= 2 && changingVerbs.contains(word) {
            if words[index - 1] == "and" || words[index - 1] == "or" {
                return .changing
            }
        }
        return .reading
    }

    /// Splits MCP tool names into the reading ones and the others, each sorted and without duplicates. Names that are
    /// not MCP tools (`mcp__…`) are left out: built-in tools aren't this classifier's business.
    ///
    /// - Parameter names: the tool names Claude Code reported
    /// - Returns: the reading names, then the changing ones
    public static func split(_ names: [String]) -> (reading: [String], changing: [String]) {
        var reading: Set<String> = []
        var changing: Set<String> = []
        for name in names where name.hasPrefix("mcp__") && isSafeToPassOnTheCommandLine(name) {
            if access(of: name) == .reading {
                reading.insert(name)
            } else {
                changing.insert(name)
            }
        }
        return (reading.sorted(), changing.sorted())
    }

    /// The part of a tool's name that says what it does: after the server's `mcp__<server>__` prefix and after any
    /// further double underscore.
    static func toolPart(of name: String) -> String {
        var parts = name.components(separatedBy: "__")
        if parts.first == "mcp", parts.count >= 3 {
            parts.removeFirst(2)
        }
        return parts.last ?? name
    }

    /// Splits a name into lowercase words at underscores, hyphens, dots and where a lowercase letter meets an uppercase
    /// one: `getBuildLog` and `get_build_log` are both `get`, `build`, `log`.
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character == "_" || character == "-" || character == "." || character == " " {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
            } else {
                if let previous, previous.isLowercase || previous.isNumber, character.isUppercase, !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// A name goes into `--allowedTools` and `--disallowedTools`, whose values are comma-separated rules: a name with a
    /// comma, a space, a parenthesis or a control character could smuggle a second rule in, so it is never passed on.
    static func isSafeToPassOnTheCommandLine(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-.:".unicodeScalars.contains(scalar))
        } && !name.isEmpty && name.count <= 200
    }
}

import Foundation

/// Keeps Claude's file tools inside the checkout of a question about code (AI-07, AI-09): a `PreToolUse` hook that
/// Claude Code runs before each tool call, passed with `--settings`.
///
/// Why a hook: with the user's setup a typed `/command` loads that skill, and a skill's `allowed-tools: Read` lets Read
/// open any path, past `--permission-mode dontAsk` (probed with Claude Code 2.1.317). A hook's denial beats that grant.
///
/// - The hook is the app's own program, `megamonitor --claude-read-guard` (``argument``): the rule below is the one
///   that runs, and nothing is written to disk. The command is the program's path in single quotes and the fixed
///   argument; the checkout never goes into it. The checkout reaches the hook through the environment
///   (``folderVariable``), set with `env`'s argument list.
/// - `|| exit 2` makes a hook that can't run (the app moved away) block the call instead of letting it pass.
/// - It only ever denies: a path inside the checkout goes on to Claude Code's own rules.
public enum ClaudeReadGuard {
    /// the program's argument that runs the hook instead of the app
    public static let argument = "--claude-read-guard"
    /// the environment variable that names the readable folder for the hook
    public static let folderVariable = "MEGAMONITOR_READABLE_FOLDER"
    /// the tools whose paths the hook checks; every other tool passes through it
    static let guardedTools: Set<String> = ["Read", "Grep", "Glob"]

    /// What the hook says of one tool call.
    public enum Decision: Hashable, Sendable {
        /// not the hook's business, or inside the folder: Claude Code's own rules decide
        case pass
        /// refused, with the reason Claude is told
        case deny(String)
    }

    // MARK: - The rule

    /// Returns the decision for a tool call: Read, Grep and Glob may only reach the folder and what is inside it.
    ///
    /// - Read's `file_path`, and Grep's and Glob's `path`, must name the folder or a path inside it once symlinks are
    ///   resolved; no path at all means the working folder, which is the folder. A relative path counts from `base`.
    /// - A `..` component, a `~`, a NUL or a value that isn't text is refused outright, before anything is resolved.
    /// - Glob's `pattern` and Grep's `glob` may not climb (`..`) or start at the home folder; an absolute one must start
    ///   inside the folder, judged by its part before the first wildcard.
    /// - Anything unexpected, like a missing `file_path`, is refused.
    ///
    /// - Parameters:
    ///   - tool: the tool's name
    ///   - input: the tool's input, as Claude Code sent it
    ///   - folder: the readable folder, its symlinks resolved
    ///   - base: the folder relative paths count from, Claude's working folder
    ///   - resolve: resolves the symlinks of an absolute path without `..`; the part that doesn't exist stays as it is
    /// - Returns: the decision
    public static func decision(
        tool: String, input: [String: Any], folder: String, base: String, resolve: (String) -> String
    ) -> Decision {
        guard guardedTools.contains(tool) else {
            return .pass
        }
        func inside(_ value: Any?, required: Bool) -> Bool {
            guard let value else {
                return !required
            }
            guard let path = value as? String else {
                return false
            }
            if path.isEmpty {
                return !required
            }
            return contains(folder: folder, path: path, base: base, resolve: resolve)
        }
        let checked: Bool
        switch tool {
        case "Read":
            checked = inside(input["file_path"], required: true)
        case "Grep":
            checked = inside(input["path"], required: false) && safePattern(input["glob"], folder: folder, resolve: resolve)
        default:
            checked = inside(input["path"], required: false)
                && input["pattern"] is String && safePattern(input["pattern"], folder: folder, resolve: resolve)
        }
        return checked ? .pass : .deny(refusal(folder: folder))
    }

    /// the reason Claude is told
    static func refusal(folder: String) -> String {
        "MegaMonitor lets Claude read only inside \(folder) in this chat."
    }

    /// Returns whether a path names the folder or a path inside it.
    static func contains(folder: String, path: String, base: String, resolve: (String) -> String) -> Bool {
        guard !path.contains("\0"), !path.hasPrefix("~") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else {
            return false
        }
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        let real = resolve(normalized(absolute))
        return real == folder || real.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Returns whether a glob pattern stays in the folder: no `..`, no `~`, no NUL; an absolute one starts inside it.
    static func safePattern(_ value: Any?, folder: String, resolve: (String) -> String) -> Bool {
        guard let value else {
            return true
        }
        guard let pattern = value as? String else {
            return false
        }
        guard !pattern.contains(".."), !pattern.contains("\0"), !pattern.hasPrefix("~"), !pattern.contains("{~") else {
            return false
        }
        guard pattern.hasPrefix("/") else {
            return true
        }
        // The fixed part before the first wildcard is where an absolute pattern starts looking.
        let wildcards = CharacterSet(charactersIn: "*?[]{}!")
        var fixed: [Substring] = []
        for component in pattern.split(separator: "/", omittingEmptySubsequences: true) {
            if component.unicodeScalars.contains(where: wildcards.contains) {
                break
            }
            fixed.append(component)
        }
        let start = "/" + fixed.joined(separator: "/")
        return contains(folder: folder, path: start, base: folder, resolve: resolve)
    }

    /// Returns an absolute path without `.` components and repeated slashes.
    static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves the symlinks of an absolute path: the longest part that exists through `realpath`, the rest appended as
    /// it is. A path without `..` means the same before and after, so nothing can climb out through a missing part.
    public static func resolvingSymlinks(_ path: String) -> String {
        var existing = normalized(path)
        var rest: [String] = []
        while existing != "/" {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                let resolved = String(cString: real)
                return rest.isEmpty ? resolved : (resolved == "/" ? "" : resolved) + "/" + rest.reversed().joined(separator: "/")
            }
            let url = URL(filePath: existing)
            rest.append(url.lastPathComponent)
            existing = url.deletingLastPathComponent().path(percentEncoded: false)
            if existing.count > 1, existing.hasSuffix("/") {
                existing.removeLast()
            }
        }
        return "/" + rest.reversed().joined(separator: "/")
    }

    // MARK: - The hook's run

    /// Returns what the hook prints for one call: Claude Code's `PreToolUse` JSON with a denial, or nothing to let the
    /// call go on. Refuses a guarded call when the input can't be read or the folder isn't set.
    ///
    /// - Parameters:
    ///   - input: the hook's stdin, Claude Code's JSON
    ///   - environment: the hook's environment, with ``folderVariable``
    ///   - resolve: resolves symlinks; ``resolvingSymlinks(_:)`` by default
    /// - Returns: the bytes for stdout
    public static func hookOutput(
        for input: Data, environment: [String: String], resolve: (String) -> String = resolvingSymlinks
    ) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
            let tool = object["tool_name"] as? String
        else {
            return denial("MegaMonitor couldn't read this tool call, so it is refused.")
        }
        guard guardedTools.contains(tool) else {
            return Data()
        }
        guard let raw = environment[folderVariable], raw.hasPrefix("/"), !raw.contains("\0"),
            !raw.split(separator: "/").contains("..")
        else {
            return denial("MegaMonitor doesn't know the readable folder, so reading is refused.")
        }
        let folder = resolve(normalized(raw))
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") && !$0.split(separator: "/").contains("..") ? $0 : nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        switch decision(tool: tool, input: input, folder: folder, base: cwd ?? folder, resolve: resolve) {
        case .pass:
            return Data()
        case .deny(let reason):
            return denial(reason)
        }
    }

    /// Claude Code's `PreToolUse` denial
    static func denial(_ reason: String) -> Data {
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason,
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: - The settings

    /// Returns the `--settings` JSON that runs the hook before every tool call. `disableAllHooks` is set to `false`, as
    /// these settings outrank the user's own, so their switch can't turn the hook off.
    ///
    /// - Parameter program: the app's program
    /// - Returns: the JSON text
    public static func settings(program: String) -> String {
        let hook: [String: Any] = ["type": "command", "command": command(program: program), "timeout": 30]
        let object: [String: Any] = [
            "disableAllHooks": false,
            "hooks": ["PreToolUse": [["matcher": "*", "hooks": [hook]]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns the hook's shell command: the program in single quotes, ``argument``, and `|| exit 2`, so a hook that
    /// can't run blocks the call.
    static func command(program: String) -> String {
        "'" + program.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument + " || exit 2"
    }

    /// Returns the program to run as the hook: the app's own executable, when it is the app's (`megamonitor` in a debug
    /// build, `MegaMonitor` in the bundle `build.sh` makes); `nil` in tests and anything else that runs this code.
    public static func appProgram(bundle: Bundle = .main) -> String? {
        guard let url = bundle.executableURL, url.lastPathComponent.lowercased() == "megamonitor" else {
            return nil
        }
        return url.path(percentEncoded: false)
    }
}

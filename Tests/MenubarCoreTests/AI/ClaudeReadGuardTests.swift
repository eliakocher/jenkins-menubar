import Foundation
import Testing

@testable import MenubarCore

/// AI-07, AI-09: the read guard, the hook that keeps Read, Grep and Glob inside a question's checkout whatever a
/// skill's `allowed-tools` grants. Every path is made up or a temporary folder; no `claude` runs.
@Suite("Claude read guard")
struct ClaudeReadGuardTests {
    private static let folder = "/work/project"
    /// a made-up file system's symlinks: one inside pointing out, one inside pointing in
    private static let links = ["/work/project/out": "/home/dev", "/work/project/alias": "/work/project/src"]

    /// resolves the made-up symlinks the way `realpath` would, by the longest linked prefix
    private static func resolve(_ path: String) -> String {
        for (link, target) in links where path == link || path.hasPrefix(link + "/") {
            return target + path.dropFirst(link.count)
        }
        return path
    }

    private static func decide(_ tool: String, _ input: [String: Any]) -> ClaudeReadGuard.Decision {
        ClaudeReadGuard.decision(tool: tool, input: input, folder: folder, base: folder, resolve: resolve)
    }

    @Test("AI-07 the read guard lets Read, Grep and Glob reach only the checkout: no climbing, no symlink out, no absolute path or pattern elsewhere", arguments: [
        // Read
        ("Read", #"{"file_path":"/work/project/src/a.swift"}"#, true),
        ("Read", #"{"file_path":"src/a.swift"}"#, true),
        ("Read", #"{"file_path":"/work/project"}"#, true),
        ("Read", #"{"file_path":"/work/project/alias/a.swift"}"#, true),
        ("Read", #"{"file_path":"/home/dev/.ssh/id_ed25519"}"#, false),
        ("Read", #"{"file_path":"/work/project-other/a"}"#, false),
        ("Read", #"{"file_path":"/work/project/../secret"}"#, false),
        ("Read", #"{"file_path":"../secret"}"#, false),
        ("Read", #"{"file_path":"/work/project/out/notes.txt"}"#, false),
        ("Read", #"{"file_path":"~/notes.txt"}"#, false),
        ("Read", #"{"file_path":"/work/project/a\u0000b"}"#, false),
        ("Read", #"{"file_path":7}"#, false),
        ("Read", #"{}"#, false),
        // Grep: no path is the working folder
        ("Grep", #"{"pattern":"token"}"#, true),
        ("Grep", #"{"pattern":"token","path":"/work/project/src"}"#, true),
        ("Grep", #"{"pattern":"token","path":"/home/dev"}"#, false),
        ("Grep", #"{"pattern":"token","path":"/work/project/out"}"#, false),
        ("Grep", #"{"pattern":"token","glob":"*.swift"}"#, true),
        ("Grep", #"{"pattern":"token","glob":"../**/*.txt"}"#, false),
        ("Grep", #"{"pattern":"token","glob":"/home/dev/*"}"#, false),
        // Glob
        ("Glob", #"{"pattern":"**/*.swift"}"#, true),
        ("Glob", #"{"pattern":"**/*.swift","path":"/work/project/src"}"#, true),
        ("Glob", #"{"pattern":"/work/project/src/**/*.swift"}"#, true),
        ("Glob", #"{"pattern":"../**"}"#, false),
        ("Glob", #"{"pattern":"src/{..,x}/*"}"#, false),
        ("Glob", #"{"pattern":"/home/dev/**"}"#, false),
        ("Glob", #"{"pattern":"/work/project/out/*"}"#, false),
        ("Glob", #"{"pattern":"/*/project/**"}"#, false),
        ("Glob", #"{"pattern":"~/**"}"#, false),
        ("Glob", #"{"pattern":"**","path":"/"}"#, false),
        ("Glob", #"{"path":"/work/project"}"#, false),
        // Not the guard's business
        ("Skill", #"{"skill":"anything"}"#, true),
        ("mcp__demo__get_issue", #"{"path":"/home/dev"}"#, true),
    ])
    func rule(tool: String, json: String, allowed: Bool) throws {
        let input = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let decision = Self.decide(tool, input)
        #expect((decision == .pass) == allowed, "\(tool) \(json)")
    }

    @Test("AI-07 the read guard resolves real symlinks, also of a path whose end doesn't exist")
    func realSymlinks() throws {
        let temporary = try TemporaryFolder()
        let root = ClaudeReadGuard.resolvingSymlinks(temporary.url.path(percentEncoded: false))
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: root + "/project/src", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: root + "/outside", withIntermediateDirectories: true)
        try Data("canary".utf8).write(to: URL(filePath: root + "/outside/secret.txt"))
        try fileManager.createSymbolicLink(atPath: root + "/project/link", withDestinationPath: "../outside")
        try fileManager.createSymbolicLink(atPath: root + "/project/file", withDestinationPath: "../outside/secret.txt")
        let folder = root + "/project"
        func allows(_ path: String) -> Bool {
            ClaudeReadGuard.decision(
                tool: "Read", input: ["file_path": path], folder: folder, base: folder,
                resolve: ClaudeReadGuard.resolvingSymlinks) == .pass
        }
        #expect(allows(folder + "/src/new-file.swift"))
        #expect(allows(folder + "/src/missing/deeper/x"))
        #expect(!allows(folder + "/link/secret.txt"))
        #expect(!allows(folder + "/link/missing.txt"))
        #expect(!allows(folder + "/file"))
        #expect(!allows(root + "/outside/secret.txt"))
    }

    @Test("AI-07 the hook prints a denial for a call outside the folder and nothing inside; no folder or unreadable input is refused")
    func hookOutput() throws {
        func output(_ json: String, folder: String? = "/work/project") -> String {
            let environment = folder.map { [ClaudeReadGuard.folderVariable: $0] } ?? [:]
            return String(decoding: ClaudeReadGuard.hookOutput(for: Data(json.utf8), environment: environment) { $0 }, as: UTF8.self)
        }
        let outside = #"{"tool_name":"Read","tool_input":{"file_path":"/home/dev/x"},"cwd":"/work/project"}"#
        let denial = try #require(
            try JSONSerialization.jsonObject(with: Data(output(outside).utf8)) as? [String: Any])
        let specific = try #require(denial["hookSpecificOutput"] as? [String: String])
        #expect(specific["hookEventName"] == "PreToolUse")
        #expect(specific["permissionDecision"] == "deny")

        #expect(output(#"{"tool_name":"Read","tool_input":{"file_path":"/work/project/a"},"cwd":"/work/project"}"#).isEmpty)
        // A relative path counts from Claude's working folder.
        #expect(output(#"{"tool_name":"Read","tool_input":{"file_path":"a"},"cwd":"/work/project/src"}"#).isEmpty)
        #expect(output(#"{"tool_name":"Read","tool_input":{"file_path":"a"},"cwd":"/home/dev"}"#).contains("deny"))
        #expect(output(#"{"tool_name":"Bash","tool_input":{"command":"ls /"}}"#).isEmpty)
        #expect(output(#"{"tool_name":"Read","tool_input":{"file_path":"/work/project/a"}}"#, folder: nil).contains("deny"))
        #expect(output(#"{"tool_name":"Read","tool_input":{"file_path":"/work/project/a"}}"#, folder: "work").contains("deny"))
        #expect(output("not json").contains("deny"))
    }

    @Test("AI-09 the hook's program is the app's own executable, as build.sh names it in the bundle or as a debug build names it; any other program is none", arguments: [
        ("MegaMonitor", true),
        ("megamonitor", true),
        ("swiftpm-testing-helper", false),
    ])
    func appProgram(executable: String, isApp: Bool) throws {
        let app = FileManager.default.temporaryDirectory
            .appending(path: "read-guard-\(UUID().uuidString)/Probe.app", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": "local.probe.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let program = contents.appending(path: "MacOS/\(executable)")
        try Data().write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path(percentEncoded: false))

        let bundle = try #require(Bundle(url: app))
        let found = ClaudeReadGuard.appProgram(bundle: bundle)
        #expect((found != nil) == isApp)
        if isApp {
            #expect(found?.hasSuffix("/Contents/MacOS/\(executable)") == true)
        }
    }

    @Test("AI-09 the hook's command quotes the app's program and never holds the folder; a hook that can't run blocks the call")
    func settings() throws {
        let settings = ClaudeReadGuard.settings(program: "/Users/dev/Apps/Mega Monitor's.app/Contents/MacOS/megamonitor")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect(object["disableAllHooks"] as? Bool == false)
        let hooks = try #require(object["hooks"] as? [String: Any])
        let entry = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(entry["matcher"] as? String == "*")
        let hook = try #require((entry["hooks"] as? [[String: Any]])?.first)
        #expect(hook["command"] as? String
            == #"'/Users/dev/Apps/Mega Monitor'\''s.app/Contents/MacOS/megamonitor' --claude-read-guard || exit 2"#)
    }

    @Test("AI-09 a question about code with the setup gets the Skill tool only behind the read guard, whose folder goes through env")
    func guardedArguments() {
        let folder = "/Users/dev/src/my project; rm -rf ~"
        var prompt = ClaudePrompt(useCase: .askAboutCode, instructions: "i", text: "facts")
        prompt.readableFolder = folder
        let setup = ClaudeSetup(useClaudeMd: true, inventory: ClaudeInventory(mcpTools: []), serverChoices: [:])
        let program = "/Applications/MegaMonitor.app/Contents/MacOS/megamonitor"
        let claude = URL(filePath: "/opt/homebrew/bin/claude")

        let guarded = ClaudeEngine.command(claude: claude, for: prompt, model: .sonnet, setup: setup, guardProgram: program)
        #expect(guarded.executable.path(percentEncoded: false) == "/usr/bin/env")
        #expect(Array(guarded.arguments.prefix(4))
            == ["-C", folder, ClaudeReadGuard.folderVariable + "=" + folder, "/opt/homebrew/bin/claude"])
        let arguments = Array(guarded.arguments.dropFirst(4))
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value("--tools") == "Read,Grep,Glob,Skill")
        #expect(value("--allowedTools")?.components(separatedBy: ",").contains("Skill") == true)
        #expect(value("--permission-mode") == "dontAsk")
        let settings = value("--settings") ?? ""
        #expect(settings.contains("--claude-read-guard") && settings.contains(program))
        #expect(!settings.contains("rm -rf"))
        #expect(!arguments.contains { $0.contains("facts") })

        // Without the guard's program, or in safe mode, no Skill tool and no hook.
        let unguarded = ClaudeEngine.arguments(for: prompt, model: .sonnet, setup: setup)
        #expect(unguarded.firstIndex(of: "--tools").map { unguarded[$0 + 1] } == "Read,Grep,Glob")
        #expect(!unguarded.contains("--settings"))
        let safe = ClaudeEngine.command(claude: claude, for: prompt, model: .sonnet, guardProgram: program)
        #expect(!safe.arguments.contains("--settings"))
        #expect(!safe.arguments.contains { $0.hasPrefix(ClaudeReadGuard.folderVariable) })
    }
}

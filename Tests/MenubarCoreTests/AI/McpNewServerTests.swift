import Foundation
import Testing

@testable import MenubarCore

/// AI-09: a server added to the Claude Code config after the listing is denied in the chats until the listing is made
/// again. Every name is made up; no real `claude`, config or home folder is read.
@Suite("MCP servers added after the listing")
struct McpNewServerTests {
    /// the listing the decisions rest on: a server with tools, one that listed none
    private static let listed = ClaudeInventory(
        mcpTools: ["mcp__plugin_demo_issues__get_issue", "mcp__plugin_demo_issues__create_issue"],
        servers: [
            ClaudeMcpServer(name: "plugin:demo:issues", status: "connected"),
            ClaudeMcpServer(name: "claude.ai Wiki", status: "needs-auth"),
        ])
    private static let choices = ["plugin_demo_issues": true]

    private static func denied(_ setup: ClaudeSetup) -> [String] {
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "t")
        let arguments = ClaudeEngine.arguments(for: prompt, model: .sonnet, setup: setup)
        return value(after: "--disallowedTools", in: arguments)?.components(separatedBy: ",") ?? []
    }

    private static func allowed(_ setup: ClaudeSetup) -> [String] {
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "t")
        let arguments = ClaudeEngine.arguments(for: prompt, model: .sonnet, setup: setup)
        return value(after: "--allowedTools", in: arguments)?.components(separatedBy: ",") ?? []
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    // MARK: - The decision

    @Test("AI-09 a server the config names that the listing never saw is denied by prefix, whatever the user chose", arguments: [
        (["brand_new"], ["mcp__brand_new__*"]),
        (["brand_new", "another-one"], ["mcp__another-one__*", "mcp__brand_new__*"]),
        // The same server twice, or an empty key, is one rule or none.
        (["brand_new", "brand_new", ""], ["mcp__brand_new__*"]),
    ] as [([String], [String])])
    func addedAfterListing(configured: [String], expected: [String]) {
        let setup = ClaudeSetup(
            useClaudeMd: true, inventory: Self.listed, serverChoices: Self.choices, configuredServers: Set(configured))
        let denied = Self.denied(setup)
        for rule in expected {
            #expect(denied.contains(rule), "\(rule)")
        }
        #expect(denied.filter { $0.hasPrefix("mcp__") && $0.hasSuffix("__*") && !$0.contains("claude_ai_Wiki") }.sorted() == expected)
        // Even when the user turned the new server on by its key before it was listed.
        let chosen = ClaudeSetup(
            useClaudeMd: true, inventory: Self.listed, serverChoices: Self.choices.merging(["brand_new": true]) { $1 },
            configuredServers: Set(configured))
        #expect(Self.denied(chosen).contains("mcp__brand_new__*"))
    }

    @Test("AI-09 a listed server with tools stays allowed for its reading tools, and a config that names only listed servers adds no denial",
          arguments: [
              [] as [String], ["plugin_demo_issues"], ["plugin_demo_issues", "claude_ai_Wiki"],
          ])
    func listedStaysAllowed(configured: [String]) {
        let plain = ClaudeSetup(useClaudeMd: true, inventory: Self.listed, serverChoices: Self.choices)
        let setup = ClaudeSetup(
            useClaudeMd: true, inventory: Self.listed, serverChoices: Self.choices, configuredServers: Set(configured))
        #expect(Self.allowed(setup) == ["mcp__plugin_demo_issues__get_issue"])
        #expect(Self.denied(setup).contains("mcp__plugin_demo_issues__create_issue"))
        #expect(!Self.denied(setup).contains("mcp__plugin_demo_issues__*"))
        // The tool-less server was denied before and still is, once.
        #expect(Self.denied(setup).filter { $0 == "mcp__claude_ai_Wiki__*" }.count == 1)
        #expect(setup == plain)
    }

    @Test("AI-09 without a listing every MCP tool is denied, whatever the config names", arguments: [
        [] as [String], ["brand_new"], ["plugin_demo_issues"],
    ])
    func noListing(configured: [String]) {
        let setup = ClaudeSetup(
            useClaudeMd: true, inventory: nil, serverChoices: Self.choices, configuredServers: Set(configured))
        #expect(setup.blocksAllMcp)
        #expect(Self.allowed(setup).isEmpty)
        #expect(Self.denied(setup).contains("mcp__*"))
    }

    // MARK: - Reading the config

    @Test("AI-09 the config's server names come from the user file, the checkout and the folders above it, plugins and the managed file")
    func readsConfig() throws {
        let tmp = try TemporaryFolder()
        let folder = tmp.url.appending(path: "src/app", directoryHint: .isDirectory).path(percentEncoded: false)
        let elsewhere = tmp.url.appending(path: "src/other", directoryHint: .isDirectory).path(percentEncoded: false)
        try tmp.write(
            """
            {"mcpServers": {"my-new": {}},
             "claudeAiMcpEverConnected": ["claude.ai New Thing"],
             "projects": {"\(folder)": {"mcpServers": {"local.one": {}}}, "\(elsewhere)": {"mcpServers": {"not-here": {}}}}}
            """, to: "home/.claude.json")
        try tmp.write(#"{"mcpServers": {"proj-one": {"command": "x"}}}"#, to: "src/app/.mcp.json")
        try tmp.write(#"{"above": {"command": "x"}}"#, to: "src/.mcp.json")
        let plugin = tmp.url.appending(path: "plugins/demo", directoryHint: .isDirectory).path(percentEncoded: false)
        try tmp.write(
            #"{"plugins": {"demo@market": [{"installPath": "\#(plugin)"}]}}"#, to: "home/.claude/plugins/installed_plugins.json")
        try tmp.write(#"{"flat": {"command": "x"}}"#, to: "plugins/demo/.mcp.json")
        try tmp.write(#"{"mcpServers": {"inline": {"command": "x"}}}"#, to: "plugins/demo/.claude-plugin/plugin.json")
        try tmp.write(#"{"mcpServers": {"managed one": {}}}"#, to: "managed/managed-mcp.json")

        let home = tmp.url.appending(path: "home", directoryHint: .isDirectory)
        let managed = tmp.url.appending(path: "managed", directoryHint: .isDirectory)
        let userFile = McpConfigScan.readUserFile(home: home)
        let keys = McpConfigScan.serverKeys(userFile: userFile, home: home, folder: folder, managed: managed)
        #expect(keys == [
            "my-new", "claude_ai_New_Thing", "local_one", "proj-one", "above", "plugin_demo_flat", "plugin_demo_inline",
            "managed_one",
        ])
        // Another folder gets the user's and the plugins' servers, not this checkout's.
        let other = McpConfigScan.serverKeys(userFile: userFile, home: home, folder: elsewhere, managed: managed)
        #expect(other.contains("not-here") && !other.contains("local_one") && !other.contains("proj-one"))
        // No folder: the user's and the plugins' only. A missing or broken file reads as no servers.
        let none = McpConfigScan.serverKeys(userFile: userFile, home: home, folder: nil, managed: managed)
        #expect(none == ["my-new", "claude_ai_New_Thing", "plugin_demo_flat", "plugin_demo_inline", "managed_one"])
        try tmp.write("{not json", to: "broken/.claude.json")
        #expect(McpConfigScan.readUserFile(home: tmp.url.appending(path: "broken", directoryHint: .isDirectory)) == McpConfigScan.UserFile())
        #expect(McpConfigScan.readUserFile(home: tmp.url.appending(path: "nowhere", directoryHint: .isDirectory)) == McpConfigScan.UserFile())
    }

    @Test("AI-09 the reader parses the user file again only when it changed")
    func readerCaches() async throws {
        let tmp = try TemporaryFolder()
        try tmp.write(#"{"mcpServers": {"first": {}}}"#, to: ".claude.json")
        let reader = McpConfigReader(home: tmp.url, managed: tmp.file("none"))
        #expect(await reader.serverKeys(folder: nil) == ["first"])
        // A different size is a change, even inside the timestamp's resolution.
        try tmp.write(#"{"mcpServers": {"first": {}, "second": {}}}"#, to: ".claude.json")
        #expect(await reader.serverKeys(folder: nil) == ["first", "second"])
    }

    // MARK: - A chat run

    @Test("AI-09 a chat denies a server added after the listing without listing again, and a listing that grew old refreshes in the background")
    @MainActor
    func chatRuns() async throws {
        let item = ConversationTests.item
        let listing = try FixtureFiles.data("Claude/setup-init.jsonl")
        let fake = ChatFake(listing: listing)
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let store = AIStore(
            defaults: TemporaryDefaults().defaults, runner: fake, now: { clock.date }, resolver: fake.resolver())
        store.update(AISettings(
            isEnabled: true, confirmedUseCases: [.askAboutItem], useMySetup: true,
            mcpServerChoices: ["plugin_demo_issues": true, "plugin_demo_builds": true]))
        let config = ConfigBox(["plugin_demo_issues", "claude_ai_Docs"])
        store.configuredMcpServers = { _ in config.keys }

        await store.ask("Why?", about: item, description: nil)
        var calls = await fake.calls
        #expect(calls.count == 2)
        var chat = try #require(calls.last)
        #expect(Self.value(after: "--disallowedTools", in: chat.arguments)?.contains("mcp__brand_new__*") == false)

        // The user adds a server: the next chat denies it, with no new listing in between.
        config.keys.insert("brand_new")
        await store.followUp(.workItem(item.reference), question: "And?")
        calls = await fake.calls
        #expect(calls.count == 3)
        chat = try #require(calls.last)
        #expect(!chat.arguments.contains("stream-json"))
        #expect(Self.value(after: "--disallowedTools", in: chat.arguments)?.contains("mcp__brand_new__*") == true)
        #expect(Self.value(after: "--allowedTools", in: chat.arguments)?.contains("mcp__plugin_demo_issues__get_issue") == true)

        // An hour later the listing is refreshed in the background, once, and the chat does not wait for it.
        clock.date = clock.date.addingTimeInterval(3600)
        await store.followUp(.workItem(item.reference), question: "Again?")
        for _ in 0..<200 where await fake.calls.filter({ $0.arguments.contains("stream-json") }).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        calls = await fake.calls
        #expect(calls.filter { $0.arguments.contains("stream-json") }.count == 2)
        #expect(!(try #require(calls.dropFirst(2).first)).arguments.contains("stream-json"))
        #expect(store.setupInventory.inventory != nil)
    }
}

/// a test clock the store reads
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// the config's server keys, changed by the test between chats
private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<String>
    init(_ keys: Set<String>) { value = keys }
    var keys: Set<String> {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A `claude` that answers the listing (the run with stream-json) with a canned output and every other run with a plain
/// answer, and a login shell that knows no `PATH`.
private actor ChatFake: ProcessRunner {
    struct Call: Sendable {
        var arguments: [String]
    }

    private let listing: Data
    private(set) var calls: [Call] = []

    init(listing: Data) {
        self.listing = listing
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        // `claude --version`, read once when claude is looked for, is not a call the tests count.
        if arguments == ["--version"] {
            return ProcessOutput(status: 0, standardOutput: Data("2.1.317 (Claude Code)\n".utf8))
        }
        calls.append(Call(arguments: arguments))
        if arguments.contains("stream-json") {
            return ProcessOutput(status: 0, standardOutput: listing)
        }
        let object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false, "result": "An answer.",
            "usage": ["input_tokens": 10, "output_tokens": 5],
        ]
        return ProcessOutput(status: 0, standardOutput: try JSONSerialization.data(withJSONObject: object))
    }

    nonisolated func resolver() -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { $0 == "/opt/homebrew/bin/claude" }
    }
}

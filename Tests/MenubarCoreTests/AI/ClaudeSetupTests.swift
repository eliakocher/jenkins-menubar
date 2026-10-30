import Foundation
import Testing

@testable import MenubarCore

/// AI-09: the chats with the user's own Claude Code setup. Every name is made up; `claude` is a fake and no real
/// command, skill or MCP server is touched.
@Suite("Claude setup")
struct ClaudeSetupTests {
    // MARK: - Reading and changing tools

    @Test("AI-09 sorts MCP tools into reading and changing ones by the verb their name starts with", arguments: [
        ("mcp__s__get_issue", McpToolAccess.reading), ("mcp__s__list_merge_requests", .reading),
        ("mcp__s__search_code", .reading), ("mcp__s__find_users", .reading), ("mcp__s__read_file_content", .reading),
        ("mcp__s__fetch_page", .reading), ("mcp__s__show_status", .reading), ("mcp__s__describe_table", .reading),
        ("mcp__s__retrieve", .reading), ("mcp__s__whoAmI", .reading), ("mcp__s__whoami", .reading),
        ("mcp__s__getStatus", .reading), ("mcp__s__getBuildLog", .reading), ("mcp__s__findJobsWithScmUrl", .reading),
        ("mcp__s__searchBuildLog", .reading), ("mcp__s__status", .reading), ("mcp__s__validate_ci_config", .reading),
        // A noun that looks like a verb after a reading one stays reading.
        ("mcp__s__list_pipeline_trigger_jobs", .reading), ("mcp__s__get_job_artifact", .reading),
        // The part after the last double underscore says what a tool does.
        ("mcp__claude_ai_Echo__echo__retrieve", .reading), ("mcp__claude_ai_Echo__echo__search", .reading),
        ("mcp__s__create_issue", .changing), ("mcp__s__update_issue", .changing), ("mcp__s__delete_note", .changing),
        ("mcp__s__merge_merge_request", .changing), ("mcp__s__approve_merge_request", .changing),
        ("mcp__s__triggerBuild", .changing), ("mcp__s__rebuildBuild", .changing), ("mcp__s__replayBuild", .changing),
        ("mcp__s__cancel_pipeline", .changing), ("mcp__s__retry_job", .changing), ("mcp__s__play_job", .changing),
        ("mcp__s__publish_draft_note", .changing), ("mcp__s__resolve_discussion", .changing),
        ("mcp__s__submit_review", .changing), ("mcp__s__mark_message_spam", .changing), ("mcp__s__set_variable", .changing),
        ("mcp__s__run_pipeline", .changing), ("mcp__s__post_comment", .changing), ("mcp__s__upload_assets", .changing),
        ("mcp__s__share_file", .changing), ("mcp__s__trash_message", .changing), ("mcp__s__browser_navigate", .changing),
        ("mcp__claude_ai_Echo__echo__send", .changing),
        // Not a known verb, or a read that also writes: kept off.
        ("mcp__s__weave_get_model_run_output", .changing), ("mcp__s__download_file_content", .changing),
        ("mcp__s__get_or_create_label", .changing), ("mcp__s__listAndDeleteNotes", .changing), ("mcp__s__", .changing),
    ])
    func classifier(name: String, access: McpToolAccess) {
        #expect(McpToolClassifier.access(of: name) == access, "\(name)")
    }

    @Test("AI-09 the split keeps only MCP tools, sorted, once, and never a name that could carry a second rule")
    func split() {
        let split = McpToolClassifier.split([
            "Read", "Bash", "mcp__b__get_x", "mcp__a__list_y", "mcp__b__get_x", "mcp__a__delete_y",
            "mcp__a__get_x,mcp__a__delete_x", "mcp__a__get_x(*)", "mcp__a__get x", "mcp__a__get_é",
        ])
        #expect(split.reading == ["mcp__a__list_y", "mcp__b__get_x"])
        #expect(split.changing == ["mcp__a__delete_y"])
    }

    // MARK: - The command line

    private static let claude = URL(filePath: "/opt/homebrew/bin/claude")
    private static let inventory = ClaudeInventory(mcpTools: [
        "mcp__plugin_demo_issues__get_issue", "mcp__plugin_demo_issues__create_issue", "mcp__plugin_demo_builds__triggerBuild",
        "mcp__plugin_demo_builds__getBuild", "mcp__claude_ai_Docs__share_file",
    ])

    /// the made-up servers the tests turn on: the demo ones, not Docs
    private static let demoChoices = ["plugin_demo_issues": true, "plugin_demo_builds": true]

    private static func setup(claudeMd: Bool = true) -> ClaudeSetup {
        ClaudeSetup(useClaudeMd: claudeMd, inventory: inventory, serverChoices: demoChoices)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    @Test("AI-09 the setup is off by default; with it off the arguments are the safe-mode ones, with it on there is no --safe-mode")
    func safeModeOnlyWithoutSetup() {
        #expect(AISettings().useMySetup == false)
        #expect(AISettings().useMyClaudeMd == true)
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "Instructions", text: "Facts: price * 2")
        let off = ClaudeEngine.arguments(for: prompt, model: .sonnet)
        #expect(off.contains("--safe-mode"))
        #expect(!off.contains("--permission-mode") && !off.contains("--allowedTools") && !off.contains("--disallowedTools"))

        let setup = Self.setup()
        let on = ClaudeEngine.arguments(for: prompt, model: .sonnet, setup: setup)
        #expect(!on.contains("--safe-mode"))
        #expect(!on.contains("--restricted"))
        #expect(Self.value(after: "--permission-mode", in: on) == "dontAsk")
        #expect(Self.value(after: "--tools", in: on) == "")
        #expect(on.contains("--no-session-persistence"))
        #expect(on.filter { $0 == "--max-budget-usd" }.count == 1)
        // The facts are never an argument.
        #expect(!on.joined(separator: " ").contains("price"))
        // The fixed parts stay: the model, the system prompt.
        #expect(Self.value(after: "--model", in: on) == "claude-sonnet-5-5")
        #expect(Self.value(after: "--system-prompt", in: on) == "Instructions")
    }

    @Test("AI-09 allows exactly the reading MCP tools by name, denies every other one and Bash, Edit and Write, and never allows those")
    func allowlist() throws {
        let setup = Self.setup()
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "t")
        let arguments = ClaudeEngine.arguments(for: prompt, model: .opus, setup: setup)
        let allowed = try #require(Self.value(after: "--allowedTools", in: arguments))
        #expect(allowed == "mcp__plugin_demo_builds__getBuild,mcp__plugin_demo_issues__get_issue")
        let denied = try #require(Self.value(after: "--disallowedTools", in: arguments)).components(separatedBy: ",")
        for never in ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch"] {
            #expect(denied.contains(never))
            #expect(!allowed.contains(never), "\(never) is allowed")
        }
        #expect(denied.contains("mcp__plugin_demo_issues__create_issue"))
        #expect(denied.contains("mcp__plugin_demo_builds__triggerBuild"))
        // A server that is off is denied as a whole, by one entry, not tool by tool.
        #expect(denied.contains("mcp__claude_ai_Docs__*"))
        #expect(!denied.contains("mcp__claude_ai_Docs__share_file"))
        #expect(!denied.contains("mcp__plugin_demo_issues__get_issue"))
        // A tool is in one list only.
        #expect(Set(allowed.components(separatedBy: ",")).isDisjoint(with: denied))
        // No bypass, and every list is one argument, so the next flag ends it.
        #expect(!arguments.contains("--dangerously-skip-permissions") && !arguments.contains("bypassPermissions"))
        #expect(arguments.firstIndex(of: "--allowedTools").map { arguments[$0 + 2].hasPrefix("--") } == true)

        // With nothing listed yet, no MCP tool at all: a failed listing never turns a tool on.
        let unknown = ClaudeEngine.arguments(for: prompt, model: .opus, setup: ClaudeSetup(useClaudeMd: true, inventory: nil))
        #expect(!unknown.contains("--allowedTools"))
        #expect(Self.value(after: "--disallowedTools", in: unknown)?.components(separatedBy: ",").contains("mcp__*") == true)
    }

    @Test("AI-09 a question about code with a checkout has Read, Grep and Glob inside that folder only, and no setup safeguard is dropped")
    func codeQuestion() throws {
        let folder = "/Users/dev/src/my project; rm -rf ~"
        var prompt = ClaudePrompt(useCase: .askAboutCode, instructions: "i", text: "t")
        prompt.readableFolder = folder
        let setup = Self.setup()
        let command = ClaudeEngine.command(claude: Self.claude, for: prompt, model: .sonnet, setup: setup)
        #expect(command.executable.path(percentEncoded: false) == "/usr/bin/env")
        #expect(Array(command.arguments.prefix(3)) == ["-C", folder, "/opt/homebrew/bin/claude"])
        let arguments = Array(command.arguments.dropFirst(3))
        #expect(Self.value(after: "--tools", in: arguments) == "Read,Grep,Glob")
        // Read, Grep and Glob are not allowed by name: a bare `Read` allows every path, no rule keeps them in the folder.
        #expect(Self.value(after: "--allowedTools", in: arguments)
            == "mcp__plugin_demo_builds__getBuild,mcp__plugin_demo_issues__get_issue")
        #expect(Self.value(after: "--add-dir", in: arguments) == folder)
        #expect(!arguments.contains("--safe-mode") && !arguments.contains("--restricted"))
        #expect(Self.value(after: "--max-budget-usd", in: arguments) == "10.00")
    }

    @Test("AI-09 CLAUDE.md goes through env after its own options, only when it is turned off; a claude path env would misread runs in safe mode")
    func claudeMd() {
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "t")
        let withMd = ClaudeEngine.command(
            claude: Self.claude, for: prompt, model: .opus, setup: Self.setup())
        #expect(withMd.executable == Self.claude)
        let without = ClaudeEngine.command(
            claude: Self.claude, for: prompt, model: .opus, setup: Self.setup(claudeMd: false))
        #expect(without.executable.path(percentEncoded: false) == "/usr/bin/env")
        #expect(Array(without.arguments.prefix(2)) == ["CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "/opt/homebrew/bin/claude"])

        // With a folder too: -C and its folder first, then the variable.
        var reading = prompt
        reading.readableFolder = "/Users/dev/src/project"
        let both = ClaudeEngine.command(
            claude: Self.claude, for: reading, model: .opus, setup: Self.setup(claudeMd: false))
        #expect(Array(both.arguments.prefix(4)) == [
            "-C", "/Users/dev/src/project", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "/opt/homebrew/bin/claude",
        ])

        // `env` would read this path as a variable: the run falls back to safe mode, nothing of the setup.
        let odd = ClaudeEngine.command(
            claude: URL(filePath: "/opt/A=B/claude"), for: prompt, model: .opus,
            setup: Self.setup(claudeMd: false))
        #expect(odd.executable.path(percentEncoded: false) == "/opt/A=B/claude")
        #expect(odd.arguments.contains("--safe-mode") && !odd.arguments.contains("--allowedTools"))
    }

    // MARK: - The servers

    private static let wide = ClaudeInventory(mcpTools: [
        "mcp__claude_ai_Gitlab_MCP__get_issue", "mcp__claude_ai_Gitlab_MCP__create_issue", "mcp__plugin_acme_jenkins__getBuild",
        "mcp__plugin_acme_jenkins__triggerBuild", "mcp__claude_ai_Figma__get_screenshot", "mcp__claude_ai_Figma__use_figma",
        "mcp__cmux-cua__click", "mcp__cmux-cua__get_window_state",
    ], servers: [
        ClaudeMcpServer(name: "claude.ai Gitlab MCP", status: "connected"),
        ClaudeMcpServer(name: "plugin:acme:jenkins", status: "connected"),
        ClaudeMcpServer(name: "claude.ai Figma", status: "connected"),
        ClaudeMcpServer(name: "cmux-cua", status: "connected"),
    ])

    @Test("AI-09 groups the MCP tools by server, and only the GitLab and Jenkins servers are on until the user chooses")
    func servers() {
        let groups = Self.wide.serverGroups
        #expect(groups.map(\.key) == ["claude_ai_Figma", "claude_ai_Gitlab_MCP", "cmux-cua", "plugin_acme_jenkins"])
        #expect(groups.map(\.name) == ["Figma", "Gitlab MCP", "cmux-cua", "jenkins (acme)"])
        #expect(groups.map(\.toolCount) == [2, 2, 2, 2] && groups.map(\.readingCount) == [1, 1, 1, 1])
        #expect(groups.map { $0.isOn(choices: [:]) } == [false, true, false, true])
        // The user's choice wins, either way, and a server they never chose keeps its default.
        let choices = ["claude_ai_Figma": true, "claude_ai_Gitlab_MCP": false]
        #expect(groups.map { $0.isOn(choices: choices) } == [true, false, false, true])
        // The key is what Claude Code makes of the server's name, and a name with a character that could carry a rule has none.
        #expect(McpServerGroup.key(ofServerNamed: "claude.ai Gitlab MCP") == "claude_ai_Gitlab_MCP")
        #expect(McpServerGroup.key(ofServerNamed: "plugin:acme:jenkins") == "plugin_acme_jenkins")
        #expect(McpServerGroup.key(of: "mcp__a(b)__get") == nil && McpServerGroup.key(of: "Read") == nil)
        // Remembered: the choices survive the settings' round trip, and old settings without them read as none.
        let settings = AISettings(mcpServerChoices: choices)
        #expect(try! JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings)).mcpServerChoices == choices)
        #expect(try! JSONDecoder().decode(AISettings.self, from: Data(#"{"isEnabled": true}"#.utf8)).mcpServerChoices.isEmpty)
    }

    @Test("AI-09 the arguments per server choice: a server that is off is denied by one prefix entry, one that is on by name")
    func perSelection() throws {
        let prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "t")
        func lists(_ choices: [String: Bool]) throws -> (allowed: [String], denied: [String]) {
            let arguments = ClaudeEngine.arguments(
                for: prompt, model: .opus, setup: ClaudeSetup(useClaudeMd: true, inventory: Self.wide, serverChoices: choices))
            return (
                Self.value(after: "--allowedTools", in: arguments)?.components(separatedBy: ",") ?? [],
                try #require(Self.value(after: "--disallowedTools", in: arguments)).components(separatedBy: ","))
        }
        // The default: GitLab and Jenkins read by name, their writes denied by name, the others by prefix.
        let standard = try lists([:])
        #expect(standard.allowed == ["mcp__claude_ai_Gitlab_MCP__get_issue", "mcp__plugin_acme_jenkins__getBuild"])
        #expect(standard.denied == [
            "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "mcp__claude_ai_Figma__*", "mcp__cmux-cua__*",
            "mcp__claude_ai_Gitlab_MCP__create_issue", "mcp__plugin_acme_jenkins__triggerBuild",
        ])
        // Figma on, GitLab off.
        let swapped = try lists(["claude_ai_Figma": true, "claude_ai_Gitlab_MCP": false])
        #expect(swapped.allowed == ["mcp__claude_ai_Figma__get_screenshot", "mcp__plugin_acme_jenkins__getBuild"])
        #expect(swapped.denied.contains("mcp__claude_ai_Gitlab_MCP__*") && swapped.denied.contains("mcp__claude_ai_Figma__use_figma"))
        #expect(!swapped.denied.contains("mcp__claude_ai_Figma__*"))
        // Everything off: nothing allowed, a prefix for each server.
        let none = try lists(["claude_ai_Gitlab_MCP": false, "plugin_acme_jenkins": false])
        #expect(none.allowed.isEmpty)
        #expect(Set(none.denied).isSuperset(of: ["mcp__claude_ai_Figma__*", "mcp__claude_ai_Gitlab_MCP__*", "mcp__cmux-cua__*", "mcp__plugin_acme_jenkins__*"]))
        // A tool is never allowed and denied.
        for choice in [standard, swapped, none] {
            #expect(Set(choice.allowed).isDisjoint(with: choice.denied))
        }
    }

    // MARK: - Listing the setup

    @Test("AI-09 reads the MCP tools and servers from claude's init event, asking no model")
    func listing() async throws {
        let inventory = try #require(ClaudeInventory.parse(streamJSON: FixtureFiles.data("Claude/setup-init.jsonl")))
        #expect(inventory.mcpTools.count == 11)
        #expect(inventory.servers.map(\.name).contains("claude.ai Docs"))
        #expect(inventory.servers.filter(\.isConnected).count == 3)
        // The name that smuggles a second rule in is dropped, the rest is sorted.
        let split = inventory.split
        #expect(split.reading == [
            "mcp__claude_ai_Docs__search_files", "mcp__claude_ai_Echo__echo__retrieve", "mcp__plugin_demo_builds__getBuild",
            "mcp__plugin_demo_builds__whoAmI", "mcp__plugin_demo_issues__get_issue", "mcp__plugin_demo_issues__list_issues",
        ])
        #expect(split.changing.contains("mcp__plugin_demo_builds__triggerBuild"))
        #expect(split.changing.contains("mcp__claude_ai_Docs__share_file"))
        // By server, with the names the list shows.
        let groups = inventory.serverGroups
        #expect(groups.map(\.key) == ["claude_ai_Docs", "claude_ai_Echo", "odd", "plugin_demo_builds", "plugin_demo_issues"])
        #expect(groups.map(\.name) == ["Docs", "claude_ai_Echo", "odd", "builds (demo)", "issues (demo)"])
        let issues = try #require(groups.last)
        #expect(issues.toolCount == 4 && issues.readingCount == 2 && issues.estimatedTokens == 2 * McpServerGroup.tokensPerTool)
        #expect(ClaudeInventory.parse(streamJSON: Data("not json\n{\"type\":\"result\"}".utf8)) == nil)

        let fake = SetupFake(listing: try FixtureFiles.data("Claude/setup-init.jsonl"))
        let engine = ClaudeEngine(runner: fake, resolver: fake.resolver())
        let found = try await engine.discoverSetup()
        #expect(found == inventory)
        let call = try #require(await fake.calls.first)
        #expect(Self.value(after: "--model", in: call.arguments) == ClaudeEngine.listingModel)
        #expect(Self.value(after: "--output-format", in: call.arguments) == "stream-json")
        #expect(call.arguments.contains("--verbose"))
        #expect(Self.value(after: "--tools", in: call.arguments) == "")
        #expect(Self.value(after: "--permission-mode", in: call.arguments) == "dontAsk")

        // No init event is a failure with the last line, not an empty setup.
        let broken = SetupFake(listing: Data("Error: not logged in\n".utf8), status: 1)
        let failing = ClaudeEngine(runner: broken, resolver: broken.resolver())
        await #expect(throws: ClaudeFailure.failed(status: 1, lastLine: "Error: not logged in")) {
            try await failing.discoverSetup()
        }
    }

    @Test("AI-09 a chat runs with the setup only when it is on, lists it once, and a failed listing keeps every MCP tool off")
    @MainActor
    func chatRuns() async throws {
        let item = ConversationTests.item
        let listing = try FixtureFiles.data("Claude/setup-init.jsonl")

        // Off: no listing, safe mode.
        let offFake = SetupFake(listing: listing)
        let off = Self.store(offFake, AISettings(isEnabled: true, confirmedUseCases: [.askAboutItem]))
        await off.ask("Why?", about: item, description: nil)
        await off.followUp(.workItem(item.reference), question: "And?")
        #expect(await offFake.calls.count == 2)
        #expect(await offFake.calls.allSatisfy { $0.arguments.contains("--safe-mode") && !$0.arguments.contains("stream-json") })

        // On: one listing, then the question and the follow-up with the setup.
        let onFake = SetupFake(listing: listing)
        let on = Self.store(onFake, AISettings(
            isEnabled: true, confirmedUseCases: [.askAboutItem], useMySetup: true, mcpServerChoices: Self.demoChoices))
        await on.ask("Why?", about: item, description: nil)
        await on.followUp(.workItem(item.reference), question: "And?")
        let calls = await onFake.calls
        #expect(calls.count == 3)
        #expect(calls[0].arguments.contains("stream-json"))
        for call in calls.dropFirst() {
            #expect(!call.arguments.contains("--safe-mode"))
            #expect(Self.value(after: "--allowedTools", in: call.arguments)?.contains("mcp__plugin_demo_issues__get_issue") == true)
            #expect(Self.value(after: "--allowedTools", in: call.arguments)?.contains("create_issue") == false)
        }

        // The listing fails: the chat still runs, with every MCP tool denied.
        let brokenFake = SetupFake(listing: Data("boom".utf8), status: 1)
        let broken = Self.store(brokenFake, AISettings(
            isEnabled: true, confirmedUseCases: [.askAboutItem], useMySetup: true, mcpServerChoices: Self.demoChoices))
        await broken.ask("Why?", about: item, description: nil)
        let chat = try #require(await brokenFake.calls.last)
        #expect(!chat.arguments.contains("--allowedTools"))
        #expect(Self.value(after: "--disallowedTools", in: chat.arguments)?.contains("mcp__*") == true)
        if case .failed = broken.setupInventory {} else { Issue.record("expected a failed listing") }

        // The explanations and digests are not chats: safe mode, even with the setup on.
        let digestFake = SetupFake(listing: listing)
        let digest = Self.store(digestFake, AISettings(isEnabled: true, confirmedUseCases: [.digest], useMySetup: true))
        digest.digestFacts = { AITests.someFacts }
        await digest.writeDigest()
        #expect(await digestFake.calls.allSatisfy { $0.arguments.contains("--safe-mode") })
    }

    @Test("AI-09 a question that starts with a command goes first, the facts after it; any other question stays last")
    func commandFirst() {
        var prompt = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "Facts\n\n# My question\n/review main please")
        prompt.question = "/review main please"
        let first = prompt.startingWithCommand()
        #expect(first.text.hasPrefix("/review main please\n\n"))
        #expect(first.text.contains("Facts\n\n# My question\n(my message above"))
        #expect(!first.text.dropFirst(20).contains("/review main please"))

        for question in ["Why is it slow?", "/Users/me/file.swift is wrong", "/", "a /review b"] {
            var plain = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "Facts\n\n# My question\n\(question)")
            plain.question = question
            #expect(plain.startingWithCommand() == plain, "\(question)")
        }
        // The question is redacted with the facts, so the two still match.
        var secret = ClaudePrompt(useCase: .askAboutItem, instructions: "i", text: "Facts\n/triage tok-1234567890")
        secret.question = "/triage tok-1234567890"
        let redacted = secret.redacted(by: SecretRedactor(knownSecrets: ["tok-1234567890"])).startingWithCommand()
        #expect(redacted.text.hasPrefix("/triage ") && !redacted.text.contains("tok-1234567890"))
    }

    // MARK: - The "/" list

    private static func write(_ folder: TemporaryFolder) throws {
        // The user's commands: front matter, none, a folder (namespaced), a quoted description.
        try folder.write("---\ndescription: Review all branch changes\n---\nDo it.\nAskUserQuestion is not used.\n", to: "home/.claude/commands/review-branch.md")
        try folder.write("# Heading line\nBody", to: "home/.claude/commands/plain.md")
        try folder.write("---\ndescription: \"Quoted: with colon\"\n---\n", to: "home/.claude/commands/sub/deep.md")
        // A skill with a folded description over two lines, another that asks questions, one for the developer only.
        try folder.write(
            "---\nname: hello-skill\ndescription: >\n  Say hello to\n  the whole team.\n---\n# Hello\n",
            to: "home/.claude/skills/hello/SKILL.md")
        try folder.write("---\ndescription: Asks things\n---\nUse AskUserQuestion to pick.\n", to: "home/.claude/skills/asker/SKILL.md")
        try folder.write("---\ndescription: Only me\ndisable-model-invocation: true\n---\nGo.\n", to: "home/.claude/skills/manual/SKILL.md")
        // A folder that is not a skill, and a file that is not a command.
        try folder.write("notes", to: "home/.claude/skills/empty/README.md")
        try folder.write("notes", to: "home/.claude/commands/readme.txt")
        // The checkout's own.
        try folder.write("---\ndescription: Project only\n---\n", to: "project/.claude/commands/ship.md")
        // Plugins: one on, one off in settings, one that isn't listed in the settings at all.
        let on = folder.url.appending(path: "plugins/demo/1.0.0").path(percentEncoded: false)
        let off = folder.url.appending(path: "plugins/gone/1.0.0").path(percentEncoded: false)
        try folder.write("---\ndescription: Triage an issue\n---\n", to: "plugins/demo/1.0.0/commands/triage.md")
        try folder.write("---\ndescription: Plan work\n---\n", to: "plugins/demo/1.0.0/skills/plan/SKILL.md")
        try folder.write("---\ndescription: Off\n---\n", to: "plugins/gone/1.0.0/commands/nope.md")
        try folder.write(
            """
            {"version": 2, "plugins": {
              "demo@market": [{"scope": "user", "installPath": "\(on)"}],
              "gone@market": [{"scope": "user", "installPath": "\(off)"}]}}
            """, to: "home/.claude/plugins/installed_plugins.json")
        try folder.write(#"{"enabledPlugins": {"demo@market": true, "gone@market": false}}"#, to: "home/.claude/settings.json")
    }

    @Test("AI-09 reads the user's commands and skills, the checkout's and the enabled plugins', with descriptions and the ones that may need interaction")
    func catalog() throws {
        let folder = try TemporaryFolder()
        try Self.write(folder)
        let found = SlashCommandCatalog.scan(
            home: folder.url.appending(path: "home"), project: folder.url.appending(path: "project"))
        func command(_ name: String) -> SlashCommand? { found.first { $0.name == name } }

        #expect(found.map(\.name) == [
            "ship", "asker", "hello-skill", "manual", "plain", "review-branch", "sub:deep", "demo:plan", "demo:triage",
        ])
        #expect(command("review-branch")?.summary == "Review all branch changes")
        // The body's first line stands in for a missing description.
        #expect(command("plain")?.summary == "Heading line")
        #expect(command("sub:deep")?.summary == "Quoted: with colon")
        #expect(command("hello-skill")?.summary == "Say hello to the whole team.")
        #expect(command("hello-skill")?.kind == .skill && command("review-branch")?.kind == .command)
        #expect(command("ship")?.source == .project)
        #expect(command("demo:triage")?.source == .plugin("demo") && command("demo:plan")?.kind == .skill)
        #expect(command("nope") == nil && command("gone:nope") == nil)
        // AskUserQuestion in the text, or developer-only: marked, still listed.
        let marked = found.filter(\.mayNeedInteraction).map(\.name)
        #expect(marked.sorted() == ["asker", "manual", "review-branch"])

        // Nothing installed, nothing found.
        #expect(SlashCommandCatalog.scan(home: folder.url.appending(path: "nobody")).isEmpty)
    }

    @Test("AI-09 the list opens on a slash word, filters by name then description, and inserts the command and a space")
    func filtering() {
        let all = [
            SlashCommand(name: "review-branch", summary: "Review all changes", source: .user, kind: .command),
            SlashCommand(name: "acme-git:create-issue", summary: "Write an issue", source: .plugin("acme-git"), kind: .skill),
            SlashCommand(name: "commit-review", summary: "Review the staged diff", source: .user, kind: .command),
            SlashCommand(name: "sra", summary: "Security risk assessment, short", source: .user, kind: .command),
            SlashCommand(name: "Review", summary: "", source: .project, kind: .command),
        ]
        func names(_ query: String) -> [String] { SlashCommandCatalog.filter(all, query: query).map(\.name) }

        #expect(names("") == all.map(\.name))
        // A name that starts with it first; a plugin's own name counts as the start; then contains; then the description.
        #expect(names("rev") == ["review-branch", "Review", "commit-review"])
        #expect(names("create") == ["acme-git:create-issue"])
        #expect(names("acme") == ["acme-git:create-issue"])
        #expect(names("risk") == ["sra"])
        #expect(names("REVIEW") == ["review-branch", "Review", "commit-review"])
        #expect(names("zzz").isEmpty)

        #expect(SlashCommandCatalog.pendingQuery(in: "/") == "")
        #expect(SlashCommandCatalog.pendingQuery(in: "/rev") == "rev")
        #expect(SlashCommandCatalog.pendingQuery(in: "/review ") == nil)
        #expect(SlashCommandCatalog.pendingQuery(in: "/review main") == nil)
        #expect(SlashCommandCatalog.pendingQuery(in: "why /rev") == nil)
        #expect(SlashCommandCatalog.pendingQuery(in: "") == nil)
        #expect(SlashCommandCatalog.insertion(for: all[1]) == "/acme-git:create-issue ")
        #expect(SlashCommandCatalog.leadingCommand(in: "/acme-git:create-issue Fix it") == "acme-git:create-issue")
        #expect(SlashCommandCatalog.leadingCommand(in: "/Users/me/x") == nil)
    }

    // MARK: - Helpers

    @MainActor
    private static func store(_ fake: SetupFake, _ settings: AISettings) -> AIStore {
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        store.update(settings)
        return store
    }
}

/// A `claude` that answers the setup listing (the one run with stream-json) with a canned output and every other run
/// with a plain answer, and a login shell that knows no `PATH`.
private actor SetupFake: ProcessRunner {
    struct Call: Sendable {
        var arguments: [String]
        var input: String?
    }

    private let listing: Data
    private let listingStatus: Int32
    private(set) var calls: [Call] = []

    init(listing: Data, status: Int32 = 0) {
        self.listing = listing
        listingStatus = status
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        // The program may be env with claude after its options.
        calls.append(Call(arguments: arguments, input: input.map { String(decoding: $0, as: UTF8.self) }))
        if arguments.contains("stream-json") {
            return ProcessOutput(status: listingStatus, standardOutput: listing)
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

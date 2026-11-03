import Foundation
import Testing

@testable import MenubarCore

/// AI-10: the chat card as a Claude Code host. The lines are a sanitized recording of Claude Code 2.1.317's
/// stream-json protocol (`Tests/Fixtures/Claude/host-turn.jsonl`); no real `claude` runs.
@Suite("Claude host")
struct ClaudeHostTests {
    private static func fixtureEvents() throws -> [ClaudeHostEvent] {
        let data = try FixtureFiles.data("Claude/host-turn.jsonl")
        return data.split(separator: UInt8(ascii: "\n")).flatMap { ClaudeHostMessage.events(in: Data($0)) }
    }

    // MARK: - Reading

    @Test("AI-10 reads Claude Code's host lines: commands, streamed text, tool calls, requests, cancels and the result; a subagent's text isn't the answer")
    func reading() throws {
        let events = try Self.fixtureEvents()
        guard case .initialized(let commands) = events.first else {
            Issue.record("initialize's answer comes first")
            return
        }
        // Claude Code's own session commands, like /compact, mean nothing in a card.
        #expect(commands.map(\.name) == ["review-branch", "demo-git:merge-request-description"])
        #expect(commands[0].summary == "Review all branch changes" && commands[0].source == .user)
        #expect(commands[1].source == .plugin("demo-git"))
        #expect(events.contains(.started(model: "claude-haiku-5-5")))
        #expect(events.contains(.unsupported(requestID: "req-hook")))
        #expect(!events.contains(.text("A subagent's own words.")))

        var turn = ClaudeHostTurn()
        var seen: [String] = []
        for event in events {
            turn.apply(event)
            if case .textDelta = event {
                seen.append(turn.text)
            }
            if case .request(let request) = event, request.toolName == "Bash" {
                #expect(turn.pending.map(\.requestID) == ["req-bash"])
                #expect(request.summary == "git log --oneline origin/main..HEAD")
                #expect(request.offersAlways)
                turn.answered(request.requestID)
            }
            if case .request(let request) = event, request.toolName == "AskUserQuestion" {
                #expect(request.isQuestion)
                #expect(request.questions.first?.header == "Tone")
                #expect(request.questions.first?.options.map(\.label) == ["Short", "Detailed"])
                #expect(!request.offersAlways)
            }
        }
        // The text streams as it comes, then the whole block replaces it.
        #expect(seen == ["Let me look at ", "Let me look at the branch."])
        #expect(turn.steps.map(\.toolName) == ["Bash", "AskUserQuestion"])
        #expect(turn.steps.allSatisfy { $0.status == .done })
        // The Write request was cancelled, the question is gone with the result.
        #expect(turn.pending.isEmpty)
        #expect(turn.answer == "## Summary\n\nAdds the thing.")
        let run = turn.run(fallbackModel: "haiku")
        #expect(run.model == "claude-haiku-5-5" && !run.isError && run.usage.inputTokens == 100)
        let raw = turn.raw(model: nil, stderrTail: "warning: something")
        #expect(raw.outcome == "success, completed" && raw.durationMS == 4200)
        #expect(raw.toolCalls == ["Bash: git log --oneline origin/main..HEAD", "AskUserQuestion"])
        #expect(!raw.asText.contains("cost") && !raw.asText.contains("0.01"))
    }

    @Test("AI-10 a tool call reads in one line: the command, the file, the pattern, an MCP tool's arguments", arguments: [
        ("Bash", #"{"command":"git status"}"#, "git status"),
        ("Write", #"{"file_path":"/work/a.md","content":"x"}"#, "/work/a.md"),
        ("Grep", #"{"pattern":"TODO","path":"/work/src"}"#, "TODO in /work/src"),
        ("mcp__plugin_demo_gitlab__update_merge_request", #"{"iid":3,"project_id":"group/app","description":{"x":1}}"#, "iid: 3, project_id: group/app"),
        ("Skill", #"{"skill":"review-branch"}"#, "review-branch"),
    ])
    func summary(tool: String, json: String, line: String) throws {
        let input = try #require(JSONValue(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        #expect(ClaudeHostTool.summary(name: tool, input: input) == line)
        #expect(ClaudeHostTool.title(of: "mcp__plugin_demo_gitlab__update_merge_request") == "demo_gitlab · update_merge_request")
    }

    // MARK: - Answering

    private static let bash = ClaudeHostRequest(
        requestID: "r1", toolName: "Bash",
        input: .object(["command": .string("touch a.txt"), "timeout": .int(60000)]),
        suggestions: [
            .object([
                "type": .string("addRules"), "behavior": .string("allow"), "destination": .string("localSettings"),
                "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("touch a.txt")])]),
            ]),
            .object(["type": .string("addRules"), "behavior": .string("deny"), "destination": .string("userSettings"),
                     "rules": .array([.object(["toolName": .string("Bash")])])]),
            .object(["type": .string("addDirectories"), "directories": .array([.string("/work")]), "destination": .string("session")]),
            .object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")]),
            .object(["type": .string("setMode"), "mode": .string("bypassPermissions"), "destination": .string("session")]),
        ])

    @Test("AI-10 Always for This Chat sends only the addRules that allow, for the session: never setMode, addDirectories or a settings file")
    func always() throws {
        let decision = ClaudePermissionAnswer.decision(.allowAlways, for: Self.bash)
        #expect(decision["behavior"] == .string("allow"))
        #expect(decision["updatedInput"] == Self.bash.input)
        let rules = try #require(decision["updatedPermissions"]?.array)
        #expect(rules.count == 1)
        #expect(rules[0]["type"] == .string("addRules") && rules[0]["destination"] == .string("session"))
        #expect(rules[0]["rules"]?.array?.first?["ruleContent"] == .string("touch a.txt"))
        // Without a rule to add, "always" is a plain allow, and the card doesn't offer it.
        let write = ClaudeHostRequest(
            requestID: "r2", toolName: "Write", input: .object(["file_path": .string("/work/a")]),
            suggestions: [.object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")])])
        #expect(!write.offersAlways)
        #expect(ClaudePermissionAnswer.decision(.allowAlways, for: write)["updatedPermissions"] == nil)
    }

    @Test("AI-10 Allow sends the input back unchanged, Deny tells Claude why, and a question's answers go into updatedInput")
    func answers() throws {
        let once = ClaudePermissionAnswer.decision(.allowOnce, for: Self.bash)
        #expect(once == .object(["behavior": .string("allow"), "updatedInput": Self.bash.input]))
        let line = String(decoding: ClaudeHostMessage.response(to: "r1", decision: once), as: UTF8.self)
        #expect(line.hasSuffix("\n") && line.contains(#""request_id":"r1""#) && line.contains(#""timeout":60000"#))

        let deny = ClaudePermissionAnswer.decision(.deny("  "), for: Self.bash)
        #expect(deny["behavior"] == .string("deny") && deny["message"]?.string?.isEmpty == false)

        let question = ClaudeHostRequest(
            requestID: "r3", toolName: "AskUserQuestion",
            input: .object(["questions": .array([.object(["question": .string("Which tone?")])])]),
            questions: [ClaudeHostQuestion(question: "Which tone?")])
        let answered = ClaudePermissionAnswer.decision(.answers(["Which tone?": "Short"]), for: question)
        #expect(answered["behavior"] == .string("allow"))
        #expect(answered["updatedInput"]?["answers"] == .object(["Which tone?": .string("Short")]))
        #expect(answered["updatedInput"]?["questions"] != nil)
    }

    @Test("AI-10 the host's arguments: stream-json both ways, every permission to the card in default mode, no tool allowed by name, WebFetch and the servers that are off denied")
    func arguments() {
        let setup = ClaudeSetup(
            useClaudeMd: false,
            inventory: ClaudeInventory(mcpTools: ["mcp__plugin_demo_gitlab__get_issue", "mcp__claude_ai_Docs__share_file"]),
            serverChoices: ["plugin_demo_gitlab": true, "claude_ai_Docs": false])
        let arguments = ClaudeEngine.hostArguments(model: .sonnet, effort: .standard, setup: setup)
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value("--input-format") == "stream-json" && value("--output-format") == "stream-json")
        #expect(value("--permission-prompt-tool") == "stdio")
        #expect(value("--permission-mode") == "default")
        #expect(value("--max-budget-usd") != nil && arguments.contains("--no-session-persistence"))
        #expect(!arguments.contains("--allowedTools") && !arguments.contains("--tools") && !arguments.contains("--safe-mode"))
        let denied = value("--disallowedTools")?.components(separatedBy: ",") ?? []
        #expect(denied.contains("WebFetch") && denied.contains("WebSearch") && denied.contains("mcp__claude_ai_Docs__*"))
        #expect(!denied.contains("Bash") && !denied.contains { $0.contains("demo_gitlab") })
        #expect(ClaudeEngine.hostEnvironment(setup: setup) == ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"])
    }

    // MARK: - The store

    @Test("AI-10 a chat with the setup runs Claude Code in its card: initialize first, the facts once, a follow-up only the question, a request waits for a click, Stop interrupts, Clear ends it")
    @MainActor
    func store() async throws {
        let launcher = HostFake()
        let runner = HostRunnerFake()
        let defaults = TemporaryDefaults()
        let store = AIStore(defaults: defaults.defaults, runner: runner, resolver: runner.resolver())
        store.hostLauncher = launcher
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.askAboutItem], useMySetup: true))
        let folder = try TemporaryFolder()
        store.hostScratchFolder = folder.url
        let item = ConversationTests.item
        let subject = AISubject.workItem(item.reference)

        // The first question: Claude asks to run Bash, and the turn waits until the card answers.
        let first = Task { await store.ask("/demo-git:merge-request-description please", about: item, description: "Secret: none") }
        let connection = try await launcher.waitForConnection()
        try await connection.waitForSent { $0.contains(#""type":"user""#) }
        #expect(connection.sent.first?.contains(#""subtype":"initialize""#) == true)
        let opening = try #require(connection.sent.first { $0.contains(#""type":"user""#) })
        // A command goes first, the facts after it.
        #expect(opening.contains(#""content":"\/demo-git:merge-request-description please"#)
            || opening.contains(#""content":"/demo-git:merge-request-description please"#))
        #expect(opening.contains("Fix the cart"))
        connection.emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[{"name":"review-branch","description":"Review (user)"}]}}}"#)
        connection.emit(#"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"git status"},"permission_suggestions":[]}}"#)
        try await waitUntil { store.hostChats[subject]?.turn?.pending.count == 1 }
        #expect(store.commands(for: subject).map(\.name) == ["review-branch"])
        #expect(!connection.sent.contains { $0.contains(#""request_id":"q1""#) })
        let request = try #require(store.hostChats[subject]?.turn?.pending.first)
        store.answer(request, of: subject, with: .allowOnce)
        #expect(connection.sent.last?.contains(#""behavior":"allow""#) == true)
        #expect(store.hostChats[subject]?.turn?.pending.isEmpty == true)
        connection.emit(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Draft"}},"parent_tool_use_id":null}"#)
        connection.emit(#"{"type":"result","subtype":"success","is_error":false,"result":"The description.","duration_ms":10,"modelUsage":{"claude-sonnet-5-5":{}}}"#)
        await first.value
        guard case .answered(let answer) = store.state(of: subject) else {
            Issue.record("the first answer lands")
            return
        }
        #expect(answer.text == "The description.")
        #expect(answer.raw?.outcome == "success")

        // A follow-up goes to the same process, as the question alone.
        let sentBefore = connection.sent.count
        let follow = Task { await store.followUp(subject, question: "Shorter?") }
        try await connection.waitForSent { $0.contains("Shorter?") }
        let message = try #require(connection.sent.dropFirst(sentBefore).first { $0.contains(#""type":"user""#) })
        #expect(!message.contains("Fix the cart"))
        #expect(launcher.connections.count == 1)

        // Stop sends interrupt; Claude ends the turn and stays.
        store.stopFollowUp(of: subject)
        try await connection.waitForSent { $0.contains(#""subtype":"interrupt""#) }
        connection.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming"}"#)
        await follow.value
        #expect(store.turns(of: subject).isEmpty)
        #expect(!connection.isClosed)

        // Clear ends the process.
        store.dismiss(subject)
        #expect(connection.isClosed)
        #expect(store.hostChats[subject] == nil)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        let met = condition()
        #expect(met)
    }
}

/// A `claude` the store hosts: it records what is sent and emits the lines a test gives it.
private final class HostConnectionFake: ClaudeHostConnection, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sentLines: [String] = []
    private var closed = false

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    var sent: [String] { lock.withLock { sentLines } }
    var isClosed: Bool { lock.withLock { closed } }

    func emit(_ line: String) {
        continuation.yield(Data(line.utf8))
    }

    func send(_ data: Data) {
        lock.withLock { sentLines.append(String(decoding: data, as: UTF8.self)) }
    }

    func closeInput() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    func terminate() {
        closeInput()
    }

    func stderrTail() -> String { "" }
    func exitStatus() -> Int32? { isClosed ? 0 : nil }

    func waitForSent(_ match: @Sendable (String) -> Bool) async throws {
        for _ in 0..<400 where !sent.contains(where: match) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let found = sent.contains(where: match)
        #expect(found)
    }
}

/// Starts fake connections and keeps them.
private final class HostFake: ClaudeHostLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [HostConnectionFake] = []

    var connections: [HostConnectionFake] { lock.withLock { started } }

    func start(executable: URL, arguments: [String], folder: URL, environment: [String: String]) throws
        -> any ClaudeHostConnection
    {
        #expect(arguments.contains("--permission-prompt-tool"))
        let connection = HostConnectionFake()
        lock.withLock { started.append(connection) }
        return connection
    }

    func waitForConnection() async throws -> HostConnectionFake {
        for _ in 0..<400 where connections.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(connections.first)
    }
}

/// A login shell that knows no `PATH`, a `claude` that only says its version, and a setup listing with no MCP tools.
private actor HostRunnerFake: ProcessRunner {
    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        if arguments == ["--version"] {
            return ProcessOutput(status: 0, standardOutput: Data("2.1.317 (Claude Code)\n".utf8))
        }
        let initLine = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[]}"#
        return ProcessOutput(status: 0, standardOutput: Data(initLine.utf8))
    }

    nonisolated func resolver() -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { $0 == "/opt/homebrew/bin/claude" }
    }
}

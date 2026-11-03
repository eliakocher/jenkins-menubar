import Foundation

// MARK: - JSON values

/// A JSON value as Claude Code sent it, kept to be sent back unchanged: a tool's input goes back as `updatedInput`.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Returns the value of a `JSONSerialization` object; `nil` for anything JSON can't hold.
    public init?(_ any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let text as String:
            self = .string(text)
        case let array as [Any]:
            var values: [JSONValue] = []
            for element in array {
                guard let value = JSONValue(element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let object as [String: Any]:
            var values: [String: JSONValue] = [:]
            for (key, element) in object {
                guard let value = JSONValue(element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    /// the value as a `JSONSerialization` object
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    /// the member of an object; `nil` for anything else
    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { values[key] } else { nil }
    }

    /// the text of a string
    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// the elements of an array
    public var array: [JSONValue]? {
        if case .array(let values) = self { values } else { nil }
    }

    /// the value as pretty JSON text, for the card's disclosure
    public var prettyText: String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        return (try? JSONSerialization.data(withJSONObject: any, options: options)).map { String(decoding: $0, as: UTF8.self) }
            ?? ""
    }
}

// MARK: - What Claude Code asks

/// One question of `AskUserQuestion`, with its options.
public struct ClaudeHostQuestion: Hashable, Sendable, Identifiable {
    public struct Option: Hashable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    /// the question, which is also the key of its answer
    public var question: String
    /// a short label, shown as a chip
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public var id: String { question }

    public init(question: String, header: String = "", options: [Option] = [], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A tool call Claude Code asks the card about (`can_use_tool`), or a question for the developer (`AskUserQuestion`,
/// `requires_user_interaction`).
public struct ClaudeHostRequest: Hashable, Sendable, Identifiable {
    /// Claude Code's id of the request, which the answer names
    public var requestID: String
    public var toolName: String
    /// the name to show, like "Bash"
    public var displayName: String
    /// the tool's input, sent back unchanged with an allow
    public var input: JSONValue
    /// Claude Code's suggestions for "always"; only their `addRules` are ever sent back (``ClaudePermissionAnswer``)
    public var suggestions: [JSONValue]
    /// the questions of an `AskUserQuestion`; empty for a tool call
    public var questions: [ClaudeHostQuestion]

    public var id: String { requestID }

    public init(
        requestID: String, toolName: String, displayName: String? = nil, input: JSONValue = .object([:]),
        suggestions: [JSONValue] = [], questions: [ClaudeHostQuestion] = []
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.displayName = displayName ?? toolName
        self.input = input
        self.suggestions = suggestions
        self.questions = questions
    }

    /// whether it is a question for the developer rather than a tool call
    public var isQuestion: Bool {
        !questions.isEmpty
    }

    /// what the call does, in one line: the command, the file, the pattern, the MCP tool's name
    public var summary: String {
        ClaudeHostTool.summary(name: toolName, input: input)
    }

    /// whether "Always for This Chat" can be offered: Claude Code suggested a rule to add
    public var offersAlways: Bool {
        !ClaudePermissionAnswer.sessionRules(from: suggestions).isEmpty
    }
}

/// How a turn ended, from Claude Code's `result` line.
public struct ClaudeHostResult: Hashable, Sendable {
    /// `success`, `error_during_execution` (stopped), `error_max_budget_usd`…
    public var subtype: String
    public var isError: Bool
    /// the final text
    public var text: String?
    public var durationMS: Int?
    public var turns: Int?
    /// `end_turn`…
    public var stopReason: String?
    /// `completed`, `aborted_streaming`, `aborted_tools`…
    public var terminalReason: String?
    /// how many tool calls were denied
    public var denials: Int
    /// the model that answered, like `claude-opus-5-5`
    public var model: String?
    public var usage: ClaudeUsage
    public var errors: [String]

    public init(
        subtype: String, isError: Bool = false, text: String? = nil, durationMS: Int? = nil, turns: Int? = nil,
        stopReason: String? = nil, terminalReason: String? = nil, denials: Int = 0, model: String? = nil,
        usage: ClaudeUsage = ClaudeUsage(), errors: [String] = []
    ) {
        self.subtype = subtype
        self.isError = isError
        self.text = text
        self.durationMS = durationMS
        self.turns = turns
        self.stopReason = stopReason
        self.terminalReason = terminalReason
        self.denials = denials
        self.model = model
        self.usage = usage
        self.errors = errors
    }
}

/// One line of Claude Code's stream-json output, as the card needs it.
public enum ClaudeHostEvent: Hashable, Sendable {
    /// `initialize`'s answer: the slash commands and skills, for the "/" list
    case initialized(commands: [SlashCommand])
    /// a turn's `system/init`: the model
    case started(model: String?)
    /// a new text block begins
    case textStarted
    /// streamed text of the current block
    case textDelta(String)
    /// a whole text block of the main conversation
    case text(String)
    /// Claude calls a tool
    case toolUse(id: String, name: String, input: JSONValue)
    /// a tool's result came back
    case toolResult(id: String, isError: Bool)
    /// a tool call or a question waits for the developer
    case request(ClaudeHostRequest)
    /// a control request the app doesn't serve; it is answered with an error
    case unsupported(requestID: String)
    /// a waiting request is gone, as after Stop
    case cancelled(requestID: String)
    /// the turn ended
    case finished(ClaudeHostResult)
}

// MARK: - Reading and writing lines

/// The stream-json control protocol of Claude Code as a host speaks it (probed with 2.1.317,
/// `docs/spikes/claude-host-protocol.md`): one JSON object per line both ways.
public enum ClaudeHostMessage {
    /// the id of the `initialize` request
    public static let initializeID = "init-1"

    /// Reads one line of Claude Code's output; lines the card doesn't need give no event.
    ///
    /// - Parameter line: one line, without its line break
    /// - Returns: the events in it
    public static func events(in line: Data) -> [ClaudeHostEvent] {
        guard let any = try? JSONSerialization.jsonObject(with: line), let object = JSONValue(any),
            let type = object["type"]?.string
        else {
            return []
        }
        // A subagent's own lines carry the tool use they belong to; its text isn't the answer.
        let isMain = object["parent_tool_use_id"].map { $0 == .null } ?? true
        switch type {
        case "control_response":
            let response = object["response"]
            guard response?["request_id"]?.string == initializeID, let inner = response?["response"] else {
                return []
            }
            let commands = (inner["commands"]?.array ?? []).compactMap(command(from:))
            return [.initialized(commands: commands)]
        case "control_request":
            guard let id = object["request_id"]?.string, let request = object["request"] else {
                return []
            }
            guard request["subtype"]?.string == "can_use_tool", let tool = request["tool_name"]?.string else {
                return [.unsupported(requestID: id)]
            }
            let input = request["input"] ?? .object([:])
            return [
                .request(
                    ClaudeHostRequest(
                        requestID: id, toolName: tool, displayName: request["display_name"]?.string, input: input,
                        suggestions: request["permission_suggestions"]?.array ?? [],
                        questions: tool == "AskUserQuestion" ? questions(in: input) : []))
            ]
        case "control_cancel_request":
            return object["request_id"]?.string.map { [.cancelled(requestID: $0)] } ?? []
        case "system":
            return object["subtype"]?.string == "init" ? [.started(model: object["model"]?.string)] : []
        case "stream_event":
            guard isMain, let event = object["event"] else { return [] }
            switch event["type"]?.string {
            case "content_block_start" where event["content_block"]?["type"]?.string == "text":
                return [.textStarted]
            case "content_block_delta" where event["delta"]?["type"]?.string == "text_delta":
                return event["delta"]?["text"]?.string.map { [.textDelta($0)] } ?? []
            default:
                return []
            }
        case "assistant":
            guard isMain else { return [] }
            return (object["message"]?["content"]?.array ?? []).compactMap { block in
                switch block["type"]?.string {
                case "text": block["text"]?.string.map { .text($0) }
                case "tool_use":
                    block["id"]?.string.flatMap { id in
                        block["name"]?.string.map { .toolUse(id: id, name: $0, input: block["input"] ?? .object([:])) }
                    }
                default: nil
                }
            }
        case "user":
            return (object["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
                return .toolResult(id: id, isError: block["is_error"] == .bool(true))
            }
        case "result":
            return [.finished(result(from: object))]
        default:
            return []
        }
    }

    /// Claude Code's own commands that steer a terminal session, which mean nothing in a card (and `/cost` would show
    /// money): left out of the "/" list
    static let hiddenCommands: Set<String> = [
        "add-dir", "agents", "auto-mode-setup", "autocompact", "batch", "bug", "clear", "color", "compact", "config",
        "context", "cost", "design-consent", "design-revoke", "doctor", "effort", "exit", "export", "extra-usage", "fast",
        "feedback", "focus", "goal", "heapdump", "hooks", "ide", "insights", "install-github-app", "list-agents", "login",
        "logout", "loop", "mcp", "memory", "model", "output-style", "permissions", "privacy-settings", "recap",
        "release-notes", "reload-plugins", "reload-skills", "rename", "resume", "schedule", "status", "statusline",
        "team-onboarding", "terminal-setup", "upgrade", "usage", "usage-credits", "vim", "workflow-launch-exec",
    ]

    private static func command(from value: JSONValue) -> SlashCommand? {
        guard let name = value["name"]?.string, !name.isEmpty, !name.hasPrefix("_"), !hiddenCommands.contains(name) else {
            return nil
        }
        var summary = value["description"]?.string ?? ""
        // Claude Code adds where it comes from in brackets: "(user)", "(project)", "(plugin-name)"; its own have none.
        var source = SlashCommand.Source.plugin("Claude Code")
        let origin: String? =
            if summary.hasSuffix(")"), let open = summary.range(of: " (", options: .backwards) {
                String(summary[open.upperBound..<summary.index(before: summary.endIndex)])
            } else {
                nil
            }
        // An origin is one word; a remark in brackets, "(resumable with /resume)", stays in the description.
        if let origin, !origin.isEmpty, !origin.contains(where: \.isWhitespace) {
            summary = String(summary.dropLast(origin.count + 3))
            source = origin == "user" ? .user : origin == "project" ? .project : .plugin(origin)
        } else if let colon = name.firstIndex(of: ":") {
            source = .plugin(String(name[..<colon]))
        }
        return SlashCommand(
            name: name, summary: String(summary.prefix(SlashCommandCatalog.summaryLimit)), source: source, kind: .skill)
    }

    private static func questions(in input: JSONValue) -> [ClaudeHostQuestion] {
        (input["questions"]?.array ?? []).compactMap { value in
            guard let question = value["question"]?.string else { return nil }
            let options = (value["options"]?.array ?? []).compactMap { option in
                option["label"]?.string.map { ClaudeHostQuestion.Option(label: $0, description: option["description"]?.string ?? "") }
            }
            return ClaudeHostQuestion(
                question: question, header: value["header"]?.string ?? "", options: options,
                multiSelect: value["multiSelect"] == .bool(true))
        }
    }

    private static func result(from object: JSONValue) -> ClaudeHostResult {
        func int(_ key: String) -> Int? {
            switch object[key] {
            case .int(let value): value
            case .double(let value): Int(value)
            default: nil
            }
        }
        let usage = object["usage"]
        func tokens(_ key: String) -> Int {
            if case .int(let value) = usage?[key] { value } else { 0 }
        }
        let models: [String] = if case .object(let byModel) = object["modelUsage"] { byModel.keys.sorted() } else { [] }
        let subtype = object["subtype"]?.string ?? "unknown"
        return ClaudeHostResult(
            subtype: subtype, isError: object["is_error"] == .bool(true) || subtype != "success",
            text: object["result"]?.string, durationMS: int("duration_ms"), turns: int("num_turns"),
            stopReason: object["stop_reason"]?.string, terminalReason: object["terminal_reason"]?.string,
            denials: object["permission_denials"]?.array?.count ?? 0, model: models.first,
            usage: ClaudeUsage(
                inputTokens: tokens("input_tokens") + tokens("cache_creation_input_tokens") + tokens("cache_read_input_tokens"),
                outputTokens: tokens("output_tokens")),
            errors: (object["errors"]?.array ?? []).compactMap(\.string))
    }

    // MARK: Writing

    /// `initialize`, the first line a host sends
    public static func initialize() -> Data {
        line(["type": "control_request", "request_id": initializeID, "request": ["subtype": "initialize"]])
    }

    /// a user message: a question, or `/command args`
    public static func user(_ text: String) -> Data {
        line([
            "type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(), "session_id": "",
        ])
    }

    /// Stop: Claude ends the turn with a `result` and stays alive for the next message
    public static func interrupt(id: String) -> Data {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    /// the answer to a request
    public static func response(to requestID: String, decision: JSONValue) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": decision.any]])
    }

    /// the answer to a control request the app doesn't serve
    public static func unsupported(_ requestID: String) -> Data {
        line([
            "type": "control_response",
            "response": ["subtype": "error", "request_id": requestID, "error": "MegaMonitor doesn't support this request"],
        ])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - The answers

/// What the developer answered in the card.
public enum ClaudePermissionChoice: Hashable, Sendable {
    /// Allow: this call only
    case allowOnce
    /// Always for This Chat: this call, and Claude Code's suggested rules for the rest of the process
    case allowAlways
    /// Deny, with what Claude is told
    case deny(String)
    /// the answers to an `AskUserQuestion`, by question text: a label, labels joined with ", ", or free text
    case answers([String: String])
}

/// Turns the developer's choice into Claude Code's permission answer (AI-10). The rule that matters:
///
/// - Allow sends the input back unchanged.
/// - "Always for This Chat" sends only `addRules` suggestions that allow, with their destination rewritten to `session`:
///   never `setMode` (it would let later, different calls run unasked), never `addDirectories`, and never a destination
///   that writes a settings file (`localSettings` wrote the checkout's `.claude/settings.local.json` in the probe).
/// - Nothing is allowed without the developer's click: the app never answers a request by itself.
public enum ClaudePermissionAnswer {
    /// Returns the rules "Always for This Chat" may add: the `addRules` suggestions that allow, for this session only.
    ///
    /// - Parameter suggestions: Claude Code's `permission_suggestions`
    /// - Returns: the rewritten suggestions; empty when there is nothing safe to add
    public static func sessionRules(from suggestions: [JSONValue]) -> [JSONValue] {
        suggestions.compactMap { suggestion in
            guard case .object(var fields) = suggestion, fields["type"]?.string == "addRules",
                fields["behavior"]?.string == "allow", let rules = fields["rules"]?.array, !rules.isEmpty,
                rules.allSatisfy({ $0["toolName"]?.string?.isEmpty == false })
            else {
                return nil
            }
            fields["destination"] = .string("session")
            return .object(fields)
        }
    }

    /// Returns the decision Claude Code gets for a request.
    ///
    /// - Parameters:
    ///   - choice: what the developer chose
    ///   - request: the request
    /// - Returns: the inner `response` of the `control_response`
    public static func decision(_ choice: ClaudePermissionChoice, for request: ClaudeHostRequest) -> JSONValue {
        switch choice {
        case .allowOnce:
            return .object(["behavior": .string("allow"), "updatedInput": request.input])
        case .allowAlways:
            var fields: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": request.input]
            let rules = sessionRules(from: request.suggestions)
            if !rules.isEmpty {
                fields["updatedPermissions"] = .array(rules)
            }
            return .object(fields)
        case .deny(let message):
            let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return .object([
                "behavior": .string("deny"),
                "message": .string(words.isEmpty ? "The developer denied this in MegaMonitor." : words),
            ])
        case .answers(let answers):
            guard case .object(var input) = request.input else {
                return .object(["behavior": .string("deny"), "message": .string("The question couldn't be answered.")])
            }
            input["answers"] = .object(answers.mapValues(JSONValue.string))
            return .object(["behavior": .string("allow"), "updatedInput": .object(input)])
        }
    }
}

// MARK: - Tool lines

/// How a tool call reads in one line of the card.
public enum ClaudeHostTool {
    /// the longest summary, in characters
    static let summaryLimit = 300

    /// Returns what a call does: the command of Bash, the file of Read, Edit and Write, the pattern of Grep and Glob,
    /// the address of WebFetch, the skill's name, a subagent's description, an MCP tool's first plain arguments.
    ///
    /// - Parameters:
    ///   - name: the tool's name
    ///   - input: its input
    /// - Returns: one line
    public static func summary(name: String, input: JSONValue) -> String {
        let keys: [String] =
            switch name {
            case "Bash": ["command"]
            case "Read", "Edit", "MultiEdit", "Write": ["file_path"]
            case "NotebookEdit": ["notebook_path"]
            case "Grep", "Glob": ["pattern"]
            case "WebFetch": ["url"]
            case "WebSearch": ["query"]
            case "Skill": ["skill", "command"]
            case "Task", "Agent": ["description"]
            default: []
            }
        if let text = keys.lazy.compactMap({ input[$0]?.string }).first {
            var line = text
            if name == "Grep" || name == "Glob", let path = input["path"]?.string {
                line += " in " + path
            }
            return clipped(line)
        }
        if name.hasPrefix("mcp__") {
            // The tool's name is in the title; its first plain arguments say what it is about.
            guard case .object(let fields) = input else { return "" }
            let pairs = fields.keys.sorted().compactMap { key -> String? in
                switch fields[key] {
                case .string(let text): "\(key): \(text)"
                case .int(let number): "\(key): \(number)"
                case .bool(let flag): "\(key): \(flag)"
                default: nil
                }
            }
            return clipped(pairs.prefix(3).joined(separator: ", "))
        }
        if case .object(let fields) = input, let first = fields.keys.sorted().lazy.compactMap({ fields[$0]?.string }).first {
            return clipped(first)
        }
        return ""
    }

    /// the tool's name for the card: "Bash", or an MCP tool's server and tool, "gitlab · get_issue"
    public static func title(of name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3 else { return name }
        let server = parts[1].replacingOccurrences(of: "plugin_", with: "").replacingOccurrences(of: "claude_ai_", with: "")
        return server + " · " + parts.dropFirst(2).joined(separator: "__")
    }

    private static func clipped(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return line.count > summaryLimit ? String(line.prefix(summaryLimit)) + "…" : line
    }
}

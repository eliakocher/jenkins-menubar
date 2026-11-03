import Foundation

/// Why Claude gave no answer (AI-01), in words for the card: a failure stays plainly a failure.
public enum ClaudeFailure: Error, Hashable, Sendable {
    /// `claude` isn't installed where the login shell or the usual places would find it
    case notFound
    /// it ran longer than ``ClaudeEngine/timeout``
    case timedOut
    /// it couldn't be started
    case couldNotRun(String)
    /// it ended without the JSON answer, with its exit status and its last line
    case failed(status: Int32, lastLine: String?)
    /// it answered with an error, like no login or a call stopped by its safety limit
    case answeredError(ClaudeRun)
    /// the answer didn't have the shape asked for
    case unreadableAnswer(ClaudeRun)
    /// the installed `claude` is too old to run the model's alias, with the version it says it needs, when it says
    case outdated(required: String?)

    /// the sentence of ``outdated(required:)``; the views know it by this text and offer ``updateCommand``
    public static let outdatedMessage = "Claude Code is too old for this model. Update it: claude update"
    /// the command that updates Claude Code
    public static let updateCommand = "claude update"

    /// Returns whether `claude` said it is too old for the model: "Claude Code 2.1.236 does not support this model;
    /// version 2.1.280 or newer is required."
    ///
    /// - Parameter text: what `claude` answered or printed
    public static func saysOutdated(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("does not support this model") || lowered.contains("or newer is required")
    }

    /// Returns the version `claude` says it needs ("2.1.280"), if its text names one.
    ///
    /// - Parameter text: what `claude` answered or printed
    public static func requiredVersion(in text: String) -> String? {
        guard let end = text.range(of: " or newer", options: .caseInsensitive) else {
            return nil
        }
        let word = text[..<end.lowerBound].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let isVersion = !word.isEmpty && word.first?.isNumber == true && word.allSatisfy { $0.isNumber || $0 == "." }
        return isVersion ? word : nil
    }

    /// the failure in a sentence
    public var message: String {
        switch self {
        case .outdated:
            Self.outdatedMessage
        case .notFound:
            "Claude Code (claude) isn't installed. Install it, then sign in with claude in Terminal."
        case .timedOut:
            "Claude didn't answer in time."
        case .couldNotRun(let reason):
            "Couldn't start claude: \(reason)"
        case .failed(let status, let lastLine):
            lastLine.map { "claude ended with \(status): \($0)" } ?? "claude ended with \(status)"
        case .answeredError(let run):
            // A call stopped by the safety limit already says so in plain words.
            run.subtype == "error_max_budget_usd" ? run.errorMessage : "Claude answered with an error: \(run.errorMessage)"
        case .unreadableAnswer:
            "Claude's answer didn't have the expected shape. Try again."
        }
    }

    /// the run, when `claude` answered at all
    public var run: ClaudeRun? {
        switch self {
        case .answeredError(let run), .unreadableAnswer(let run): run
        default: nil
        }
    }
}

/// Runs Claude Code headless, `claude -p`, with the developer's own Claude Code login: the app holds no key (AI-01).
///
/// - `claude` is found once: the login shell's `PATH`, then the usual places (``ProgramResolver``, as Open in IDE).
/// - The facts go in through stdin, never on the command line; only the app's fixed instructions and the answer's
///   schema are arguments (``arguments(for:model:effort:)``).
/// - `--safe-mode` leaves out the user's CLAUDE.md, skills, plugins, hooks and MCP servers, and `--tools ""` every tool:
///   the answer comes from the facts alone, nothing runs, and the prompt stays small. `--no-session-persistence` keeps
///   the sessions out of Claude Code's history. `--max-budget-usd` stops a runaway call at a fixed ``maxBudgetUSD``.
/// - With the user's setup (``ClaudeSetup``, AI-09) `--safe-mode` is left out: their skills, plugins, commands and MCP
///   servers load, but `--permission-mode dontAsk` lets only the named tools run, whatever their own settings allow:
///   the reading MCP tools by name, the use case's own `Read,Grep,Glob`; every other MCP tool and Bash, Edit, Write are
///   denied by name too (a denial beats their own allow rules, and a skill's `allowed-tools`). A chat gets the Skill
///   tool, so Claude can load a skill as in Claude Code (``tools(folder:setup:guarded:)``); with a folder only behind
///   the read guard (``ClaudeReadGuard``), which keeps Read, Grep and Glob inside it whatever a skill allows.
/// - The model goes in as the CLI's alias (`--model opus`, ``ClaudeModel``): `claude` picks the newest model of the
///   family it knows, so an old and a new Claude Code both work. An old one that still can't run it answers with
///   "does not support this model"; that is ``ClaudeFailure/outdated(required:)``, never sent again by itself.
/// - It ends `claude` after ``timeout``.
public actor ClaudeEngine {
    /// the fixed safety limit of one call, `--max-budget-usd`: a runaway call stops here. Not a setting, not shown.
    static let maxBudgetUSD = "1.00"
    /// the limit of the coffee break's one line: a few cents at most
    static let maxCoffeeBudgetUSD = "0.05"
    /// the limit of the fun layer's daily batch of lines: a few cents at most
    static let maxFunBudgetUSD = "0.10"
    /// the same limit for a question about code, which reads files and may review a long diff with Opus (AI-07)
    static let maxCodeBudgetUSD = "5.00"
    /// the limits with the user's setup, whose tool list alone is some 200,000 tokens before the cache has it (AI-09)
    static let maxSetupBudgetUSD = "5.00"
    static let maxSetupCodeBudgetUSD = "10.00"
    /// the built-in tools that write or run something, denied with the user's setup whatever their settings allow
    static let deniedBuiltInTools = ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]
    /// the model name of the setup listing: `claude` prints its `init` event first, then finds the model unknown and
    /// stops, so listing the tools calls no model and costs nothing
    static let listingModel = "setup-listing-no-model-call"
    /// how long the listing may take: `claude` starts the user's MCP servers first
    public static let listingTimeout: Duration = .seconds(60)

    /// how long an answer may take; measured answers took 3 to 5 s
    public static let timeout: Duration = .seconds(120)
    /// how long a question about code may take: a long diff, and files to read in the checkout (AI-07)
    public static let codeTimeout: Duration = .seconds(300)
    /// the tools of a question about code with a checkout: reading only, never Bash, Edit or Write (AI-07)
    static let readingTools = "Read,Grep,Glob"
    /// the tool that loads a skill's text when Claude picks one, as `/name` does in Claude Code; only with the user's
    /// setup and no folder to read (``tools(folder:setup:)``). Its name in Claude Code 2.1.317, where `SlashCommand` is
    /// unknown and ignored.
    static let skillTool = "Skill"

    private let runner: any ProcessRunner
    private let resolver: ProgramResolver
    /// the program that runs the read guard's hook, the app's own; `nil` runs a folder's chat without the Skill tool
    let guardProgram: String?
    /// `claude`'s path once looked for: `.some(nil)` when it wasn't found
    private var located: URL??
    /// `claude --version`'s answer once read: `.some(nil)` when it couldn't be read
    private var versionRead: String??

    /// - Parameters:
    ///   - runner: runs `claude` and the login shell
    ///   - resolver: finds `claude`; one of its own by default
    ///   - guardProgram: the program of the read guard's hook (``ClaudeReadGuard``); the app's own by default, none in tests
    public init(runner: any ProcessRunner, resolver: ProgramResolver? = nil, guardProgram: String? = ClaudeReadGuard.appProgram()) {
        self.runner = runner
        self.resolver = resolver ?? ProgramResolver(runner: runner)
        self.guardProgram = guardProgram
    }

    /// Returns `claude`'s full path, looked for once.
    public func locate() async -> URL? {
        if let located {
            return located
        }
        let found = await resolver.resolve("claude")
        located = .some(found)
        return found
    }

    /// Forgets where `claude` was, so the next ``locate()`` looks again, as after installing it.
    public func forgetLocation() {
        located = nil
        versionRead = nil
    }

    /// Returns the version of the `claude` found ("2.1.317"), read once with `claude --version`; `nil` when it isn't
    /// found or says none.
    ///
    /// - Parameter refresh: read it again, as after `claude update`
    public func version(refresh: Bool = false) async -> String? {
        if let versionRead, !refresh {
            return versionRead
        }
        guard let claude = await locate() else {
            return nil
        }
        let output = try? await runner.run(claude, arguments: ["--version"], input: nil, timeout: .seconds(10))
        let version = output.flatMap { Self.version(from: String(decoding: $0.standardOutput, as: UTF8.self)) }
        versionRead = .some(version)
        return version
    }

    /// Returns the version in `claude --version`'s text, "2.1.317 (Claude Code)": its first number with dots.
    static func version(from text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).map(String.init).first {
            $0.first?.isNumber == true && $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." }
        }
    }

    /// Returns `claude`'s arguments for a prompt: fixed flags, the app's instructions and schema, the model and the
    /// effort. The facts are never among them.
    ///
    /// - Parameters:
    ///   - prompt: the prompt
    ///   - model: the model
    ///   - effort: how long Claude thinks; Default adds no flag
    ///   - setup: the user's Claude Code setup to load instead of `--safe-mode`; `nil` runs in safe mode
    ///   - guardProgram: the read guard's program; with a folder and the setup it adds the hook and the Skill tool
    /// - Returns: the arguments
    public static func arguments(
        for prompt: ClaudePrompt, model: ClaudeModel, effort: ClaudeEffort = .standard, setup: ClaudeSetup? = nil,
        guardProgram: String? = nil
    ) -> [String] {
        let folder = readableFolder(of: prompt)
        let guarded = folder != nil && setup != nil && guardProgram != nil
        var arguments = [
            "-p", "--output-format", "json", "--model", model.rawValue, "--tools", tools(folder: folder, setup: setup, guarded: guarded),
        ]
        if let setup {
            arguments += ["--no-session-persistence", "--max-budget-usd", budget(for: prompt, setup: true)]
            // Only what is allowed runs, by the names below and the user's own allow rules; a denial beats every allow rule.
            arguments += ["--permission-mode", "dontAsk"]
            // Read, Grep and Glob are not in the list: a bare `Read` allows every path, while without a rule they may read
            // only the working folders, the checkout (checked: a file outside is denied under `dontAsk`).
            let allowed = (folder == nil || guarded ? [skillTool] : []) + setup.readingTools
            if !allowed.isEmpty {
                arguments += ["--allowedTools", allowed.joined(separator: ",")]
            }
            let denied = deniedBuiltInTools
                + (setup.blocksAllMcp ? ["mcp__*"] : setup.blockedServers.map { "mcp__\($0)__*" } + setup.otherTools)
            arguments += ["--disallowedTools", denied.joined(separator: ",")]
            if let folder {
                // The setup's settings stay on, so no `--restricted`; `dontAsk` keeps Read inside the working folders,
                // and the read guard's hook keeps it there when a skill's `allowed-tools` would let it out.
                arguments += ["--add-dir", folder]
                if guarded, let guardProgram {
                    arguments += ["--settings", ClaudeReadGuard.settings(program: guardProgram)]
                }
            }
        } else {
            arguments += ["--safe-mode", "--no-session-persistence", "--max-budget-usd", budget(for: prompt)]
            if let folder {
                // `--restricted` keeps the file tools inside the working folders: the checkout, which is also the working
                // directory (``command(claude:for:model:effort:setup:)``). The folder is one argument, and a flag follows it.
                arguments += ["--restricted", "--add-dir", folder]
            }
        }
        arguments += ["--system-prompt", prompt.instructions]
        if let level = effort.level {
            arguments += ["--effort", level]
        }
        if let schema = prompt.schema {
            arguments += ["--json-schema", schema]
        }
        return arguments
    }

    /// Returns the built-in tools of a run, `--tools`: none, `Read,Grep,Glob` with a folder to read, and the Skill tool
    /// in a chat with the user's setup, so their skills load as in Claude Code (AI-09).
    ///
    /// A skill's `allowed-tools` grants its tools past `dontAsk` (probed with 2.1.317): only a tool that is missing from
    /// `--tools` or denied by name stays off. Without a folder no file tool exists and Bash, Edit, Write and the changing
    /// MCP tools are denied by name, so a skill can only read through the allowed MCP tools. With a folder a skill's bare
    /// `Read` would read outside the checkout, so there the Skill tool comes only with the read guard's hook.
    ///
    /// - Parameters:
    ///   - folder: the folder the prompt lets Claude read, if any
    ///   - setup: the user's setup, or `nil` for safe mode
    ///   - guarded: whether the read guard's hook runs (``ClaudeReadGuard``)
    /// - Returns: the comma-separated tool names, or an empty text for none
    static func tools(folder: String?, setup: ClaudeSetup?, guarded: Bool = false) -> String {
        if folder != nil {
            return setup != nil && guarded ? readingTools + "," + skillTool : readingTools
        }
        return setup == nil ? "" : skillTool
    }

    // MARK: - A hosted chat (AI-10)

    /// the limit of a hosted chat's whole process, which lives for many turns; a chat that reaches it starts anew
    static let maxHostBudgetUSD = "10.00"

    /// what Claude Code's own system prompt gets added in a chat card; the item's facts come in the first message
    static let hostInstructions = """
        You run inside MegaMonitor, a developer's menu bar app, in the chat card of one item: a merge request, a work \
        item or a build. The developer's first message has the item's facts. The developer reads your text in the card \
        and approves each tool call there, so say briefly what you are about to do. Answer in Markdown, concise and \
        concrete. Don't commit or push unless the developer asks.
        """

    /// Returns the arguments of a chat that Claude Code runs as in a terminal, hosted by the card (AI-10): stream-json
    /// both ways, every permission question to the card (`--permission-prompt-tool stdio`), and
    /// `--permission-mode default` always, since the user's own default mode may let calls run unasked (probed: `auto`
    /// did). No tool is allowed by name: only the user's own allow rules and a skill's `allowed-tools` run a tool
    /// without the card asking. WebFetch and WebSearch stay denied, and so do the MCP servers the user turned off or
    /// the listing doesn't know. The facts never go here: they are the first message, on stdin.
    ///
    /// - Parameters:
    ///   - model: the model
    ///   - effort: how long Claude thinks
    ///   - setup: the user's setup
    /// - Returns: the arguments
    public static func hostArguments(model: ClaudeModel, effort: ClaudeEffort, setup: ClaudeSetup) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default",
            "--model", model.rawValue, "--no-session-persistence", "--max-budget-usd", maxHostBudgetUSD,
        ]
        let denied = ["WebFetch", "WebSearch"] + (setup.blocksAllMcp ? ["mcp__*"] : setup.blockedServers.map { "mcp__\($0)__*" })
        arguments += ["--disallowedTools", denied.joined(separator: ",")]
        arguments += ["--append-system-prompt", hostInstructions]
        if let level = effort.level {
            arguments += ["--effort", level]
        }
        return arguments
    }

    /// Returns the environment a hosted chat adds to the app's own: CLAUDE.md off when the user turned it off.
    public static func hostEnvironment(setup: ClaudeSetup) -> [String: String] {
        setup.useClaudeMd ? [:] : ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"]
    }

    /// Returns the safety limit of a prompt: the higher one for a question about code, else the fixed one.
    static func budget(for prompt: ClaudePrompt, setup: Bool = false) -> String {
        if setup {
            return prompt.useCase == .askAboutCode ? maxSetupCodeBudgetUSD : maxSetupBudgetUSD
        }
        if prompt.useCase == .coffeeBreak {
            return maxCoffeeBudgetUSD
        }
        if prompt.useCase == .funBatch {
            return maxFunBudgetUSD
        }
        return prompt.useCase == .askAboutCode ? maxCodeBudgetUSD : maxBudgetUSD
    }

    /// Returns the folder a prompt lets Claude read: an absolute path, else none (AI-07).
    static func readableFolder(of prompt: ClaudePrompt) -> String? {
        guard let folder = prompt.readableFolder, folder.hasPrefix("/"), !folder.contains("\0") else {
            return nil
        }
        return folder
    }

    /// Returns the program and the arguments that run `claude` for a prompt. A prompt with a folder to read runs in
    /// that folder through `/usr/bin/env -C`, since the app's own working directory is `/`, which `--restricted` would
    /// leave open; a setup without CLAUDE.md runs through `env` too, with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`. A `claude`
    /// path `env` would read as a variable (`NAME=value`) runs without the folder and its tools, and without the setup.
    ///
    /// - Parameters:
    ///   - claude: `claude`'s full path
    ///   - prompt: the prompt
    ///   - model: the model
    ///   - effort: how long Claude thinks
    ///   - setup: the user's Claude Code setup, or `nil` for safe mode
    ///   - guardProgram: the read guard's program; its folder goes to the hook as ``ClaudeReadGuard/folderVariable``
    /// - Returns: the program and its arguments
    public static func command(
        claude: URL, for prompt: ClaudePrompt, model: ClaudeModel, effort: ClaudeEffort = .standard, setup: ClaudeSetup? = nil,
        guardProgram: String? = nil
    ) -> (executable: URL, arguments: [String]) {
        let path = claude.path(percentEncoded: false)
        let folder = readableFolder(of: prompt)
        var variables = setup.map { $0.useClaudeMd ? [] : ["CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"] } ?? []
        if let folder, setup != nil, guardProgram != nil {
            // One argument of `env`'s list: the hook reads it from its environment, never from a shell line.
            variables.append(ClaudeReadGuard.folderVariable + "=" + folder)
        }
        guard folder != nil || !variables.isEmpty else {
            return (claude, arguments(for: prompt, model: model, effort: effort, setup: setup))
        }
        guard !path.contains("=") else {
            var plain = prompt
            plain.readableFolder = nil
            return (claude, arguments(for: plain, model: model, effort: effort))
        }
        // `env`'s own options come before the first variable.
        let options = folder.map { ["-C", $0] } ?? []
        return (
            URL(filePath: "/usr/bin/env"),
            options + variables + [path]
                + arguments(for: prompt, model: model, effort: effort, setup: setup, guardProgram: guardProgram))
    }

    /// Lists what the user's Claude Code setup offers a headless run: the MCP tools of the connected servers. It starts
    /// `claude` with a model that doesn't exist, which prints its `init` event first and then stops: no model is called.
    ///
    /// - Returns: the tools and servers
    /// - Throws: ``ClaudeFailure``
    public func discoverSetup() async throws(ClaudeFailure) -> ClaudeInventory {
        guard let claude = await locate() else {
            throw .notFound
        }
        let output: ProcessOutput
        do {
            output = try await runner.run(
                claude,
                arguments: [
                    "-p", "--output-format", "stream-json", "--verbose", "--model", Self.listingModel, "--tools", "",
                    "--no-session-persistence", "--max-budget-usd", "0.05", "--permission-mode", "dontAsk",
                    "--disallowedTools", Self.deniedBuiltInTools.joined(separator: ","),
                ],
                input: Data("list".utf8), timeout: Self.listingTimeout)
        } catch is ProcessTimedOut {
            throw .timedOut
        } catch {
            throw .couldNotRun(error.localizedDescription)
        }
        guard let inventory = ClaudeInventory.parse(streamJSON: output.standardOutput) else {
            let text = String(decoding: output.standardError + output.standardOutput, as: UTF8.self)
            let lastLine = text.split(whereSeparator: \.isNewline).last.map { String($0.prefix(300)) }
            throw .failed(status: output.status, lastLine: lastLine)
        }
        return inventory
    }

    /// Sends a prompt and returns the answer.
    ///
    /// - Parameters:
    ///   - prompt: the prompt, redacted
    ///   - model: the model
    ///   - effort: how long Claude thinks; Default adds no flag
    ///   - setup: the user's Claude Code setup to load; `nil` runs in safe mode
    /// - Returns: the answer
    /// - Throws: ``ClaudeFailure``
    public func run(
        _ prompt: ClaudePrompt, model: ClaudeModel, effort: ClaudeEffort = .standard, setup: ClaudeSetup? = nil
    ) async throws(ClaudeFailure) -> ClaudeRun {
        guard let claude = await locate() else {
            throw .notFound
        }
        let output: ProcessOutput
        let command = Self.command(
            claude: claude, for: prompt, model: model, effort: effort, setup: setup, guardProgram: guardProgram)
        do {
            output = try await runner.run(
                command.executable, arguments: command.arguments, input: Data(prompt.text.utf8),
                timeout: prompt.useCase == .askAboutCode ? Self.codeTimeout : Self.timeout)
        } catch is ProcessTimedOut {
            throw .timedOut
        } catch {
            throw .couldNotRun(error.localizedDescription)
        }
        // An error answer comes as JSON too, with exit status 1.
        guard var run = try? ClaudeRun.parse(output.standardOutput) else {
            let text = String(decoding: output.standardError + output.standardOutput, as: UTF8.self)
            if ClaudeFailure.saysOutdated(text) {
                throw .outdated(required: ClaudeFailure.requiredVersion(in: text))
            }
            let lastLine = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
                .map { String($0.prefix(300)) }
            throw .failed(status: output.status, lastLine: lastLine)
        }
        run.exitStatus = output.status
        guard !run.isError, output.status == 0 else {
            run.isError = true
            // An old `claude` doesn't know the alias's model: a problem of the installation, said as one.
            if ClaudeFailure.saysOutdated(run.errorMessage) {
                throw .outdated(required: ClaudeFailure.requiredVersion(in: run.errorMessage))
            }
            throw .answeredError(run)
        }
        return run
    }
}

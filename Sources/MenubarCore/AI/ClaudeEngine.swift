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
    /// it answered with an error, like the budget reached or no login; the cost is spent all the same
    case answeredError(ClaudeRun)
    /// the answer didn't have the shape asked for
    case unreadableAnswer(ClaudeRun)

    /// the failure in a sentence
    public var message: String {
        switch self {
        case .notFound:
            "Claude Code (claude) isn't installed. Install it, then sign in with claude in Terminal."
        case .timedOut:
            "Claude didn't answer within \(Int(ClaudeEngine.timeout.components.seconds)) s."
        case .couldNotRun(let reason):
            "Couldn't start claude: \(reason)"
        case .failed(let status, let lastLine):
            lastLine.map { "claude ended with \(status): \($0)" } ?? "claude ended with \(status)"
        case .answeredError(let run):
            "Claude answered with an error: \(run.errorMessage)"
        case .unreadableAnswer:
            "Claude's answer didn't have the expected shape. Try again."
        }
    }

    /// the run, when `claude` answered at all: its cost counts
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
///   schema are arguments (``arguments(for:model:budgetUSD:)``).
/// - `--safe-mode` leaves out the user's CLAUDE.md, skills, plugins, hooks and MCP servers, and `--tools ""` every tool:
///   the answer comes from the facts alone, nothing runs, and the prompt stays small. `--no-session-persistence` keeps
///   the sessions out of Claude Code's history. `--max-budget-usd` caps each answer at what the monthly cap leaves.
/// - It ends `claude` after ``timeout``.
public actor ClaudeEngine {
    /// how long an answer may take; measured answers took 3 to 5 s
    public static let timeout: Duration = .seconds(120)

    private let runner: any ProcessRunner
    private let resolver: ProgramResolver
    /// `claude`'s path once looked for: `.some(nil)` when it wasn't found
    private var located: URL??

    /// - Parameters:
    ///   - runner: runs `claude` and the login shell
    ///   - resolver: finds `claude`; one of its own by default
    public init(runner: any ProcessRunner, resolver: ProgramResolver? = nil) {
        self.runner = runner
        self.resolver = resolver ?? ProgramResolver(runner: runner)
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
    }

    /// Returns `claude`'s arguments for a prompt: fixed flags, the app's instructions and schema, the model and the
    /// budget. The facts are never among them.
    ///
    /// - Parameters:
    ///   - prompt: the prompt
    ///   - model: the model
    ///   - budgetUSD: the most the answer may cost
    /// - Returns: the arguments
    public static func arguments(for prompt: ClaudePrompt, model: ClaudeModel, budgetUSD: Double) -> [String] {
        var arguments = [
            "-p", "--output-format", "json", "--model", model.rawValue, "--tools", "", "--safe-mode",
            "--no-session-persistence", "--max-budget-usd", String(format: "%.2f", max(budgetUSD, AICostCap.smallestBudgetUSD)),
            "--system-prompt", prompt.instructions,
        ]
        if let schema = prompt.schema {
            arguments += ["--json-schema", schema]
        }
        return arguments
    }

    /// Sends a prompt and returns the answer.
    ///
    /// - Parameters:
    ///   - prompt: the prompt, redacted
    ///   - model: the model
    ///   - budgetUSD: the most the answer may cost
    /// - Returns: the answer, with its tokens and cost
    /// - Throws: ``ClaudeFailure``
    public func run(_ prompt: ClaudePrompt, model: ClaudeModel, budgetUSD: Double) async throws(ClaudeFailure) -> ClaudeRun {
        guard let claude = await locate() else {
            throw .notFound
        }
        let output: ProcessOutput
        do {
            output = try await runner.run(
                claude, arguments: Self.arguments(for: prompt, model: model, budgetUSD: budgetUSD),
                input: Data(prompt.text.utf8), timeout: Self.timeout)
        } catch is ProcessTimedOut {
            throw .timedOut
        } catch {
            throw .couldNotRun(error.localizedDescription)
        }
        // An error answer comes as JSON too, with exit status 1.
        guard var run = try? ClaudeRun.parse(output.standardOutput) else {
            let text = String(decoding: output.standardError + output.standardOutput, as: UTF8.self)
            let lastLine = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
                .map { String($0.prefix(300)) }
            throw .failed(status: output.status, lastLine: lastLine)
        }
        run.exitStatus = output.status
        guard !run.isError, output.status == 0 else {
            run.isError = true
            throw .answeredError(run)
        }
        return run
    }
}

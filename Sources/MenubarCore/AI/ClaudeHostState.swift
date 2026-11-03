import Foundation

/// What a run reported, for "Raw Response" under "What Was Sent": the answer's Markdown source and the run's facts.
/// Never its cost (the user's rule: no money in the UI).
public struct ClaudeRawResponse: Hashable, Sendable {
    /// the answer as Claude wrote it, Markdown
    public var markdown: String
    /// the model that answered, as reported
    public var model: String?
    public var durationMS: Int?
    /// the tool calls, one line each: "Bash: git status"
    public var toolCalls: [String]
    /// how the run ended: `success`, `error_during_execution`…, with the stop reason when there is one
    public var outcome: String
    /// `claude`'s exit status, for a one-shot run
    public var exitStatus: Int32?
    /// the last lines `claude` wrote to stderr
    public var stderrTail: String?

    public init(
        markdown: String, model: String? = nil, durationMS: Int? = nil, toolCalls: [String] = [], outcome: String,
        exitStatus: Int32? = nil, stderrTail: String? = nil
    ) {
        self.markdown = markdown
        self.model = model
        self.durationMS = durationMS
        self.toolCalls = toolCalls
        self.outcome = outcome
        self.exitStatus = exitStatus
        self.stderrTail = stderrTail
    }

    /// Returns the raw response of a one-shot run.
    public init(run: ClaudeRun) {
        self.init(
            markdown: run.text ?? "", model: run.model, durationMS: run.durationMS, outcome: run.subtype ?? "unknown",
            exitStatus: run.exitStatus)
    }

    /// the facts as text, for Copy
    public var asText: String {
        var lines: [String] = []
        if let model { lines.append("Model: \(model)") }
        if let durationMS { lines.append("Duration: \(Self.seconds(durationMS))") }
        lines.append("Outcome: \(outcome)")
        if let exitStatus { lines.append("Exit status: \(exitStatus)") }
        if !toolCalls.isEmpty {
            lines.append("Tool calls:")
            lines += toolCalls.map { "  \($0)" }
        }
        if let stderrTail, !stderrTail.isEmpty {
            lines += ["stderr:", stderrTail]
        }
        lines += ["", markdown]
        return lines.joined(separator: "\n")
    }

    /// "3.4 s"
    public static func seconds(_ milliseconds: Int) -> String {
        (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }
}

/// One tool call of a turn, as a quiet line in the card.
public struct ClaudeHostStep: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case running
        case done
        case failed
    }

    /// the tool use's id
    public var id: String
    public var toolName: String
    public var summary: String
    public var status: Status

    public init(id: String, toolName: String, summary: String, status: Status = .running) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.status = status
    }

    /// the line of the raw response
    var rawLine: String {
        let mark = status == .failed ? " (failed)" : ""
        return summary.isEmpty ? toolName + mark : "\(toolName): \(summary)\(mark)"
    }
}

/// A turn of a hosted chat while it runs (AI-10): the text so far, the tool calls, and what waits for the developer.
public struct ClaudeHostTurn: Hashable, Sendable {
    /// the text blocks that are complete
    public var committed: String = ""
    /// the text block being streamed
    public var streaming: String = ""
    public var steps: [ClaudeHostStep] = []
    /// the tool calls and questions waiting for an answer, the oldest first
    public var pending: [ClaudeHostRequest] = []
    /// how it ended, once it did
    public var result: ClaudeHostResult?

    public init() {}

    /// the text to show: the complete blocks and the one being streamed
    public var text: String {
        [committed, streaming].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Applies one event of Claude Code's output.
    public mutating func apply(_ event: ClaudeHostEvent) {
        switch event {
        case .textStarted:
            streaming = ""
        case .textDelta(let text):
            streaming += text
        case .text(let text):
            let block = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                committed = committed.isEmpty ? block : committed + "\n\n" + block
            }
            streaming = ""
        case .toolUse(let id, let name, let input):
            guard !steps.contains(where: { $0.id == id }) else { return }
            steps.append(ClaudeHostStep(id: id, toolName: name, summary: ClaudeHostTool.summary(name: name, input: input)))
        case .toolResult(let id, let isError):
            if let index = steps.firstIndex(where: { $0.id == id }) {
                steps[index].status = isError ? .failed : .done
            }
        case .request(let request):
            pending.removeAll { $0.requestID == request.requestID }
            pending.append(request)
        case .cancelled(let id):
            pending.removeAll { $0.requestID == id }
        case .finished(let result):
            self.result = result
            pending = []
            for index in steps.indices where steps[index].status == .running {
                steps[index].status = result.isError ? .failed : .done
            }
        case .initialized, .started, .unsupported:
            break
        }
    }

    /// Takes a request off once the developer answered it.
    public mutating func answered(_ requestID: String) {
        pending.removeAll { $0.requestID == requestID }
    }

    /// the answer's Markdown: the final text Claude Code reports, else every text block of the turn
    public var answer: String {
        let final = result?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return final.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : final
    }

    /// Returns the turn as a run, the shape the chats already keep: the answer, the model, the error.
    ///
    /// - Parameter fallbackModel: the model asked for, when Claude Code reported none
    public func run(fallbackModel: String?) -> ClaudeRun {
        let result = result ?? ClaudeHostResult(subtype: "unknown", isError: true)
        let text = answer
        return ClaudeRun(
            text: text.isEmpty ? nil : text, usage: result.usage, durationMS: result.durationMS,
            model: result.model ?? fallbackModel, isError: result.isError, subtype: result.subtype, errors: result.errors)
    }

    /// Returns the raw response of the turn.
    ///
    /// - Parameters:
    ///   - model: the model Claude Code reported at the start
    ///   - stderrTail: the last lines of stderr
    public func raw(model: String?, stderrTail: String?) -> ClaudeRawResponse {
        let reason = [result?.subtype, result?.terminalReason ?? result?.stopReason].compactMap { $0 }
        return ClaudeRawResponse(
            markdown: answer, model: result?.model ?? model, durationMS: result?.durationMS, toolCalls: steps.map(\.rawLine),
            outcome: reason.isEmpty ? "unknown" : reason.joined(separator: ", "), stderrTail: stderrTail)
    }
}

/// A chat hosted in a card (AI-10): Claude Code's commands for the "/" list and the turn in progress. The process lives
/// in ``AIStore``; this is what the views read.
public struct ClaudeHostChat: Hashable, Sendable {
    /// the commands and skills `initialize` reported; empty until it answered
    public var commands: [SlashCommand] = []
    /// the turn in progress, or the last one
    public var turn: ClaudeHostTurn?

    public init(commands: [SlashCommand] = [], turn: ClaudeHostTurn? = nil) {
        self.commands = commands
        self.turn = turn
    }
}

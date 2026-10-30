import Foundation

// MARK: - The thread

/// One question of a conversation with Claude and where its answer stands (AI-08).
public struct ConversationTurn: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Claude is answering
        case thinking
        /// the answer in Markdown, the model that gave it
        case answered(String, model: String, at: Date)
        /// why there is no answer
        case failed(String)
    }

    public var id: UUID
    public var question: String
    public var askedAt: Date
    public var status: Status
    /// what the question is about in a merge request's code chat (AI-07); `nil` elsewhere
    public var scope: CodeScope?

    public init(
        id: UUID = UUID(), question: String, askedAt: Date, status: Status = .thinking, scope: CodeScope? = nil
    ) {
        self.id = id
        self.question = question
        self.askedAt = askedAt
        self.status = status
        self.scope = scope
    }

    /// the answer's text, once there is one
    public var answer: String? {
        if case .answered(let text, _, _) = status { text } else { nil }
    }

    /// the model that answered, as reported, once there is an answer
    public var model: String? {
        if case .answered(_, let model, _) = status { model } else { nil }
    }

    /// the model's name for the turn, "Opus 5.5", or the name as reported when it is none of the app's
    public var modelName: String? {
        model.map { ClaudeModel(rawValue: $0)?.shortName ?? $0 }
    }
}

/// The follow-up questions and answers below a Claude answer, in the order they were asked (AI-08). Kept in memory per
/// subject; the first answer itself stays what it was (a card, or Markdown) and is not a turn.
public struct Conversation: Hashable, Sendable {
    public var turns: [ConversationTurn]

    /// how many subjects' conversations are kept while the app runs; the oldest idle one goes first
    public static let kept = 12

    public init(turns: [ConversationTurn] = []) {
        self.turns = turns
    }

    /// whether Claude is answering a turn
    public var isThinking: Bool {
        turns.contains { $0.status == .thinking }
    }
}

// MARK: - The first answer as text

extension AIAnswer {
    /// the most of the first answer that goes back to Claude with a follow-up, in characters
    public static let openingCharacters = 12_000

    /// Returns the answer as plain text, for what Claude is told of its own first answer and for Claude Code: the
    /// investigation's verdict, cause, evidence, suspects and next step; the summary's open and agreed points; or the
    /// Markdown as it was.
    public var asText: String {
        if let explanation {
            var lines = ["Verdict: \(explanation.verdict.title)"]
            if !explanation.headline.isEmpty { lines.append("Headline: \(explanation.headline)") }
            if !explanation.failedAt.isEmpty { lines.append("Failed at: \(explanation.failedAt)") }
            if !explanation.cause.isEmpty { lines.append("Root cause: \(explanation.cause)") }
            if !explanation.evidence.isEmpty {
                lines.append("Evidence:")
                lines += explanation.evidence.map { "  \($0)" }
            }
            if !explanation.suspects.isEmpty {
                lines.append("Suspect commits:")
                for suspect in explanation.suspects {
                    let by = [suspect.author, suspect.why].filter { !$0.isEmpty }.joined(separator: ": ")
                    lines.append("- \(String(suspect.commit.prefix(10))) \(suspect.message) (\(by))")
                }
            }
            if !explanation.nextStep.isEmpty { lines.append("Next step: \(explanation.nextStep)") }
            return lines.joined(separator: "\n")
        }
        if let summary {
            var lines: [String] = []
            if !summary.open.isEmpty {
                lines.append("Open:")
                lines += summary.open.map { "- \($0.point) (waiting on \($0.waitingOn))" }
            }
            if !summary.agreed.isEmpty {
                lines.append("Agreed:")
                lines += summary.agreed.map { "- \($0)" }
            }
            return lines.isEmpty ? "Nothing to summarize." : lines.joined(separator: "\n")
        }
        return text ?? ""
    }
}

// MARK: - What a follow-up sends

extension AIUseCase {
    /// what the app asked for the first answer, as the conversation's first line
    fileprivate var openingRequest: String {
        switch self {
        case .explainBuild: "The developer asked why the build failed."
        case .summarizeThreads: "The developer asked for a summary of the review discussion."
        case .digest: "The developer asked for their daily digest."
        case .askAboutCode: "The developer's first question is at the end of the facts above."
        case .openInClaudeCode: "The developer asked for help with this item."
        case .askAboutItem: "The developer's first question is at the end of the facts above."
        }
    }
}

extension ClaudePrompt {
    /// the most turns a follow-up sends back; older ones are left out, with a note
    public static let followUpTurns = 10
    /// the most characters of earlier questions and answers a follow-up sends back
    public static let followUpCharacters = 60_000
    /// the most of one earlier answer that is sent back
    static let followUpAnswerCharacters = 20_000

    /// the system prompt of a follow-up to an answer that was structured (JSON): plain Markdown now
    static let followUpInstructions = """
        You are Claude, talking with a developer inside their developer tool. The input has the facts first (a failed \
        build, a merge request's discussion or code, work items), then the conversation so far, then the developer's \
        new question. Answer only that new question, from the facts and the conversation, and say plainly when they \
        don't tell enough to be sure. You can't run commands, open links or change anything. Answer in Markdown, \
        concise and concrete: lead with the answer, and use short lists and code blocks only where they help. Don't \
        repeat what you already said, and don't answer in JSON.
        """

    /// what is added to the instructions of a first answer that was already text
    static let followUpNote = """

        This turn is a follow-up in a conversation. The input has the facts first, then the conversation so far, then \
        the developer's new question. Answer only that new question, in Markdown, instead of doing the first task again.
        """

    /// Returns what a follow-up sends: the facts exactly as the first answer got them, once; then the conversation so
    /// far, Claude's first answer and the answered turns in order, delimited; then the new question. The first answer
    /// keeps its tools and its limits (the same use case and readable folder); a first answer that was JSON gets
    /// plain-Markdown instructions and no schema. The conversation is capped: at most ``followUpTurns`` turns and
    /// ``followUpCharacters`` characters of them, the oldest dropped with a note in the text.
    ///
    /// - Parameters:
    ///   - answer: the first answer, with the prompt it was given
    ///   - history: the turns asked since, the last one the newest; only the answered ones are sent
    ///   - question: the new question
    ///   - context: more facts for the new question alone, like the diff of another scope in a code chat; they go
    ///     right before the question
    /// - Returns: the prompt, not redacted yet
    public static func followUp(
        to answer: AIAnswer, history: [ConversationTurn], question: String, context: String? = nil
    ) -> ClaudePrompt {
        let first = answer.prompt
        var lines = [first.text, "", "# The conversation so far", ""]
        lines.append(first.useCase.openingRequest)
        lines.append("")
        lines.append("## Claude's first answer")
        lines.append(head(answer.asText, characters: AIAnswer.openingCharacters))

        // The newest turns that fit, oldest first.
        let answered: [(question: String, answer: String)] = history.compactMap { turn in
            let about = turn.scope.flatMap { $0 == .mergeRequest ? nil : " (about \($0.title))" } ?? ""
            return turn.answer.map { (turn.question + about, head($0, characters: followUpAnswerCharacters)) }
        }
        var kept: [(question: String, answer: String)] = []
        var size = 0
        for turn in answered.reversed() {
            let cost = turn.question.count + turn.answer.count
            if kept.count >= followUpTurns || (!kept.isEmpty && size + cost > followUpCharacters) {
                break
            }
            kept.insert(turn, at: 0)
            size += cost
        }
        let dropped = answered.count - kept.count
        if dropped > 0 {
            lines.append("")
            lines.append(
                "(\(dropped) earlier question\(dropped == 1 ? "" : "s") and \(dropped == 1 ? "its answer" : "their answers") "
                    + "left out to keep this short.)")
        }
        for (index, turn) in kept.enumerated() {
            let number = dropped + index + 1
            lines += ["", "## Developer's question \(number)", turn.question, "", "## Claude's answer \(number)", turn.answer]
        }
        if let context, !context.isEmpty {
            lines += ["", "# More code for the new question", context]
        }
        lines += ["", "# The developer's new question", question]

        var prompt = ClaudePrompt(
            useCase: first.useCase,
            instructions: first.schema == nil ? first.instructions + followUpNote : followUpInstructions,
            text: lines.joined(separator: "\n"), readableFolder: first.readableFolder)
        prompt.schema = nil
        prompt.question = question
        return prompt
    }

    /// the most of the facts handed on to Claude Code, in characters
    static let continuationFactCharacters = 30_000

    /// Returns Claude Code's first prompt to go on with a conversation: Claude's first answer, every answered turn, and
    /// the facts that were sent, cut to ``continuationFactCharacters``.
    ///
    /// - Parameters:
    ///   - answer: the first answer, with the prompt it was given
    ///   - turns: the turns of the conversation
    /// - Returns: the text, which ``ClaudeCodeContext/conversation(_:text:)`` starts with
    public static func continuation(of answer: AIAnswer, turns: [ConversationTurn]) -> String {
        var lines = ["Here is a conversation I had with Claude in MegaMonitor, then the facts it was given.", ""]
        lines += ["## Claude's first answer", answer.asText]
        for (index, turn) in turns.enumerated() {
            guard let reply = turn.answer else { continue }
            lines += ["", "## My question \(index + 1)", turn.question, "", "## Claude's answer \(index + 1)", reply]
        }
        lines += ["", "## The facts it was given", head(answer.prompt.text, characters: continuationFactCharacters)]
        lines += ["", "Let's go on from here: look at the code in this checkout where it helps. Don't commit or push."]
        return lines.joined(separator: "\n")
    }
}

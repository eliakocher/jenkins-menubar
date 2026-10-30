import Foundation
import Testing

@testable import MenubarCore

/// AI-08: asking Claude follow-ups. Every input is made up; `claude` is a fake and nothing real is called.
@Suite("Claude conversation")
struct ConversationTests {
    // MARK: - What a follow-up sends

    @Test("AI-08 a follow-up sends the facts once, then the turns in order, then the new question, redacted")
    func stdin() {
        let answer = Self.answer
        let history = [
            ConversationTurn(question: "Is it flaky?", askedAt: Self.date, status: .answered("Probably, token tok-1234567890 leaked", model: "m", at: Self.date)),
            ConversationTurn(question: "Which commit?", askedAt: Self.date, status: .answered("The discount one.", model: "m", at: Self.date)),
            // A turn that failed or is still being answered is not part of the conversation Claude sees.
            ConversationTurn(question: "Failed one", askedAt: Self.date, status: .failed("no")),
            ConversationTurn(question: "Pending one", askedAt: Self.date),
        ]
        let prompt = ClaudePrompt.followUp(to: answer, history: history, question: "Show me the line, tok-1234567890?")
            .redacted(by: SecretRedactor(knownSecrets: ["tok-1234567890"]))
        let text = prompt.text

        // The facts exactly as sent the first time, once, at the start.
        #expect(text.hasPrefix(answer.prompt.text))
        #expect(text.components(separatedBy: answer.prompt.text).count == 2)
        // The first answer as text, then the answered turns in order, then the new question last.
        let order = ["Claude's first answer", "Root cause: ", "Developer's question 1", "Is it flaky?", "Claude's answer 1",
            "Developer's question 2", "Which commit?", "Claude's answer 2", "The developer's new question", "Show me the line"]
        var at = text.startIndex
        for marker in order {
            guard let found = text.range(of: marker, range: at..<text.endIndex) else {
                Issue.record("\(marker) is missing or out of order")
                return
            }
            at = found.upperBound
        }
        #expect(!text.contains("Failed one") && !text.contains("Pending one"))
        // No token anywhere, and no earlier-turns note when nothing was left out.
        #expect(!text.contains("tok-1234567890"))
        #expect(!text.contains("left out"))
        // A structured first answer asks for plain Markdown now.
        #expect(prompt.schema == nil)
        #expect(prompt.instructions == ClaudePrompt.followUpInstructions)
    }

    @Test("AI-08 the resent conversation is capped at ten turns, the oldest dropped with a note", arguments: [
        (14, 4, "4 earlier questions and their answers left out"),
        (11, 1, "1 earlier question and its answer left out"),
        (10, 0, ""),
    ])
    func cap(count: Int, dropped: Int, note: String) {
        let history = (1...count).map {
            ConversationTurn(question: "Q\($0)", askedAt: Self.date, status: .answered("A\($0)", model: "m", at: Self.date))
        }
        let text = ClaudePrompt.followUp(to: Self.answer, history: history, question: "next").text
        #expect(text.components(separatedBy: "## Developer's question ").count - 1 == 10)
        #expect(text.contains("Developer's question \(dropped + 1)\nQ\(dropped + 1)\n"))
        #expect(text.contains("Developer's question \(count)\nQ\(count)\n"))
        #expect(dropped == 0 || !text.contains("\nQ\(dropped)\n"))
        #expect(note.isEmpty ? !text.contains("left out") : text.contains(note))
    }

    @Test("AI-08 a long conversation is cut by characters too, keeping the newest turns")
    func characterCap() {
        let big = String(repeating: "x", count: 19_000)
        let history = (1...6).map {
            ConversationTurn(question: "Q\($0)", askedAt: Self.date, status: .answered(big + "\($0)", model: "m", at: Self.date))
        }
        let text = ClaudePrompt.followUp(to: Self.answer, history: history, question: "next").text
        // 60,000 characters hold three of these; the first three are left out.
        #expect(text.contains("3 earlier questions and their answers left out"))
        #expect(text.contains("Q6") && !text.contains("Q3\n"))
        #expect(text.count < Self.answer.prompt.text.count + 70_000)
    }

    @Test("AI-08 each turn runs claude with the same tools, limits and effort as the first answer, and its own model")
    func argv() {
        // A JSON first answer: no schema now, no tool, the model of the turn.
        let explain = ClaudePrompt.followUp(to: Self.answer, history: [], question: "Why?")
        let plain = ClaudeEngine.arguments(for: explain, model: .haiku, effort: .high)
        #expect(Array(plain.prefix(11)) == [
            "-p", "--output-format", "json", "--model", "claude-haiku-5-5", "--tools", "", "--safe-mode",
            "--no-session-persistence", "--max-budget-usd", "1.00",
        ])
        #expect(plain.contains("--effort") && plain.contains("high"))
        #expect(!plain.contains("--json-schema"))
        #expect(Self.answer.prompt.schema != nil)
        #expect(plain.contains(explain.instructions))

        // A question about code with a checkout keeps reading it, with the higher limit.
        var first = ClaudePrompt(useCase: .askAboutCode, instructions: "Answer in Markdown.", text: "facts")
        first.readableFolder = "/Users/nobody/checkout"
        let code = AIAnswer(text: "It does.", model: "claude-opus-5-5", prompt: first, answeredAt: Self.date)
        let follow = ClaudePrompt.followUp(to: code, history: [], question: "And callers?")
        let reading = ClaudeEngine.arguments(for: follow, model: .sonnet)
        #expect(reading.starts(with: ["-p", "--output-format", "json", "--model", "claude-sonnet-5-5", "--tools", "Read,Grep,Glob"]))
        #expect(reading.contains("5.00") && reading.contains("--restricted"))
        #expect(reading.contains("--add-dir") && reading.contains("/Users/nobody/checkout"))
        #expect(follow.instructions.hasPrefix("Answer in Markdown."))
        #expect(follow.instructions.contains("follow-up"))
        // The facts and the conversation never reach the command line.
        #expect(!reading.contains { $0.contains("And callers?") || $0 == "facts" })
    }

    // MARK: - The conversation's state

    @Test("AI-08 follow-ups join the thread in order, each with its own model; a failure stays a failure; Clear resets")
    @MainActor
    func thread() async throws {
        let fake = ScriptedClaude([.text("First digest."), .text("**Second** answer."), .failure, .text("Third answer.")])
        let store = Self.store(fake)
        await store.writeDigest()
        guard case .answered = store.state(of: .digest) else {
            Issue.record("expected the digest")
            return
        }

        await store.followUp(.digest, question: "  What first?  ", model: .haiku)
        await store.followUp(.digest, question: "And then?")
        await store.followUp(.digest, question: "Anything else?")
        var turns = store.turns(of: .digest)
        #expect(turns.map(\.question) == ["What first?", "And then?", "Anything else?"])
        #expect(turns[0].answer == "**Second** answer.")
        // The model of the turn, as asked: the click's, else Settings'.
        #expect(turns[0].model == "claude-haiku-5-5")
        #expect(turns[1].status == .failed(ClaudeFailure.failed(status: 1, lastLine: "boom").message))

        // The calls: the digest, then one per turn, each model at its own turn; the history only has answered turns.
        let calls = await fake.calls
        #expect(calls.count == 4)
        #expect(calls[1].arguments.contains("claude-haiku-5-5"))
        #expect(calls[2].arguments.contains("claude-opus-5-5"))
        #expect(calls[1].input?.contains("What first?") == true)
        #expect(calls[3].input?.contains("**Second** answer.") == true)
        #expect(calls[3].input?.contains("And then?") == false)

        // A failed turn can be asked again: it goes and its question comes back at the end.
        await store.retry(turns[1], of: .digest)
        turns = store.turns(of: .digest)
        #expect(turns.map(\.question) == ["What first?", "Anything else?", "And then?"])
        #expect(turns.last?.answer == "Third answer.")

        // Clear resets the thread; a follow-up needs an answer.
        store.dismiss(.digest)
        #expect(store.turns(of: .digest).isEmpty)
        await store.followUp(.digest, question: "Still there?")
        #expect(store.turns(of: .digest).isEmpty)
    }

    @Test("AI-08 Stop ends the answer in progress, drops the turn and gives its question back; Claude off asks nothing")
    @MainActor
    func stop() async throws {
        let fake = ScriptedClaude([.text("First digest."), .hang])
        let store = Self.store(fake)
        await store.writeDigest()

        let asking = Task { await store.followUp(.digest, question: "Slow one?") }
        var yields = 0
        while !(store.conversations[.digest]?.isThinking ?? false), yields < 1000 {
            await Task.yield()
            yields += 1
        }
        #expect(store.turns(of: .digest).count == 1)
        // A second question while one is being answered does nothing.
        await store.followUp(.digest, question: "Pushy?")
        #expect(store.turns(of: .digest).count == 1)

        #expect(store.stopFollowUp(of: .digest) == "Slow one?")
        await asking.value
        #expect(store.turns(of: .digest).isEmpty)
        #expect(store.stopFollowUp(of: .digest) == nil)

        // With Claude off nothing is asked.
        store.update(AISettings(isEnabled: false))
        let before = await fake.calls.count
        await store.followUp(.digest, question: "Hello?")
        #expect(store.turns(of: .digest).isEmpty)
        #expect(await fake.calls.count == before)
    }

    @Test("AI-08 cancelling the task that waits for a tool ends the tool, before and while it runs")
    func cancelEndsTheTool() async throws {
        let runner = SystemProcessRunner()
        let started = Date()
        let running = Task {
            try await runner.run(URL(filePath: "/bin/sleep"), arguments: ["30"], input: nil, timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(300))
        running.cancel()
        let output = try await running.value
        #expect(output.status != 0)
        #expect(Date().timeIntervalSince(started) < 10)

        // Cancelled before it starts: it ends at once too.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(URL(filePath: "/bin/sleep"), arguments: ["30"], input: nil, timeout: .seconds(60))
        }
        let ended = try await early.value
        #expect(ended.status != 0)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("AI-08 Continue in Claude Code gets the whole conversation, and never starts with a dash")
    func continuation() {
        let history = [
            ConversationTurn(question: "Is it flaky?", askedAt: Self.date, status: .answered("Probably.", model: "m", at: Self.date)),
        ]
        let text = ClaudePrompt.continuation(of: Self.answer, turns: history)
        #expect(text.contains("Root cause: "))
        #expect(text.contains("Is it flaky?") && text.contains("Probably."))
        #expect(text.contains(Self.answer.prompt.text))
        let context = ClaudeCodeContext.conversation(.workItem(Self.item), text: text)
        let checkout = Checkout(path: "/Users/nobody/main-repo", name: "main-repo", baseBranch: "develop", folder: UUID())
        let prompt = context.prompt(in: checkout)
        #expect(prompt.hasPrefix("Context from MegaMonitor"))
        #expect(prompt.contains("- Work item: group/project#12"))
        #expect(prompt.contains("Is it flaky?"))
        // The item's own first task is replaced by the conversation.
        #expect(!prompt.contains("propose a plan"))
    }

    @Test("AI-08 a question about a work item sends its facts and the question, then can be followed up; Clear forgets both")
    @MainActor
    func workItem() async {
        let fake = ScriptedClaude([.text("It blocks the release."), .text("Because of the label.")])
        let store = Self.store(fake)
        var item = Self.item
        item.labels = [Label(title: "slot::2026.45")]
        let subject = AISubject.workItem(item.reference)

        await store.ask("Why does it matter?", about: item, description: "Cart totals are wrong.")
        // The first question of this use case shows what it sends and waits.
        guard case .review(let prompt) = store.state(of: subject) else {
            Issue.record("expected the review, got \(store.state(of: subject))")
            return
        }
        #expect(prompt.useCase == .askAboutItem)
        #expect(prompt.text.contains("group/project#12") && prompt.text.contains("slot::2026.45"))
        #expect(prompt.text.contains("Cart totals are wrong.") && prompt.text.hasSuffix("Why does it matter?"))
        #expect(await fake.calls.isEmpty)
        await store.send(subject)
        #expect(store.openingQuestions[subject] == "Why does it matter?")

        await store.followUp(subject, question: "Which label?")
        #expect(store.turns(of: subject).first?.answer == "Because of the label.")
        let call = await fake.calls.last
        #expect(call?.input?.hasPrefix(prompt.text) == true)

        store.dismiss(subject)
        #expect(store.state(of: subject) == .idle)
        #expect(store.turns(of: subject).isEmpty && store.openingQuestions[subject] == nil)
    }

    // MARK: - Made-up values

    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static let item = WorkItem(
        reference: "group/project#12", title: "Fix the cart", webURL: URL(string: "https://example.com/group/project/-/issues/12")!,
        updatedAt: date)

    /// the first answer of a failed build: a card, with the facts it was given
    static var answer: AIAnswer {
        AIAnswer(
            explanation: BuildExplanation(
                headline: "Discount applied twice", verdict: .real, failedAt: "Unit tests", cause: "The discount is applied after tax.",
                evidence: ["[ERROR] CartServiceTest.appliesDiscount:42 expected:<90> but was:<100>"],
                suspects: [BuildExplanation.Suspect(commit: "1a2b3c4d5e6f", author: "Jane Doe", message: "Apply discount after tax", why: "touches the total")],
                nextStep: "Apply the discount before tax."),
            model: "claude-opus-5-5", prompt: AITests.prompt, answeredAt: date)
    }

    @MainActor
    static func store(_ fake: ScriptedClaude) -> AIStore {
        let store = AIStore(
            defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest]))
        store.digestFacts = { AITests.someFacts }
        return store
    }
}

/// A `claude` that answers its runs from a script, one behavior per run (the last one again after that), and a login
/// shell that knows no `PATH`.
actor ScriptedClaude: ProcessRunner {
    enum Behavior: Sendable {
        case text(String)
        /// an error answer, exit status 1
        case failure
        /// never answers until the task is cancelled
        case hang
    }

    struct Call: Sendable {
        var arguments: [String]
        var input: String?
    }

    private let script: [Behavior]
    private(set) var calls: [Call] = []

    init(_ script: [Behavior]) {
        self.script = script
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        let behavior = script[min(calls.count, script.count - 1)]
        calls.append(Call(arguments: arguments, input: input.map { String(decoding: $0, as: UTF8.self) }))
        switch behavior {
        case .text(let text):
            let object: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false, "result": text,
                "usage": ["input_tokens": 10, "output_tokens": 5],
            ]
            return ProcessOutput(status: 0, standardOutput: try JSONSerialization.data(withJSONObject: object))
        case .failure:
            return ProcessOutput(status: 1, standardError: Data("boom".utf8))
        case .hang:
            try await Task.sleep(for: .seconds(600))
            return ProcessOutput(status: 0)
        }
    }

    /// A resolver that finds `claude` in `/opt/homebrew/bin`.
    nonisolated func resolver() -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { $0 == "/opt/homebrew/bin/claude" }
    }
}

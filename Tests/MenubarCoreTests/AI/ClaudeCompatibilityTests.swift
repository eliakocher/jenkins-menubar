import Foundation
import Testing

@testable import MenubarCore

/// AI-01: the app works with any recent Claude Code. The models go in as the CLI's aliases, the version is read once,
/// and an outdated `claude` is a problem with its fix, never a loop. Every `claude` here is a fake.
@Suite("Claude compatibility")
struct ClaudeCompatibilityTests {
    private static let outdatedText =
        "API Error: 400 Claude Code 2.1.236 does not support this model; version 2.1.280 or newer is required. "
        + "Run 'claude update', or update the Claude desktop app, then try again."

    @Test("AI-01 the models go to claude as the CLI's aliases, never as pinned ids", arguments: ClaudeModel.allCases)
    func aliases(model: ClaudeModel) throws {
        let arguments = ClaudeEngine.arguments(for: AITests.prompt, model: model)
        let value = try #require(arguments.drop { $0 != "--model" }.dropFirst().first)
        #expect(value == model.rawValue)
        #expect(["opus", "sonnet", "haiku"].contains(value))
    }

    @Test(
        "AI-01 settings saved with a pinned model id still decode, to the alias of their family",
        arguments: [
            ("claude-opus-5-5", ClaudeModel.opus), ("claude-sonnet-5-5", .sonnet), ("claude-haiku-5-5", .haiku),
            ("claude-opus-4-1-20250805", .opus), ("claude-sonnet-9-0[1m]", .sonnet), ("opus", .opus), ("Haiku", .haiku),
        ])
    func oldValuesDecode(stored: String, expected: ClaudeModel) throws {
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(#"{"isEnabled":true,"model":"\#(stored)"}"#.utf8))
        #expect(settings.model == expected)
        // Saved again, it holds the alias.
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(written.contains(#""model":"\#(expected.rawValue)""#))
    }

    @Test(
        "AI-01 the model that answered is named from the id claude reports",
        arguments: [
            ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5-20260101", "Sonnet 5.5"), ("claude-haiku-6", "Haiku 6"),
            ("claude-opus-5-5[1m]", "Opus 5.5"), ("opus", "Opus"), ("some-other-model", "some-other-model"),
        ])
    func answeredName(id: String, expected: String) {
        #expect(ClaudeModel.displayName(ofModel: id) == expected)
    }

    @Test(
        "AI-01 the outdated-claude answer is told from other errors, and names the version it needs",
        arguments: [
            (Self.outdatedText, true, "2.1.280"),
            ("Claude Code 2.1.236 does not support this model", true, nil),
            ("version 3.0.1 or newer is required", true, "3.0.1"),
            ("API Error: 401 Invalid authentication credentials", false, nil),
            ("Claude stopped before it finished. Ask again.", false, nil),
        ])
    func recognizesOutdated(text: String, outdated: Bool, required: String?) {
        #expect(ClaudeFailure.saysOutdated(text) == outdated)
        #expect(ClaudeFailure.requiredVersion(in: text) == required)
    }

    @Test("AI-01 an answer saying claude is too old becomes the update problem, from the JSON answer or from plain output")
    func engineMapsOutdated() async throws {
        let json = Self.errorAnswer(Self.outdatedText)
        for output in [
            ProcessOutput(status: 1, standardOutput: json),
            ProcessOutput(status: 1, standardError: Data(Self.outdatedText.utf8)),
        ] {
            let fake = ScriptedRunner([output])
            let engine = ClaudeEngine(runner: fake, resolver: fake.resolver())
            await #expect(throws: ClaudeFailure.outdated(required: "2.1.280")) {
                try await engine.run(AITests.prompt, model: .opus)
            }
        }
        #expect(ClaudeFailure.outdated(required: nil).message == "Claude Code is too old for this model. Update it: claude update")
        // Any other error stays an error answer.
        let other = ScriptedRunner([ProcessOutput(status: 1, standardOutput: Self.errorAnswer("API Error: 401 no login"))])
        let engine = ClaudeEngine(runner: other, resolver: other.resolver())
        do {
            _ = try await engine.run(AITests.prompt, model: .opus)
            Issue.record("expected an error answer")
        } catch {
            if case .answeredError = error {} else { Issue.record("expected an error answer, got \(error)") }
        }
    }

    @Test("AI-01 reads claude's version once; the store keeps it and notes an outdated claude until a run works, without asking again by itself")
    @MainActor
    func versionAndOutdatedNote() async throws {
        let answer = try FixtureFiles.data("Claude/digest.json")
        let fake = ScriptedRunner([
            ProcessOutput(status: 0, standardOutput: Data("2.1.317 (Claude Code)\n".utf8)),
            ProcessOutput(status: 1, standardOutput: Self.errorAnswer(Self.outdatedText)),
            ProcessOutput(status: 0, standardOutput: Data("2.1.320 (Claude Code)\n".utf8)),
            ProcessOutput(status: 0, standardOutput: answer),
        ])
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver())
        store.digestFacts = { AITests.someFacts }
        store.update(AISettings(isEnabled: true, confirmedUseCases: [.digest]))
        await store.detect()
        await store.detect()
        #expect(store.claudeVersion == "2.1.317")
        #expect(await fake.calls.map(\.arguments) == [["--version"]])

        await store.writeDigest()
        guard case .failed(let message, _) = store.state(of: .digest) else {
            Issue.record("expected the update problem")
            return
        }
        #expect(message == ClaudeFailure.outdatedMessage)
        #expect(store.outdatedClaude == OutdatedClaude(required: "2.1.280"))
        // One call, no retry by itself.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.calls.count == 2)

        // After `claude update` the next ask reads the version again, and an answer clears the note.
        await store.writeDigest()
        #expect(store.outdatedClaude == nil)
        #expect(store.claudeVersion == "2.1.320")
        if case .answered = store.state(of: .digest) {} else { Issue.record("expected the digest") }
    }

    @Test("AI-01 claude --version's text gives the number", arguments: [
        ("2.1.317 (Claude Code)\n", "2.1.317"), ("claude 2.2.0", "2.2.0"), ("", nil), ("command not found", nil),
    ])
    func versionText(text: String, expected: String?) {
        #expect(ClaudeEngine.version(from: text) == expected)
    }

    private static func errorAnswer(_ text: String) -> Data {
        let object: [String: Any] = ["type": "result", "subtype": "success", "is_error": true, "result": text]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// A `claude` that answers one scripted output per call, and the last one again after that.
private actor ScriptedRunner: ProcessRunner {
    struct Call: Sendable {
        var arguments: [String]
    }

    private var outputs: [ProcessOutput]
    private(set) var calls: [Call] = []

    init(_ outputs: [ProcessOutput]) {
        self.outputs = outputs
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        calls.append(Call(arguments: arguments))
        return outputs.count > 1 ? outputs.removeFirst() : (outputs.first ?? ProcessOutput(status: 1))
    }

    nonisolated func resolver() -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { $0 == "/opt/homebrew/bin/claude" }
    }
}

import Foundation
import Testing

@testable import MenubarCore

/// FUN-06: Haiku's daily batch through the real engine and a fake runner: the same safe mode as the coffee break, nothing of
/// the user's on the command line or in the prompt, and a failure leaves the built-in lines.
@Suite("FunBatchRun")
struct FunBatchRunTests {
    private static let day = Date(timeIntervalSince1970: 1_793_700_000)

    @Test("FUN-06 the batch runs Haiku in safe mode with no tools and a low budget, and returns the lines")
    @MainActor
    func runsSafely() async throws {
        let lines = ["redemption": ["The butler found sunshine behind the red clouds."], "tip": ["Rest your eyes between two builds."]]
        let fake = FakeHaiku(result: String(decoding: try JSONEncoder().encode(lines), as: UTF8.self))
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver(found: true))
        let answer = await store.funBatch(on: Self.day, calendar: .current)
        #expect(answer == lines)

        let call = try #require(await fake.calls.first)
        let arguments = call.arguments
        #expect(Array(arguments.prefix(11)) == [
            "-p", "--output-format", "json", "--model", "haiku", "--tools", "", "--safe-mode", "--no-session-persistence",
            "--max-budget-usd", "0.10",
        ])
        #expect(!arguments.contains("--add-dir") && !arguments.contains("--allowedTools") && !arguments.contains("--json-schema"))
        // The prompt on stdin is exactly the batch prompt: the key descriptions, the weekday and the season.
        #expect(call.input == FunBatch.prompt(on: Self.day, calendar: .current).text)
        #expect(!arguments.joined(separator: " ").contains("Wednesday"))
    }

    @Test("FUN-06 the answer may come as text with a code fence")
    @MainActor
    func fenced() async throws {
        let fake = FakeHaiku(result: "Here you go:\n```json\n{\"merged\": [\"Merged and very well mannered.\"]}\n```")
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: fake, resolver: fake.resolver(found: true))
        #expect(await store.funBatch(on: Self.day) == ["merged": ["Merged and very well mannered."]])
    }

    @Test("FUN-06 nothing is asked while Claude is off or missing; a bad answer gives nothing and the fallbacks stand")
    @MainActor
    func offAndBroken() async throws {
        let missing = FakeHaiku(result: "{}")
        let none = AIStore(defaults: TemporaryDefaults().defaults, runner: missing, resolver: missing.resolver(found: false))
        #expect(await none.funBatch(on: Self.day) == nil)
        #expect(await missing.calls.isEmpty)

        let off = FakeHaiku(result: "{}")
        let disabled = AIStore(defaults: TemporaryDefaults().defaults, runner: off, resolver: off.resolver(found: true))
        disabled.update(AISettings(isEnabled: false))
        #expect(await disabled.funBatch(on: Self.day) == nil)
        #expect(await off.calls.isEmpty)

        let broken = FakeHaiku(result: "I could not think of anything funny today.")
        let store = AIStore(defaults: TemporaryDefaults().defaults, runner: broken, resolver: broken.resolver(found: true))
        #expect(await store.funBatch(on: Self.day) == nil)
        let fun = FunStore()
        #expect(FunLines.merged.contains(fun.draw(.merged, now: Self.day, seed: 3)))
    }
}

/// A runner whose `claude` answers with one made-up result, and which counts the calls.
private actor FakeHaiku: ProcessRunner {
    struct Call: Sendable {
        var arguments: [String]
        var input: String?
    }

    private let result: String
    private(set) var calls: [Call] = []

    init(result: String) {
        self.result = result
    }

    func run(_ executable: URL, arguments: [String], input: Data?) async throws -> ProcessOutput {
        if executable.lastPathComponent == "zsh" {
            return ProcessOutput(status: 1)
        }
        if arguments == ["--version"] {
            return ProcessOutput(status: 0, standardOutput: Data("2.1.317 (Claude Code)\n".utf8))
        }
        calls.append(Call(arguments: arguments, input: input.map { String(decoding: $0, as: UTF8.self) }))
        let object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false, "result": result,
            "usage": ["input_tokens": 100, "output_tokens": 300],
        ]
        return ProcessOutput(status: 0, standardOutput: try JSONSerialization.data(withJSONObject: object))
    }

    nonisolated func resolver(found: Bool) -> ProgramResolver {
        ProgramResolver(runner: self, home: URL(filePath: "/Users/nobody")) { path in
            found && path == "/opt/homebrew/bin/claude"
        }
    }
}

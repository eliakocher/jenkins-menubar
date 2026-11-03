import Foundation
import Testing

@testable import MenubarCore

/// FUN-05 to FUN-07: the line pool, the no-repeat rule, Haiku's daily batch and the fallbacks.
@Suite("FunStore")
struct FunStoreTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

    @Test("FUN-05 every kind of line has at least ten built-in fallbacks, all different, with only their own tokens")
    func fallbacks() {
        for key in FunKey.allCases {
            let lines = FunLines.lines(for: key)
            #expect(lines.count >= 10, "\(key) has \(lines.count) lines")
            #expect(Set(lines).count == lines.count, "\(key) repeats a line")
            for line in lines {
                #expect(!line.isEmpty && line.count <= 140, "\(line)")
                var rest = line
                key.tokens.forEach { rest = rest.replacingOccurrences(of: $0, with: "") }
                #expect(!rest.contains("{") && !rest.contains("}"), "a foreign token in \(line)")
            }
        }
        // Tokens are filled in.
        #expect(FunLines.fill("{d} of building.", ["{d}": "1h12m"]) == "1h12m of building.")
    }

    @Test("FUN-05 a drawn line isn't drawn again for two weeks, then the oldest comes back")
    func noRepeat() {
        let store = FunStore(calendar: Self.calendar)
        let count = FunLines.redemption.count
        var drawn: [String] = []
        for index in 0..<count {
            drawn.append(store.draw(.redemption, now: Self.day.addingTimeInterval(Double(index)), seed: index))
        }
        #expect(Set(drawn).count == count)
        // Everything is seen: the line seen longest ago comes back.
        let again = store.draw(.redemption, now: Self.day.addingTimeInterval(100), seed: 0)
        #expect(again == drawn[0])
        // After two weeks all of them are fresh again.
        let later = Self.day.addingTimeInterval(15 * 24 * 3600)
        let fresh = store.draw(.redemption, now: later, seed: 3)
        #expect(FunLines.redemption.contains(fresh))
        #expect(store.snapshot.seen.count == 1)
    }

    @Test("FUN-06 Haiku's lines are drawn first, once each, and only usable ones get into the pool")
    func pool() {
        let store = FunStore(calendar: Self.calendar)
        let added = store.addBatch(
            [
                "redemption": [
                    "The butler found a new hat in the lost and found.", "Too short", "Counting 3 builds is a number line.",
                    "See https://example.com for a reason to smile.", "The butler found a new hat in the lost and found.",
                ],
                "longBuild": ["{d} of building and the butler learned to juggle."],
                "streak": ["{d} is the wrong token for this key, sadly."],
                "nonsense": ["This key does not exist in the app at all."],
            ], now: Self.day)
        #expect(added == 2)
        #expect(store.poolCount(.redemption) == 1 && store.poolCount(.longBuild) == 1 && store.poolCount(.streak) == 0)
        let line = store.draw(.redemption, now: Self.day, seed: 0)
        #expect(line == "The butler found a new hat in the lost and found.")
        #expect(store.poolCount(.redemption) == 0)
        // The same line isn't taken into the pool again while it is remembered as seen.
        #expect(store.addBatch(["redemption": [line]], now: Self.day) == 0)
        #expect(store.draw(.longBuild, now: Self.day, values: ["{d}": "2h00m"]).hasPrefix("2h00m of building"))
        // Without a line in the pool, a built-in one stands in.
        #expect(FunLines.redemption.contains(store.draw(.redemption, now: Self.day, seed: 1)))
    }

    @Test("FUN-06 the pool keeps at most twelve lines a key")
    func poolLimit() {
        let store = FunStore(calendar: Self.calendar)
        let names = ["alpha", "beta", "gamma", "delta", "kappa", "sigma", "omega", "theta", "iota", "zeta", "lambda", "epsilon", "rho", "tau", "phi", "psi", "chi", "eta", "mu", "nu"]
        let words = names.map { "A friendly line about build \($0)." }
        #expect(store.addBatch(["merged": words], now: Self.day) == FunStore.poolLimit)
    }

    @Test("FUN-06 the batch is due once a day and once more while four kinds ran dry; never a third call")
    func batchCap() {
        let store = FunStore(calendar: Self.calendar)
        #expect(store.needsBatch(now: Self.day))
        #expect(store.reserveBatch(now: Self.day))
        // Nothing is in the pool, so every kind ran dry: one top-up.
        #expect(store.needsBatch(now: Self.day))
        #expect(store.reserveBatch(now: Self.day))
        #expect(!store.needsBatch(now: Self.day) && !store.reserveBatch(now: Self.day))
        // Tomorrow it is due again.
        #expect(store.needsBatch(now: Self.day.addingTimeInterval(24 * 3600)))
        // With full pools, a second call the same day isn't due.
        let full = FunStore(calendar: Self.calendar)
        for key in FunKey.allCases {
            let lines = (0..<3).map { "A kind line for \(key.rawValue), take \(["alpha", "beta", "gamma"][$0])." }
            full.addBatch([key.rawValue: lines], now: Self.day)
        }
        #expect(full.reserveBatch(now: Self.day) && !full.needsBatch(now: Self.day))
    }

    @Test("FUN-06 the batch's answer is read from JSON, also inside a code fence or a sentence")
    func parsing() {
        #expect(FunBatch.parse(#"{"merged": ["a line"]}"#) == ["merged": ["a line"]])
        #expect(FunBatch.parse("Sure!\n```json\n{\"tip\": [\"one\", \"two\"]}\n```") == ["tip": ["one", "two"]])
        #expect(FunBatch.parse("no json here") == nil && FunBatch.parse(nil) == nil)
        #expect(FunBatch.parse(#"{"merged": "not an array"}"#) == nil)
    }

    @Test("FUN-06 the batch prompt holds the fixed key descriptions, the weekday and the season, and nothing else")
    func promptHasNoUserData() {
        let prompt = FunBatch.prompt(on: Self.day, calendar: Self.calendar)
        #expect(prompt.useCase == .funBatch && prompt.schema == nil && prompt.readableFolder == nil && prompt.question == nil)
        #expect(prompt.text.hasPrefix("Today is Wednesday, in autumn. "))
        for key in FunKey.allCases {
            #expect(prompt.text.contains("- \(key.rawValue): \(key.promptHint)\n"))
        }
        // Everything after the first sentences is the key list: no build, job, branch, name or number of the user's.
        let rest = prompt.text.dropFirst("Today is Wednesday, in autumn. ".count)
        let expected = "Write \(FunBatch.linesPerKey) fresh lines for each of these keys:\n"
            + FunKey.allCases.map { "- \($0.rawValue): \($0.promptHint)\n" }.joined()
        #expect(String(rest) == expected)
        #expect(prompt.instructions.contains("Never write a digit"))
    }

    @Test("FUN-05 the counters, the pool and the catches survive a relaunch; a damaged file starts over")
    func persistence() throws {
        let folder = try TemporaryFolder()
        let file = folder.file("nested/fun.json")
        let store = FunStore(file: file, calendar: Self.calendar)
        store.noteFinished(.success, now: Self.day)
        store.noteFinished(.success, now: Self.day)
        store.addBatch(["merged": ["A line that waits in the pool for its turn."]], now: Self.day)
        store.noteCatch()
        _ = store.tip(now: Self.day)
        let reopened = FunStore(file: file, calendar: Self.calendar)
        #expect(reopened.snapshot == store.snapshot)
        #expect(reopened.snapshot.greenStreak == 2 && reopened.snapshot.catches == 1 && reopened.poolCount(.merged) == 1)
        // The tip is one a day.
        #expect(reopened.tip(now: Self.day.addingTimeInterval(3600)) == store.tip(now: Self.day))
        try Data("{ not json".utf8).write(to: file)
        #expect(FunStore(file: file, calendar: Self.calendar).snapshot == FunStore.Stored())
    }

    @Test("FUN-05 once-a-day marks are true once a day")
    func marks() {
        let store = FunStore(calendar: Self.calendar)
        #expect(store.mark("x", now: Self.day))
        #expect(!store.mark("x", now: Self.day.addingTimeInterval(3600)))
        #expect(store.mark("x", now: Self.day.addingTimeInterval(24 * 3600)))
        #expect(store.mark("y", now: Self.day))
    }
}

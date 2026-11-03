import Foundation
import Testing

@testable import MenubarCore

@Suite("EggRules")
struct EggRulesTests {
    @Test("EGG-02 the Konami code needs its keys in order, at most 1.5 s apart")
    func konami() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ keys: [KonamiKey], gap: TimeInterval) -> [Bool] {
            var matcher = KonamiMatcher()
            return keys.enumerated().map { matcher.feed($1, at: start.addingTimeInterval(Double($0) * gap)) }
        }
        let code = KonamiMatcher.code
        #expect(run(code, gap: 0.5).last == true)
        #expect(run(code, gap: 0.5).dropLast().allSatisfy { !$0 })
        // A stray key before the code, or an extra ↑ inside it, doesn't hide it.
        #expect(run([.left, .up] + code, gap: 0.5).last == true)
        #expect(run([.up, .up, .up, .down, .down, .left, .right, .left, .right, .b, .a], gap: 0.5).last == true)
        // Too slow, or a wrong key.
        #expect(run(code, gap: 1.6).last == false)
        #expect(run(Array(code.dropLast()) + [.b], gap: 0.5).last == false)
        // Forgotten once it fired: the same keys again need the whole code.
        var matcher = KonamiMatcher()
        var fired = 0
        for (index, key) in (code + [.b, .a]).enumerated() where matcher.feed(key, at: start.addingTimeInterval(Double(index) * 0.2)) {
            fired += 1
        }
        #expect(fired == 1)
    }

    @Test("EGG-09 ten Check Nows within 10 s fire once per 10 min")
    func checkNowMashing() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func presses(_ gaps: [TimeInterval], counter: inout CheckMashCounter, from first: Date) -> [Bool] {
            var time = first
            return gaps.map { gap in
                time = time.addingTimeInterval(gap)
                return counter.press(at: time)
            }
        }
        var counter = CheckMashCounter()
        let fast = presses(Array(repeating: 1, count: 10), counter: &counter, from: start)
        #expect(fast == Array(repeating: false, count: 9) + [true])
        // Mashing again within 10 min stays quiet; after it, it fires again.
        #expect(presses(Array(repeating: 0.5, count: 10), counter: &counter, from: start.addingTimeInterval(30)).last == false)
        #expect(presses(Array(repeating: 0.5, count: 10), counter: &counter, from: start.addingTimeInterval(700)).last == true)
        // Ten presses spread over more than 10 s never fire.
        var slow = CheckMashCounter()
        #expect(presses(Array(repeating: 2, count: 20), counter: &slow, from: start).allSatisfy { !$0 })
    }

    @Test("EGG-21 the credits keep the butler's attribution with the eggs off")
    func credits() {
        #expect(EggRules.attribution.contains("CC BY-SA 3.0"))
        #expect(EggRules.attribution.contains("jenkins.io"))
        // Off, the roll is the author's serious credit alone: no gags.
        #expect(AboutCredits.groups(eggs: false) == [[AboutCredits.author]])
        // On, the roll keeps the author's line and has the butler's.
        let roll = AboutCredits.groups(eggs: true).flatMap { $0 }
        #expect(roll.contains(CreditLine("Directed by", "the butler")))
        #expect(roll.contains { $0.name == "Elia Kocher" })
        #expect(AboutCredits.copyright == "© 2026 Elia Kocher")
    }
}

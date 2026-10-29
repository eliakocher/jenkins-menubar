import Foundation
import Testing

@testable import MenubarCore

@Suite("TestClock")
struct TestClockTests {
    @Test("TestClock wakes only the sleepers that are due")
    func wakesDueSleepers() async throws {
        let clock = TestClock()
        let short = Task { try await clock.sleep(for: .seconds(3)) }
        let long = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(2)

        clock.advance(by: .seconds(4))
        try await short.value
        #expect(clock.sleeperCount == 1)
        #expect(clock.now == TestClock.Instant(offset: .seconds(4)))

        clock.advance(by: .seconds(1))
        try await long.value
        #expect(clock.sleeperCount == 0)
    }

    @Test("TestClock wakes a sleep that starts after an advance only at the next one")
    func laterSleepWaits() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))
        let sleep = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers()

        clock.advance(by: .seconds(1))
        try await sleep.value
        #expect(clock.now.offset == .seconds(11))
    }

    @Test("TestClock returns at once for a deadline that has passed")
    func pastDeadline() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(5))

        try await clock.sleep(until: TestClock.Instant(offset: .seconds(2)))
        try await clock.sleep(for: .zero)
        #expect(clock.sleeperCount == 0)
    }

    @Test("TestClock ends a cancelled sleep with CancellationError")
    func cancelledSleep() async throws {
        let clock = TestClock()
        let sleep = Task { try await clock.sleep(for: .seconds(60)) }
        await clock.waitForSleepers()

        sleep.cancel()
        await #expect(throws: CancellationError.self) { try await sleep.value }
        #expect(clock.sleeperCount == 0)

        let cancelledFirst = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(60))
        }
        await #expect(throws: CancellationError.self) { try await cancelledFirst.value }
        #expect(clock.sleeperCount == 0)
    }
}

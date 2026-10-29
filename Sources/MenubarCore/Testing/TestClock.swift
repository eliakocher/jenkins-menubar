#if DEBUG
import Foundation

/// A clock whose time moves only when a test advances it, for code that takes `any Clock<Duration>`. Debug builds only.
///
/// The code under test sleeps on it as on a real clock. The test waits until that code sleeps, then moves the time:
///
/// ```swift
/// let clock = TestClock()
/// let answer = Task { try await transport.send(request) }
/// await clock.waitForSleepers()
/// clock.advance(by: .seconds(20))
/// ```
///
/// `advance` wakes only the sleeps that were due by then; a sleep that starts after it waits for the next `advance`.
/// That keeps tests deterministic: to run a loop three times, wait for its sleep and advance, three times.
public final class TestClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol, CustomStringConvertible {
        /// the time since the clock started
        public var offset: Swift.Duration

        public init(offset: Swift.Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public var description: String {
            "TestClock.Instant(\(offset))"
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var nextID: UInt64 = 0
        /// sleeps that started but haven't registered their continuation yet
        var starting: Set<UInt64> = []
        /// sleeps cancelled before they registered
        var cancelled: Set<UInt64> = []
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
    }

    private let lock = NSLock()
    private var state: State

    public init(now: Instant = Instant()) {
        state = State(now: now)
    }

    public var now: Instant {
        lock.withLock { state.now }
    }

    public var minimumResolution: Swift.Duration {
        .zero
    }

    /// the number of tasks sleeping on this clock now
    public var sleeperCount: Int {
        lock.withLock { state.sleepers.count }
    }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = lock.withLock {
            state.nextID += 1
            state.starting.insert(state.nextID)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, waiters): (Result<Void, any Error>?, [Waiter]) = lock.withLock {
                    state.starting.remove(id)
                    if state.cancelled.remove(id) != nil {
                        return (.failure(CancellationError()), [])
                    }
                    if deadline <= state.now {
                        return (.success(()), [])
                    }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return (nil, takeSatisfiedWaiters())
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
                for waiter in waiters {
                    waiter.continuation.resume()
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                if state.starting.remove(id) != nil {
                    state.cancelled.insert(id)
                }
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` tasks sleep on this clock.
    ///
    /// - Parameter count: the number of sleeping tasks to wait for
    public func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if state.sleepers.count >= count {
                    return true
                }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    /// Moves the time forward and wakes, earliest first, every sleeper whose deadline has come.
    ///
    /// - Parameter duration: how far to move the time; not negative
    public func advance(by duration: Swift.Duration) {
        advance(to: now.advanced(by: duration))
    }

    /// Moves the time to an instant and wakes, earliest first, every sleeper whose deadline has come. An instant in the
    /// past changes nothing.
    ///
    /// - Parameter instant: the new time
    public func advance(to instant: Instant) {
        let due: [Sleeper] = lock.withLock {
            guard instant > state.now else {
                return []
            }
            state.now = instant
            let due = state.sleepers.filter { $0.deadline <= instant }
            state.sleepers.removeAll { $0.deadline <= instant }
            return due.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Removes and returns the waiters whose count of sleepers is reached. Called with the lock held.
    private func takeSatisfiedWaiters() -> [Waiter] {
        let count = state.sleepers.count
        let satisfied = state.waiters.filter { $0.count <= count }
        state.waiters.removeAll { $0.count <= count }
        return satisfied
    }
}
#endif

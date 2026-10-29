import Foundation

/// The Mac going to sleep or waking up (OD-05).
public enum SystemEvent: String, Hashable, Sendable, CaseIterable {
    case willSleep
    case didWake
}

/// Tells when the Mac goes to sleep and wakes up (OD-05).
///
/// The app implements it with NSWorkspace's sleep and wake notifications; tests use ``FakeSystemEvents``.
public protocol SystemEvents: Sendable {
    /// Returns the events from now on. Each call gives a stream of its own.
    func events() -> AsyncStream<SystemEvent>
}

/// Tells whether the Mac has a network path (OD-05).
///
/// ``PathReachability`` implements it with NWPathMonitor; tests use ``FakeReachability``.
public protocol Reachability: Sendable {
    /// Returns whether the network can be reached: the current value first, then each change. Each call gives a
    /// stream of its own.
    func updates() -> AsyncStream<Bool>
}

/// Tells whether Low Power Mode is on (OD-05).
///
/// ``SystemPowerMode`` implements it with ProcessInfo; tests use ``FakePowerMode``.
public protocol PowerMode: Sendable {
    /// Returns whether Low Power Mode is on: the current value first, then each change. Each call gives a stream of
    /// its own.
    func lowPowerModeUpdates() -> AsyncStream<Bool>
}

/// Low Power Mode as ProcessInfo reports it, read again at each `NSProcessInfoPowerStateDidChange`.
public struct SystemPowerMode: PowerMode {
    public init() {}

    public func lowPowerModeUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(ProcessInfo.processInfo.isLowPowerModeEnabled)
            let observer = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
            ) { _ in
                continuation.yield(ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
            let token = ObserverToken(observer)
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.observer)
            }
        }
    }

    /// The observer that NotificationCenter hands out, which only the termination handler removes.
    private final class ObserverToken: @unchecked Sendable {
        let observer: any NSObjectProtocol

        init(_ observer: any NSObjectProtocol) {
            self.observer = observer
        }
    }
}

#if DEBUG
/// Sleep and wake events that a test sends by hand. Debug builds only.
public final class FakeSystemEvents: SystemEvents, @unchecked Sendable {
    private let broadcast = FakeBroadcast<SystemEvent>(current: nil)

    public init() {}

    public func events() -> AsyncStream<SystemEvent> {
        broadcast.stream()
    }

    /// Sends an event to every stream made so far.
    public func send(_ event: SystemEvent) {
        broadcast.send(event)
    }
}

/// A network path that a test turns on and off. Debug builds only.
public final class FakeReachability: Reachability, @unchecked Sendable {
    private let broadcast: FakeBroadcast<Bool>

    /// - Parameter reachable: whether the network can be reached at first
    public init(reachable: Bool = true) {
        broadcast = FakeBroadcast(current: reachable)
    }

    public func updates() -> AsyncStream<Bool> {
        broadcast.stream()
    }

    /// Changes whether the network can be reached, and tells every stream made so far.
    public func set(reachable: Bool) {
        broadcast.send(reachable)
    }
}

/// Low Power Mode that a test turns on and off. Debug builds only.
public final class FakePowerMode: PowerMode, @unchecked Sendable {
    private let broadcast: FakeBroadcast<Bool>

    /// - Parameter lowPowerMode: whether Low Power Mode is on at first
    public init(lowPowerMode: Bool = false) {
        broadcast = FakeBroadcast(current: lowPowerMode)
    }

    public func lowPowerModeUpdates() -> AsyncStream<Bool> {
        broadcast.stream()
    }

    /// Turns Low Power Mode on or off, and tells every stream made so far.
    public func set(lowPowerMode: Bool) {
        broadcast.send(lowPowerMode)
    }
}

/// Hands each value to every stream made so far; a new stream starts with the current value, when there is one.
final class FakeBroadcast<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(current: Value?) {
        self.current = current
    }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        let id = UUID()
        let current = lock.withLock {
            continuations[id] = continuation
            return self.current
        }
        if let current {
            continuation.yield(current)
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ value: Value) {
        let continuations = lock.withLock {
            if current != nil {
                current = value
            }
            return Array(self.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(value)
        }
    }
}
#endif

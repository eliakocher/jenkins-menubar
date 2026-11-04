import Foundation
import Observation

/// Remembers values that are made from observable state, until anything they read changes (the Slots page's plan).
///
/// A value is made once per key. While it is made, the state it reads is tracked; when any of it changes, every remembered
/// value is forgotten and ``generation`` goes up. So reading the same key again gives the same value without making it
/// again, however often a view is drawn, and the next read after a change makes it afresh.
///
/// A view that reads through ``value(for:make:)`` is drawn again after a change: it reads ``generation``, which the
/// change bumps. State that isn't observable, like the clock, belongs in the key.
@Observable @MainActor
public final class ObservedCache {
    /// how often the remembered values were forgotten; a view that reads a value depends on it
    public private(set) var generation = 0
    /// how many values were made, which tests count
    @ObservationIgnored public private(set) var makes = 0
    @ObservationIgnored private var values: [AnyHashable: Any] = [:]
    /// how many makes are running; a nested read must not track ``generation``, or forgetting bumps it inside its own change
    @ObservationIgnored private var making = 0

    /// the most values kept at once: chips and days that came and went
    private static let capacity = 16

    public init() {}

    /// Returns the value of a key: the remembered one, else the one `make` returns, which is then remembered.
    ///
    /// - Parameters:
    ///   - key: what tells the values apart, with what the state doesn't have (the day, the chips)
    ///   - make: makes the value; what it reads from observable state is tracked
    /// - Returns: the value
    public func value<Value>(for key: some Hashable, make: () -> Value) -> Value {
        // A view that reads this depends on the next forgetting; a make that reads another key doesn't (it would forget
        // again inside the change of `generation` itself and crash).
        if making == 0 {
            _ = generation
        }
        let key = AnyHashable(key)
        if let remembered = values[key] as? Value {
            return remembered
        }
        makes += 1
        making += 1
        defer { making -= 1 }
        let value = withObservationTracking(make, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.forgetAll() }
        })
        if values.count >= Self.capacity {
            values.removeAll()
        }
        values[key] = value
        return value
    }

    /// Forgets every value, as a change of what they read does.
    public func forgetAll() {
        values.removeAll()
        generation += 1
    }
}

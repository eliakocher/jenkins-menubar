import Foundation

/// A key of the Konami code.
public enum KonamiKey: Hashable, Sendable {
    case up
    case down
    case left
    case right
    case b
    case a
}

/// Watches the keys of the pane for ↑ ↑ ↓ ↓ ← → ← → B A, at most 1.5 s between two keys (EGG-02).
///
/// It keeps the last keys, so a stray key before the code, or an extra ↑, doesn't hide it.
public struct KonamiMatcher: Sendable {
    /// the code
    public static let code: [KonamiKey] = [.up, .up, .down, .down, .left, .right, .left, .right, .b, .a]
    /// the longest pause between two keys of the code
    public static let pause: TimeInterval = 1.5

    private var recent: [KonamiKey] = []
    private var lastKeyAt: Date?

    public init() {}

    /// Notes a key.
    ///
    /// - Parameters:
    ///   - key: the key
    ///   - now: when it was pressed
    /// - Returns: `true` when the key completes the code; the keys are forgotten then
    public mutating func feed(_ key: KonamiKey, at now: Date) -> Bool {
        if let lastKeyAt, now.timeIntervalSince(lastKeyAt) > Self.pause {
            recent = []
        }
        lastKeyAt = now
        recent.append(key)
        if recent.count > Self.code.count {
            recent.removeFirst(recent.count - Self.code.count)
        }
        guard recent == Self.code else {
            return false
        }
        recent = []
        return true
    }
}

/// One frame of the butler's bow in the status icon.
public enum BowFrame: Hashable, Sendable {
    case upright
    case half
    case full
}

/// The steps of the bow (EGG-02): upright, half bow, full bow, half bow, upright, 0.4 s each; under Reduce Motion the
/// full-bow frame alone for 1.6 s.
public enum BowSequence {
    /// Returns the frames and how long each stays.
    ///
    /// - Parameter reduceMotion: whether Reduce Motion is on
    public static func steps(reduceMotion: Bool) -> [(frame: BowFrame, duration: Duration)] {
        if reduceMotion {
            return [(frame: .full, duration: .milliseconds(1600))]
        }
        return [BowFrame.upright, .half, .full, .half, .upright].map { (frame: $0, duration: Duration.milliseconds(400)) }
    }
}

/// Counts the Check Nows for the mashing egg (EGG-09): ten within 10 s, at most once per 10 min.
public struct CheckMashCounter: Sendable {
    /// how many presses within ``window`` fire the egg
    public static let presses = 10
    public static let window: TimeInterval = 10
    /// the least time between two firings
    public static let cooldown: TimeInterval = 600

    private var times: [Date] = []
    private var lastFired: Date?

    public init() {}

    /// Notes a Check Now.
    ///
    /// - Parameter now: when it was pressed
    /// - Returns: `true` when this press is the tenth within 10 s and the egg hasn't fired in the last 10 min
    public mutating func press(at now: Date) -> Bool {
        times.append(now)
        times.removeAll { now.timeIntervalSince($0) > Self.window }
        guard times.count >= Self.presses else {
            return false
        }
        if let lastFired, now.timeIntervalSince(lastFired) < Self.cooldown {
            return false
        }
        lastFired = now
        times = []
        return true
    }
}

import Foundation
import Observation

/// The eggs that play out live: the Konami bow of the status icon (EGG-02) and the line Check Now shows while it is
/// mashed (EGG-09). The views read what shows now; the keys and the Check Nows feed it.
///
/// It never makes a sound, takes the focus or waits for anything: a check starts as it always does.
@Observable
@MainActor
public final class EggStage {
    /// the bow frame the status icon shows now; `nil` when the butler isn't bowing
    public private(set) var bow: BowFrame?
    /// the line that replaces "Last checked" for 5 s after a Check Now was mashed; `nil` otherwise
    public private(set) var mashLine: String?

    /// how long the mashing line shows
    public static let mashLineDuration = Duration.seconds(5)

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var matcher = KonamiMatcher()
    @ObservationIgnored private var counter = CheckMashCounter()
    @ObservationIgnored private var bowing: Task<Void, Never>?
    @ObservationIgnored private var mashing: Task<Void, Never>?

    /// - Parameters:
    ///   - now: the current time
    ///   - clock: the clock of the animation's waits
    public init(now: @escaping @Sendable () -> Date, clock: any Clock<Duration>) {
        self.now = now
        self.clock = clock
    }

    /// Notes a key of the pane; the code makes the butler bow.
    ///
    /// - Parameters:
    ///   - key: the key
    ///   - enabled: whether the easter eggs are on
    ///   - reduceMotion: whether Reduce Motion is on, which shows one frame instead of the bow
    public func key(_ key: KonamiKey, enabled: Bool, reduceMotion: Bool) {
        guard enabled, matcher.feed(key, at: now()), bowing == nil else {
            return
        }
        let steps = BowSequence.steps(reduceMotion: reduceMotion)
        bowing = Task { [clock] in
            for step in steps {
                bow = step.frame
                try? await clock.sleep(for: step.duration)
                if Task.isCancelled {
                    break
                }
            }
            bow = nil
            bowing = nil
        }
    }

    /// Notes a Check Now; the tenth within 10 s shows the line for 5 s.
    ///
    /// - Parameter enabled: whether the easter eggs are on
    public func checkNowPressed(enabled: Bool) {
        guard enabled, counter.press(at: now()) else {
            return
        }
        mashLine = EggRules.checkNowMashing
        mashing?.cancel()
        mashing = Task { [clock] in
            try? await clock.sleep(for: Self.mashLineDuration)
            guard !Task.isCancelled else {
                return
            }
            mashLine = nil
        }
    }

    /// Ends what plays, as the app stops.
    public func stop() {
        bowing?.cancel()
        mashing?.cancel()
    }
}

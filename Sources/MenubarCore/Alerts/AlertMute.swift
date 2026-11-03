import Foundation
import Observation

/// Mute Alerts for 1 Hour (HOT-09): for an hour, the build alerts' glass panel and banners and the Inbox's panels and
/// desktop banners stay quiet, as for a muted job (ALERT-09). Everything is still logged, and still listed in the
/// builds and the Inbox. A hot corner or a menu fires it; fired again while muted, it ends the mute.
///
/// It is kept in memory only: a relaunch starts unmuted.
@Observable @MainActor
public final class AlertMute {
    /// how long one mute lasts
    public static let duration: Duration = .seconds(3600)

    /// when the mute ends; nil while not muted
    public private(set) var until: Date?

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let log: ActivityLog?
    /// the wait for the mute's end
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// the log lines, in order
    @ObservationIgnored private var logTask: Task<Void, Never>?

    /// - Parameters:
    ///   - now: the current time
    ///   - clock: the clock of the wait for the mute's end
    ///   - log: the Activity log; nil logs nothing
    public init(now: @escaping @Sendable () -> Date, clock: any Clock<Duration>, log: ActivityLog?) {
        self.now = now
        self.clock = clock
        self.log = log
    }

    /// whether the alerts are muted right now
    public var isMuted: Bool {
        guard let until else {
            return false
        }
        return now() < until
    }

    /// Mutes the alerts for an hour, or ends the mute while they are muted.
    ///
    /// - Returns: whether the alerts are muted afterwards
    @discardableResult
    public func toggle() -> Bool {
        if isMuted {
            unmute()
            return false
        }
        mute()
        return true
    }

    /// Mutes the alerts for an hour from now; a mute under way starts over.
    public func mute() {
        let end = now().addingTimeInterval(TimeInterval(Self.duration.components.seconds))
        until = end
        write("Alerts muted until \(end.formatted(date: .omitted, time: .shortened))")
        expiry?.cancel()
        expiry = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: Self.duration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.until == end else {
                return
            }
            self.until = nil
            self.write("Alerts unmuted: the hour is over")
        }
    }

    /// Ends the mute at once; nothing happens while not muted.
    public func unmute() {
        expiry?.cancel()
        expiry = nil
        guard until != nil else {
            return
        }
        until = nil
        write("Alerts unmuted")
    }

    private func write(_ message: String) {
        guard let log else {
            return
        }
        let previous = logTask
        logTask = Task {
            await previous?.value
            await log.log(.info, .alerts, message)
        }
    }

    #if DEBUG
    /// Waits until the log lines so far are written. Debug builds only.
    func settled() async {
        await logTask?.value
    }
    #endif
}

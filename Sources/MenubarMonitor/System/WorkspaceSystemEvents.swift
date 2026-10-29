import AppKit
import MenubarCore

/// Sleep and wake from NSWorkspace's notifications (OD-05): the scheduler cancels the check under way when the Mac
/// goes to sleep, and checks when it wakes.
struct WorkspaceSystemEvents: SystemEvents {
    func events() -> AsyncStream<SystemEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let observers = Observers(center: center, [
                center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                    continuation.yield(.willSleep)
                },
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                    continuation.yield(.didWake)
                },
            ])
            continuation.onTermination = { _ in
                observers.remove()
            }
        }
    }

    /// The observers NotificationCenter hands out, which only the stream's end removes.
    private final class Observers: @unchecked Sendable {
        private let center: NotificationCenter
        private let observers: [any NSObjectProtocol]

        init(center: NotificationCenter, _ observers: [any NSObjectProtocol]) {
            self.center = center
            self.observers = observers
        }

        func remove() {
            observers.forEach(center.removeObserver)
        }
    }
}

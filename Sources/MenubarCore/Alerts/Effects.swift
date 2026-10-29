import Foundation

/// The side effects of the alerts: the alert window, banners and sounds.
///
/// The app's `NativeEffects` shows the floating alert window as a panel of its own, posts banners through
/// UNUserNotificationCenter and plays sounds with NSSound. Tests and the gallery use ``FakeEffects``.
public protocol Effects: Sendable {
    /// Shows the alert in a floating window of its own (ALERT-03).
    func showAlertWindow(_ alert: BuildAlert) async

    /// Posts the alert as a banner, with the actions of its category (ALERT-03, ALERT-05).
    ///
    /// - Parameter alert: the alert
    /// - Returns: `false` when notifications aren't allowed, so no banner showed
    func postBanner(_ alert: BuildAlert) async -> Bool

    /// Plays a system sound.
    func playSound(_ sound: AlertContent.Sound) async

    /// Posts a slot notice as a banner, without a sound (SLOT-04).
    ///
    /// - Parameter notice: the notice
    /// - Returns: `false` when notifications aren't allowed, so no banner showed
    func postNotice(_ notice: SlotNotice) async -> Bool
}

extension Effects {
    /// Effects without banners for notices show none.
    public func postNotice(_ notice: SlotNotice) async -> Bool { false }
}

#if DEBUG
/// Effects that only record what they were asked to do. Debug builds only.
public actor FakeEffects: Effects {
    /// One thing the effects were asked to do.
    public enum Call: Hashable, Sendable {
        case alertWindow(BuildAlert)
        case banner(BuildAlert)
        case sound(AlertContent.Sound)
        case notice(SlotNotice)
    }

    /// what was asked, in order
    public private(set) var calls: [Call] = []
    /// whether banners show; when `false`, ``postBanner(_:)`` records nothing and returns `false`
    public var notificationsAllowed: Bool

    public init(notificationsAllowed: Bool = true) {
        self.notificationsAllowed = notificationsAllowed
    }

    public func setNotificationsAllowed(_ allowed: Bool) {
        notificationsAllowed = allowed
    }

    public func showAlertWindow(_ alert: BuildAlert) {
        calls.append(.alertWindow(alert))
    }

    public func postBanner(_ alert: BuildAlert) -> Bool {
        guard notificationsAllowed else {
            return false
        }
        calls.append(.banner(alert))
        return true
    }

    public func playSound(_ sound: AlertContent.Sound) {
        calls.append(.sound(sound))
    }

    public func postNotice(_ notice: SlotNotice) -> Bool {
        guard notificationsAllowed else {
            return false
        }
        calls.append(.notice(notice))
        return true
    }

    /// the slot notices posted, in order
    public var notices: [SlotNotice] {
        calls.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }

    /// the alerts shown in a window, in order
    public var alertWindows: [BuildAlert] {
        calls.compactMap { if case .alertWindow(let alert) = $0 { alert } else { nil } }
    }

    /// the alerts posted as banners, in order
    public var banners: [BuildAlert] {
        calls.compactMap { if case .banner(let alert) = $0 { alert } else { nil } }
    }

    /// the sounds played, in order
    public var sounds: [AlertContent.Sound] {
        calls.compactMap { if case .sound(let sound) = $0 { sound } else { nil } }
    }

    /// Forgets the calls so far.
    public func reset() {
        calls = []
    }
}
#endif

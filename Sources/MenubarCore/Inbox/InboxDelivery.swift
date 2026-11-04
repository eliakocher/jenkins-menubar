import Foundation

/// What an event does when it happens, chosen per event in Settings → Notifications: a pop-up, a banner, an Inbox entry
/// or nothing (the user, 2026-11-03: "a single selection button toggle"). Every choice except ``off`` puts an entry in the
/// Inbox, so a pop-up or a banner is never the only trace of something.
///
/// The raw values are the ones the old Big Panel / Desktop Notification / Inbox Only choices were stored under, so a saved
/// choice reads as before.
public enum InboxDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    /// the app's own window in the middle of the screen, with the butler: it stays until it is closed
    case popUp = "bigPanel"
    /// a macOS banner through the notification center, with Show, Mark Done and Snooze 1 Hour
    case banner = "desktopNotification"
    /// an entry in the Inbox, nothing more: no window, no banner, no sound
    case inbox = "inboxOnly"
    /// nothing at all: no pop-up, no banner, no sound and no entry
    case off

    /// the choice in the control, in Title Style
    public var title: String {
        switch self {
        case .popUp: "Pop-up"
        case .banner: "Banner"
        case .inbox: "Inbox"
        case .off: "Off"
        }
    }

    /// the choice's small symbol (SF Symbols)
    public var systemImage: String {
        switch self {
        case .popUp: "macwindow"
        case .banner: "bell.badge"
        case .inbox: "tray"
        case .off: "nosign"
        }
    }

    /// What the choice does, for its tooltip.
    ///
    /// - Parameter isBuild: whether the row is a finished build, which also plays its sound
    public func explanation(isBuild: Bool) -> String {
        switch self {
        case .popUp:
            isBuild
                ? "A window in the middle of the screen with the butler and a sound; it stays until you close it. It also waits in the Inbox."
                : "A window in the middle of the screen with the butler; it stays until you close it. It also waits in the Inbox."
        case .banner:
            isBuild
                ? "macOS's notification banner, with a sound. It also waits in the Inbox."
                : "macOS's notification banner. It also waits in the Inbox."
        case .inbox: "Only an entry in the Inbox: no window, no banner, no sound."
        case .off: "Nothing: no window, no banner, no sound and no Inbox entry."
        }
    }

    /// the control's order: the loud choices first, then the quiet ones
    public static let pickerOrder: [InboxDelivery] = [.popUp, .banner, .inbox, .off]
}

extension InboxEventKind {
    /// whether the Inbox's delivery rules leave this kind out: my own to-dos never announce themselves
    var deliveryIsNotInTheRules: Bool {
        self == .myTodo
    }

    /// whether the kind is a finished build, whose choice also decides the sound and the pop-up of the build alerts
    public var isFinishedBuild: Bool {
        switch self {
        case .buildFailed, .buildSucceeded, .watchedBuildFailed, .watchedBuildSucceeded: true
        default: false
        }
    }

    /// What the kind does until the user picks: my Jenkins builds pop up, the Jenkins builds I watch show as a banner, GitLab's
    /// "pipeline failed" is Off (the failed Jenkins build is the news, and GitLab's to-do for it is hidden from the Inbox,
    /// the user, 2026-11-04), the rest is an Inbox entry.
    public var defaultDelivery: InboxDelivery {
        switch self {
        case .buildFailed, .buildSucceeded: .popUp
        case .watchedBuildFailed, .watchedBuildSucceeded: .banner
        case .pipelineFailed: .off
        default: .inbox
        }
    }

    /// whether the kind counts in the Red Dot until the user changes it: everything but the successful builds
    public var countsInRedDotByDefault: Bool {
        self != .buildSucceeded && self != .watchedBuildSucceeded
    }

    /// the choices that make sense for the kind: all of them, the same columns in every row
    public var availableDeliveries: [InboxDelivery] {
        self == .myTodo ? [.inbox] : InboxDelivery.pickerOrder
    }
}

extension InboxNotificationRules {
    /// The kinds whose delivery these rules keep: everything but the user's own to-dos, which never announce themselves.
    public static var deliveryKinds: [InboxEventKind] {
        settingsKinds.filter { !$0.deliveryIsNotInTheRules }
    }

    /// Returns what a kind does when it happens.
    ///
    /// - Parameter kind: the kind
    /// - Returns: the user's choice, or the kind's default; ``InboxDelivery/inbox`` for my own to-dos
    public func delivery(for kind: InboxEventKind) -> InboxDelivery {
        kind.deliveryIsNotInTheRules ? .inbox : deliveries[kind.rawValue] ?? kind.defaultDelivery
    }

    /// Sets what a kind does; the kind's default removes the override. It does nothing for the kinds the rules don't
    /// deliver (the user's own to-dos).
    ///
    /// - Parameters:
    ///   - delivery: the choice
    ///   - kind: the kind
    public mutating func set(_ delivery: InboxDelivery, for kind: InboxEventKind) {
        guard !kind.deliveryIsNotInTheRules else {
            return
        }
        deliveries[kind.rawValue] = delivery == kind.defaultDelivery ? nil : delivery
    }

    /// whether any kind shows as a macOS banner, which needs the notification permission
    public var usesBanners: Bool {
        Self.deliveryKinds.contains { delivery(for: $0) == .banner }
    }

    /// the groups in the user's order, every group once (``InboxGroupOrder``)
    public var groupOrder: [InboxGroup] {
        InboxGroupOrder.merged(stored: groupOrderNames)
    }

    /// Keeps a group order; the default order is kept as nothing, so a group added later lands in its place.
    ///
    /// - Parameter order: the groups in the user's order
    public mutating func setGroupOrder(_ order: [InboxGroup]) {
        groupOrderNames = InboxGroupOrder.stored(order)
    }
}

/// The order of the Inbox's groups, which the user can change in Settings → Notifications. It is kept as the groups' raw
/// names in ``InboxNotificationRules/groupOrderNames``, empty for the default order.
///
/// Like `SectionOrder`, a saved order survives updates: a name that isn't a group any more is dropped, and a group it
/// doesn't list yet takes its default place, right after the group that comes before it in the default order.
public enum InboxGroupOrder {
    /// Returns the groups in the saved order.
    ///
    /// - Parameters:
    ///   - stored: the saved names; empty is the default order
    ///   - groups: every group in the default order
    /// - Returns: every group once: the saved ones in their order, unknown names and repeats dropped, the others after
    ///   their default predecessor
    public static func merged(stored: [String], groups: [InboxGroup] = InboxGroup.allCases) -> [InboxGroup] {
        var result: [InboxGroup] = []
        for name in stored {
            if let group = InboxGroup(rawValue: name), groups.contains(group), !result.contains(group) {
                result.append(group)
            }
        }
        for (index, group) in groups.enumerated() where !result.contains(group) {
            var position = 0
            for earlier in groups[..<index].reversed() {
                if let found = result.firstIndex(of: earlier) {
                    position = found + 1
                    break
                }
            }
            result.insert(group, at: position)
        }
        return result
    }

    /// Returns the value to keep for an order: nothing for the default order.
    ///
    /// - Parameters:
    ///   - order: the groups in the user's order
    ///   - groups: every group in the default order
    public static func stored(_ order: [InboxGroup], groups: [InboxGroup] = InboxGroup.allCases) -> [String] {
        order == groups ? [] : order.map(\.rawValue)
    }

    /// Returns the order after a drag; the offsets are those of SwiftUI's `onMove`.
    ///
    /// - Parameters:
    ///   - order: the groups in their order
    ///   - source: the offsets of the dragged rows
    ///   - destination: the offset the rows are dropped before
    public static func moving(_ order: [InboxGroup], from source: IndexSet, to destination: Int) -> [InboxGroup] {
        let dragged = source.filter { order.indices.contains($0) }.map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let position = destination - source.count { $0 < destination }
        rest.insert(contentsOf: dragged, at: min(max(position, 0), rest.count))
        return rest
    }
}

/// What a button of the pop-up or a macOS banner does for an event (INBOX-14).
public enum InboxDeliveryAction: String, Sendable, CaseIterable {
    /// opens the event's target in the app and notes it as seen
    case show
    /// marks the event's entry done: a GitLab to-do in GitLab, a local entry here
    case done
    /// snoozes the entry for an hour
    case snooze
    /// closes the panel's page and leaves the entry in the Inbox; a banner's own dismissal
    case dismiss

    /// the button's name in the pop-up, in Title Style
    public var panelTitle: String {
        switch self {
        case .show: "Show"
        case .done: "Done"
        case .snooze: "Snooze 1 Hour"
        case .dismiss: "Dismiss"
        }
    }

    /// the button's name in the pop-up for an event: the coffee break's Done says it is on its way
    ///
    /// - Parameter kind: the event's kind
    public func panelTitle(for kind: InboxEventKind) -> String {
        self == .done && kind == .coffeeBreak ? "On My Way ☕" : panelTitle
    }

    /// the button's name on a banner: the banner's own dismissal is the system's
    public var bannerTitle: String {
        switch self {
        case .show: "Show"
        case .done: "Mark Done"
        case .snooze: "Snooze 1 Hour"
        case .dismiss: "Dismiss"
        }
    }
}

/// What an Inbox event's macOS banner carries and what its buttons mean (INBOX-14): a registered category with Show, Mark
/// Done and Snooze 1 Hour, and the event itself as JSON in the banner's user info, so a click after a relaunch still knows
/// what it is about.
public enum InboxBanner {
    /// the notification category of an Inbox event's banner
    public static let category = "inbox-event"
    /// the user info key that holds the event as JSON text
    public static let eventKey = "inboxEvent"
    /// the notification category of the coffee break's banner, which has no Snooze (the coffee break can't be snoozed)
    public static let coffeeCategory = "inbox-event-coffee"
    /// the actions, in the order the banner shows them
    public static let actions: [InboxDeliveryAction] = [.show, .done, .snooze]
    /// the actions of the coffee break's banner
    public static let coffeeActions: [InboxDeliveryAction] = [.done]

    /// Returns the category an event's banner carries.
    public static func category(for event: InboxEvent) -> String {
        event.kind.canSnooze ? category : coffeeCategory
    }

    /// Returns the identifier of an action's button.
    public static func identifier(of action: InboxDeliveryAction) -> String {
        "inbox." + action.rawValue
    }

    /// Returns what a click did.
    ///
    /// - Parameter identifier: the clicked action's identifier; `nil` for a click on the banner itself, which shows the event
    /// - Returns: the action; `nil` for an identifier that isn't one of the banner's buttons
    public static func action(forIdentifier identifier: String?) -> InboxDeliveryAction? {
        guard let identifier else {
            return .show
        }
        return actions.first { Self.identifier(of: $0) == identifier }
    }

    /// Returns the user info of an event's banner.
    public static func userInfo(for event: InboxEvent) -> [String: String] {
        guard let data = try? JSONEncoder().encode(event), let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return [eventKey: text]
    }

    /// Reads the event back from a banner's user info.
    ///
    /// - Parameter userInfo: the user info, as the notification delegate gets it
    /// - Returns: `nil` when it isn't an Inbox event's banner
    public static func event(from userInfo: [AnyHashable: Any]) -> InboxEvent? {
        guard let text = userInfo[eventKey] as? String else {
            return nil
        }
        return try? JSONDecoder().decode(InboxEvent.self, from: Data(text.utf8))
    }

    /// the banner's title: the headline, or the coffee break's own
    public static func title(of event: InboxEvent) -> String {
        event.kind == .coffeeBreak ? "☕ Coffee break" : event.headline
    }

    /// the banner's subtitle: the target's title; empty when it repeats the title
    public static func subtitle(of event: InboxEvent) -> String {
        event.kind == .coffeeBreak || event.title == title(of: event) ? "" : event.title
    }

    /// the banner's body: the line under the headline, like Claude's first line or the coffee break's line
    public static func body(of event: InboxEvent) -> String {
        event.excerpt ?? (event.kind == .coffeeBreak ? "" : event.reference ?? "")
    }
}

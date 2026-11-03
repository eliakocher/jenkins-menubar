import Foundation

/// How an event announces itself beyond the Inbox, chosen per kind in Settings → Notifications (Task 7.03, the user,
/// 2026-11-03: "it should be configurable if we want a big notification, a normal desktop notification or only in the
/// inbox"). The Inbox and Badge toggles stay as they are; this is the loud part.
public enum InboxDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    /// nothing beyond the Inbox, its badge and the menu bar's dot: what every kind does until the user picks
    case inboxOnly
    /// a macOS banner through the notification center, with Show, Mark Done and Snooze 1 Hour
    case desktopNotification
    /// the app's own floating panel, in the look of the failed-build alert, with Show, Done, Snooze 1 Hour and Dismiss
    case bigPanel

    /// the choice in the picker, in Title Style
    public var title: String {
        switch self {
        case .inboxOnly: "Inbox Only"
        case .desktopNotification: "Desktop Notification"
        case .bigPanel: "Big Panel"
        }
    }

    /// the picker's order: the quiet choice first, then the louder ones
    public static let pickerOrder: [InboxDelivery] = [.inboxOnly, .desktopNotification, .bigPanel]
}

extension InboxNotificationRules {
    /// The kinds that can announce themselves with a panel or a banner: everything but the user's own to-dos.
    public static var deliveryKinds: [InboxEventKind] {
        settingsKinds.filter { $0 != .myTodo }
    }

    /// Returns how a kind announces itself.
    ///
    /// - Parameter kind: the kind
    /// - Returns: the user's choice, or ``InboxDelivery/inboxOnly``
    public func delivery(for kind: InboxEventKind) -> InboxDelivery {
        kind == .myTodo ? .inboxOnly : deliveries[kind.rawValue] ?? .inboxOnly
    }

    /// Sets how a kind announces itself; the default removes the override.
    ///
    /// - Parameters:
    ///   - delivery: the choice
    ///   - kind: the kind
    public mutating func set(_ delivery: InboxDelivery, for kind: InboxEventKind) {
        deliveries[kind.rawValue] = delivery == .inboxOnly ? nil : delivery
    }

    /// whether any kind announces itself as a macOS banner, which needs the notification permission
    public var usesDesktopNotifications: Bool {
        deliveries.values.contains(.desktopNotification)
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

/// What a button of the big panel or a macOS banner does for an event (INBOX-14).
public enum InboxDeliveryAction: String, Sendable, CaseIterable {
    /// opens the event's target in the app and notes it as seen
    case show
    /// marks the event's entry done: a GitLab to-do in GitLab, a local entry here
    case done
    /// snoozes the entry for an hour
    case snooze
    /// closes the panel's page and leaves the entry in the Inbox; a banner's own dismissal
    case dismiss

    /// the button's name in the big panel, in Title Style
    public var panelTitle: String {
        switch self {
        case .show: "Show"
        case .done: "Done"
        case .snooze: "Snooze 1 Hour"
        case .dismiss: "Dismiss"
        }
    }

    /// the button's name in the big panel for an event: the coffee break's Done says it is on its way
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

/// The events the big panel holds, to page through, like the alert window's pages (``AlertPages``): the newest first. An
/// event that comes while the panel is open joins it and is shown at once; a dismissed page shows the next older one; the
/// panel closes once no page is left.
public struct InboxEventPages: Equatable, Sendable {
    /// the events, the newest first
    public private(set) var events: [InboxEvent] = []
    /// the shown page's place in ``events``
    public private(set) var index = 0

    public init() {}

    public var isEmpty: Bool { events.isEmpty }
    public var count: Int { events.count }

    /// the event shown; `nil` once none is left
    public var current: InboxEvent? {
        events.indices.contains(index) ? events[index] : nil
    }

    /// "1 of 3"; the newest event is the first
    public var position: String { "\(index + 1) of \(events.count)" }
    public var hasPrevious: Bool { index > 0 }
    public var hasNext: Bool { index + 1 < events.count }

    /// Adds an event as the newest page, and shows it. An event already in the panel is replaced and shown.
    public mutating func add(_ event: InboxEvent) {
        events.removeAll { $0.id == event.id }
        events.insert(event, at: 0)
        index = 0
    }

    public mutating func previous() {
        if hasPrevious { index -= 1 }
    }

    public mutating func next() {
        if hasNext { index += 1 }
    }

    /// Removes a page; the one shown is followed by the next older page, or by the one before it when it was the last.
    ///
    /// - Parameter id: the event's id
    public mutating func dismiss(_ id: String) {
        guard let removed = events.firstIndex(where: { $0.id == id }) else {
            return
        }
        events.remove(at: removed)
        if removed < index {
            index -= 1
        }
        index = max(0, min(index, events.count - 1))
    }

    public mutating func dismissAll() {
        events = []
        index = 0
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

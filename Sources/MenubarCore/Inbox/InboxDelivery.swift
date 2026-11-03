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

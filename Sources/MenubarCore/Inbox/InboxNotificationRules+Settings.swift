import Foundation

extension InboxNotificationRules {
    /// The kinds Settings → Notifications lists, in the order of the pane: what needs me first, then what happened to
    /// my merge requests, then the rest.
    public static let settingsKinds: [InboxEventKind] = [
        .assigned, .reviewRequested, .mentioned, .approved, .changesRequested, .reviewed, .merged, .pipelineFailed,
        .buildFailed, .claudeAnswered, .digestReady, .coffeeBreak, .otherTodo, .myTodo,
    ]

    /// Returns whether a kind goes to a route, as the user set it (before quiet hours and the projects filter).
    ///
    /// - Parameters:
    ///   - route: the route
    ///   - kind: the kind
    /// - Returns: whether the kind's routes have it
    public func sends(_ kind: InboxEventKind, to route: InboxRoutes) -> Bool {
        routes(for: kind).contains(route)
    }

    /// Turns one route of a kind on or off and keeps the others, as the toggles of Settings → Notifications do.
    ///
    /// - Parameters:
    ///   - route: the route
    ///   - isOn: whether the kind goes there
    ///   - kind: the kind
    public mutating func set(_ route: InboxRoutes, _ isOn: Bool, for kind: InboxEventKind) {
        var routes = routes(for: kind)
        if isOn {
            routes.insert(route)
        } else {
            routes.remove(route)
        }
        set(routes, for: kind)
    }

    /// One line for the log when the routing changes: what is off, and the projects filter.
    public var summary: String {
        var parts: [String] = []
        let hidden = Self.settingsKinds.filter { !sends($0, to: .inbox) }.map(\.title)
        if !hidden.isEmpty {
            parts.append("not in the Inbox: \(hidden.joined(separator: ", "))")
        }
        let uncounted = Self.settingsKinds.filter { !sends($0, to: .badge) }.map(\.title)
        if !uncounted.isEmpty {
            parts.append("not in the badge: \(uncounted.joined(separator: ", "))")
        }
        let loud = Self.deliveryKinds.filter { delivery(for: $0) != .inboxOnly }
        if !loud.isEmpty {
            parts.append("delivery: " + loud.map { "\($0.title) → \(delivery(for: $0).title)" }.joined(separator: ", "))
        }
        if !groupOrderNames.isEmpty {
            parts.append("group order: " + groupOrder.map(\.title).joined(separator: ", "))
        }
        if onlyMyProjects {
            parts.append("only my projects")
        }
        parts.append(coffeeBreak ? "coffee break at \(Self.clock(coffeeMinutes))" : "no coffee break")
        return parts.joined(separator: "; ")
    }

    /// 539 → "08:59"
    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
    }
}

import Foundation

extension InboxNotificationRules {
    /// The kinds Settings → Notifications lists, in the order of the pane: the finished builds first (mine, then the
    /// ones I watch), then what needs me, then what happened to my merge requests, then the rest.
    public static let settingsKinds: [InboxEventKind] = buildKinds + [
        .assigned, .reviewRequested, .mentioned, .approved, .changesRequested, .reviewed, .merged, .pipelineFailed,
        .claudeAnswered, .digestReady, .coffeeBreak, .whatsNew, .otherTodo, .myTodo,
    ]

    /// the four rows of the finished builds, in the order of the pane
    public static let buildKinds: [InboxEventKind] = [
        .buildFailed, .buildSucceeded, .watchedBuildFailed, .watchedBuildSucceeded,
    ]

    /// Returns whether a kind goes to a route, as the user set it (before the projects filter).
    ///
    /// - Parameters:
    ///   - route: the route
    ///   - kind: the kind
    /// - Returns: whether the kind's routes have it
    public func sends(_ kind: InboxEventKind, to route: InboxRoutes) -> Bool {
        routes(for: kind).contains(route)
    }

    /// Turns the Red Dot of a kind on or off, as the checkbox of Settings → Notifications does. The Inbox bit is the
    /// kind's delivery, set with `set(_:for:)`.
    ///
    /// - Parameters:
    ///   - route: the route; only ``InboxRoutes/badge`` does anything
    ///   - isOn: whether the kind goes there
    ///   - kind: the kind
    public mutating func set(_ route: InboxRoutes, _ isOn: Bool, for kind: InboxEventKind) {
        guard route == .badge else {
            return
        }
        var routes = routes(for: kind)
        if isOn {
            routes.insert(.badge)
        } else {
            routes.remove(.badge)
        }
        setRoutes(routes, for: kind)
    }

    /// One line for the log when the routing changes: what differs from the defaults.
    public var summary: String {
        var parts: [String] = []
        let changed = Self.deliveryKinds.filter { delivery(for: $0) != $0.defaultDelivery }
        if !changed.isEmpty {
            parts.append("delivery: " + changed.map { "\($0.title) → \(delivery(for: $0).title)" }.joined(separator: ", "))
        }
        let uncounted = Self.settingsKinds.filter { sends($0, to: .badge) != $0.countsInRedDotByDefault }.map(\.title)
        if !uncounted.isEmpty {
            parts.append("red dot changed: \(uncounted.joined(separator: ", "))")
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

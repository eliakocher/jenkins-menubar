import Foundation

/// One thing the alert window holds: a finished build's alert or an Inbox event delivered as a pop-up (ALERT-03, INBOX-14).
public struct AlertWindowItem: Equatable, Identifiable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// a build's alert, with whether it shows as a window because its banner couldn't
        case build(BuildAlert, notificationsOff: Bool)
        case event(InboxEvent)
    }

    public var payload: Payload

    public init(_ payload: Payload) {
        self.payload = payload
    }

    public init(alert: BuildAlert, notificationsOff: Bool) {
        self.init(.build(alert, notificationsOff: notificationsOff))
    }

    public init(event: InboxEvent) {
        self.init(.event(event))
    }

    /// `build|<alert id>` or `event|<event id>`, so a build and an event never share an id
    public var id: String {
        switch payload {
        case .build(let alert, _): "build|\(alert.id.uuidString)"
        case .event(let event): "event|\(event.id)"
        }
    }

    public var isBuild: Bool {
        if case .build = payload { true } else { false }
    }

    /// Whether the item is bad news, which decides the butler: a build that didn't succeed, and an event that is a failure
    /// (``InboxEvent/isFailure``).
    public var isFailure: Bool {
        switch payload {
        case .build(let alert, _): alert.content.result != .success
        case .event(let event): event.isFailure
        }
    }

    /// Whether the item can't be dismissed with Esc: the coffee break, which has one button, "On My Way ☕", and is never
    /// snoozed or dismissed (the user, 2026-11-04: "only the confirm button, no dismiss").
    public var isMandatory: Bool {
        if case .event(let event) = payload { event.kind == .coffeeBreak } else { false }
    }

    /// the window's title for the item alone
    public var windowTitle: String {
        switch payload {
        case .build(let alert, _): alert.content.headlineParts?.text ?? alert.content.headline
        case .event(let event): event.kind == .coffeeBreak ? "Coffee Break" : event.headline
        }
    }

    // MARK: - A summary's row

    /// The reference a summary row starts with: "!12511 #1" for a build, "!210" or "#31" for an event; `nil` without one.
    public var summaryReference: String? {
        switch payload {
        case .build(let alert, _):
            guard let parts = alert.content.headlineParts else {
                return nil
            }
            return "\(parts.label) #\(String(parts.number))"
        case .event(let event):
            return event.shortReference
        }
    }

    /// the one-line title of a summary row: the build's title or job, the event's target or its headline
    public var summaryTitle: String {
        switch payload {
        case .build(let alert, _):
            alert.content.title ?? alert.build.job
        case .event(let event):
            event.title.isEmpty ? event.headline : event.title
        }
    }

    /// the quiet end of a summary row: a build's duration, the event's kind
    public var summaryDetail: String? {
        switch payload {
        case .build(let alert, _):
            alert.content.facts.first { $0.hasPrefix("Duration: ") }.map { String($0.dropFirst("Duration: ".count)) }
        case .event(let event):
            event.kind.shortTitle
        }
    }
}

/// The alert window's items, the newest first. One item shows as its own pop-up; two or more show as one summary
/// (``AlertSummary``).
public struct AlertWindowItems: Equatable, Sendable {
    public private(set) var items: [AlertWindowItem] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// the item shown alone; `nil` for none or several
    public var single: AlertWindowItem? {
        items.count == 1 ? items[0] : nil
    }

    /// whether the window shows a summary
    public var isSummary: Bool { items.count > 1 }

    /// the window's title in the system's window lists: the item's own, or the summary's; `nil` for an empty window
    public var windowTitle: String? {
        AlertSummary.make(items)?.title ?? items.first?.windowTitle
    }

    /// Adds an item as the newest. One that is already in the window is replaced and becomes the newest.
    public mutating func add(_ item: AlertWindowItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
    }

    /// Removes an item; an id that isn't in the window changes nothing.
    public mutating func dismiss(_ id: String) {
        items.removeAll { $0.id == id }
    }

    public mutating func dismissAll() {
        items = []
    }
}

extension InboxEvent {
    /// Whether the event is bad news: a failed pipeline or build, changes requested on my merge request, and a Claude answer
    /// that is a failure. Every other kind is good or neutral.
    public var isFailure: Bool {
        switch kind {
        case .pipelineFailed, .buildFailed, .watchedBuildFailed, .changesRequested: true
        case .claudeAnswered: headline.hasPrefix("Claude couldn't")
        default: false
        }
    }
}

extension InboxEventKind {
    /// the kind in one word, for a summary row's quiet end
    public var shortTitle: String {
        switch self {
        case .assigned: "Assigned"
        case .reviewRequested: "Review"
        case .mentioned: "Mention"
        case .approved: "Approved"
        case .changesRequested: "Changes"
        case .reviewed: "Reviewed"
        case .merged: "Merged"
        case .pipelineFailed: "Pipeline"
        case .otherTodo, .myTodo: "To-Do"
        case .claudeAnswered: "Claude"
        case .digestReady: "Digest"
        case .buildFailed, .buildSucceeded, .watchedBuildFailed, .watchedBuildSucceeded: "Build"
        case .coffeeBreak: "Coffee"
        case .whatsNew: "Update"
        }
    }
}

/// What the alert window shows when it holds two or more items: one summary instead of pages (the user, 2026-11-04: "if we
/// have multiple popups we close the previous and we show a small summary with a 'go to inbox'"). The details live in the
/// Inbox, which every pop-up already leaves an entry in.
public struct AlertSummary: Equatable, Sendable {
    /// which butler the summary shows
    public enum Butler: String, Equatable, Sendable, CaseIterable {
        /// all failures
        case sad
        /// all successes or good news
        case happy
        /// both
        case mixed
    }

    /// the most rows the list shows at once; more scroll
    public static let visibleRows = 6

    public var title: String
    public var butler: Butler
    /// one row per item, the newest first
    public var rows: [AlertWindowItem]

    /// Returns the summary of items.
    ///
    /// - Parameter items: the window's items, the newest first
    /// - Returns: the summary; `nil` for fewer than two items, which show as themselves
    public static func make(_ items: [AlertWindowItem]) -> AlertSummary? {
        guard items.count > 1 else {
            return nil
        }
        let failures = items.filter(\.isFailure).count
        let butler: Butler = failures == items.count ? .sad : failures == 0 ? .happy : .mixed
        let title: String
        if items.allSatisfy(\.isBuild) {
            switch butler {
            case .sad: title = "\(items.count) Builds Failed"
            case .happy: title = "\(items.count) Builds Succeeded"
            case .mixed: title = "\(items.count) Builds Finished"
            }
        } else {
            title = "\(items.count) New"
        }
        return AlertSummary(title: title, butler: butler, rows: items)
    }
}

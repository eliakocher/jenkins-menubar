import Foundation

/// The kinds of things the Inbox announces (Task 7.03, INBOX-05), each with its own routing in Settings →
/// Notifications.
///
/// A reply in a thread I'm in isn't one: GitLab makes no to-do for it unless I'm mentioned, and the lists the app
/// polls have no comments.
public enum InboxEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// a work item or merge request was assigned to me
    case assigned
    /// my review or approval was asked for
    case reviewRequested
    /// someone mentioned or addressed me
    case mentioned
    /// a reviewer approved my merge request
    case approved
    /// a reviewer requested changes on my merge request
    case changesRequested
    /// a reviewer reviewed my merge request with comments, or GitLab's "review submitted" to-do
    case reviewed
    /// my merge request was merged
    case merged
    /// my merge request's pipeline failed
    case pipelineFailed
    /// any other GitLab to-do, like one I added myself
    case otherTodo
    /// Claude answered a question, or failed to, while its card wasn't on screen: a local entry
    case claudeAnswered
    /// the morning digest is written: a local entry that opens the Digest
    case digestReady
    /// one of my builds failed or went unstable: a local entry, as history of the alert (the pop-up or banner still shows)
    case buildFailed
    /// one of my builds succeeded: a local entry, when its row in Settings → Notifications isn't Off
    case buildSucceeded
    /// a build I only watch failed or went unstable: a local entry
    case watchedBuildFailed
    /// a build I only watch succeeded: a local entry
    case watchedBuildSucceeded
    /// the daily coffee break, at 08:59 by default: a local entry with a line Claude's Haiku wrote
    case coffeeBreak
    /// the app was updated: a local entry that opens "What's New" with the changelog since the last version seen
    case whatsNew
    /// one of the user's own to-dos, kept on this Mac (``MyTodo``): only its Badge toggle matters, it is always in the Inbox
    /// and never announced
    case myTodo

    /// The routes before the user changes them: every kind is in the Inbox, and counts in the Red Dot unless it is a
    /// successful build.
    public var defaultRoutes: InboxRoutes {
        countsInRedDotByDefault ? [.inbox, .badge] : [.inbox]
    }

    /// Whether an entry of this kind can be snoozed anywhere: the Inbox's rows, the pop-up, a banner's buttons. The coffee
    /// break can't (the user, 2026-11-03: "coffee is mandatory"); it can be marked done or dismissed.
    public var canSnooze: Bool {
        self != .coffeeBreak
    }

    /// the Inbox group of its entries (INBOX-02)
    public var group: InboxGroup {
        switch self {
        case .mentioned: .mentions
        case .reviewRequested: .reviewRequests
        case .assigned: .assigned
        case .claudeAnswered, .digestReady: .claude
        case .buildFailed, .buildSucceeded, .watchedBuildFailed, .watchedBuildSucceeded, .pipelineFailed: .builds
        case .coffeeBreak: .coffee
        case .whatsNew: .whatsNew
        case .myTodo: .myToDos
        default: .other
        }
    }

    /// The kinds that say the same thing about one target and are announced once together: a review comes from the
    /// to-do and from the merge request list, as approved, changes requested or reviewed.
    var family: String {
        switch self {
        case .approved, .changesRequested, .reviewed: "review"
        default: rawValue
        }
    }

    /// the kind's name in Settings → Notifications, in Title Style
    public var title: String {
        switch self {
        case .assigned: "Assigned to Me"
        case .reviewRequested: "Review Requested"
        case .mentioned: "Mentioned"
        case .approved: "My MR Approved"
        case .changesRequested: "Changes Requested on My MR"
        case .reviewed: "My MR Reviewed"
        case .merged: "My MR Merged"
        case .pipelineFailed: "My MR's GitLab Pipeline Failed"
        case .otherTodo: "Other To-Dos"
        case .claudeAnswered: "Claude's Answers"
        case .digestReady: "Morning Digest"
        case .buildFailed: "My Jenkins Build Failed or Unstable"
        case .buildSucceeded: "My Jenkins Build Succeeded"
        case .watchedBuildFailed: "Watched Jenkins Build Failed or Unstable"
        case .watchedBuildSucceeded: "Watched Jenkins Build Succeeded"
        case .coffeeBreak: "Coffee Break"
        case .whatsNew: "What's New"
        case .myTodo: "My To-Dos"
        }
    }
}

/// Something that happened between two polls, to announce once (INBOX-05).
public struct InboxEvent: Codable, Hashable, Sendable, Identifiable {
    /// Stable across polls and launches: `todo|<to-do id>` for a GitLab to-do; for a change seen in the merge request
    /// list, its kind, the MR, the reviewer and the time of the poll that saw it.
    public var id: String
    public var kind: InboxEventKind
    /// where it was seen
    public var source: Source
    /// the to-do it came from; `nil` for a change in the merge request list
    public var todoID: String?
    /// the target's title
    public var title: String
    /// the target's full reference, like `group/project!12`
    public var reference: String?
    /// the target's page
    public var targetURL: URL?
    /// the project's full path
    public var projectPath: String?
    /// who did it: the to-do's author, the reviewer; `nil` when nobody did, like a failed pipeline
    public var actor: MergeRequest.Person?
    /// when it happened: the to-do's creation, or the poll that saw the change
    public var occurredAt: Date
    /// what happened, for a local item that says it in its own words, like "Claude answered: Why Did It Fail?"; `nil`
    /// for the kinds ``headline`` words itself
    public var headlineText: String?
    /// a short line under the title: the first line of Claude's answer; `nil` for none
    public var excerpt: String?
    /// for a finished build, its GitLab page: the merge request or the branch it builds, which ``InboxFailureMatching``
    /// uses to tell that a failed build and GitLab's "pipeline failed" are one failure; `nil` for anything else
    public var relatedURL: URL?
    /// for a failed pipeline, the merge request's source branch, which names a branch job's build; `nil` when not known
    public var sourceBranch: String?

    public init(
        id: String, kind: InboxEventKind, source: Source, todoID: String? = nil, title: String, reference: String? = nil,
        targetURL: URL? = nil, projectPath: String? = nil, actor: MergeRequest.Person? = nil, occurredAt: Date,
        headlineText: String? = nil, excerpt: String? = nil, relatedURL: URL? = nil, sourceBranch: String? = nil
    ) {
        self.relatedURL = relatedURL
        self.sourceBranch = sourceBranch
        self.id = id
        self.kind = kind
        self.source = source
        self.todoID = todoID
        self.title = title
        self.reference = reference
        self.targetURL = targetURL
        self.projectPath = projectPath
        self.actor = actor
        self.occurredAt = occurredAt
        self.headlineText = headlineText
        self.excerpt = excerpt
    }

    public enum Source: String, Codable, Hashable, Sendable {
        /// a new GitLab to-do
        case todo
        /// a change between two loads of my merge requests
        case mergeRequests
        /// something of this app: a Claude answer or the digest, kept on this Mac (``InboxStore/addLocal(_:)``)
        case local
    }

    /// A short line for a banner or a row: "Alex Doe approved !12", in sentence case.
    public var headline: String {
        if let headlineText {
            return headlineText
        }
        let who = actor.map { $0.name.isEmpty ? $0.username : $0.name }
        let what = shortReference ?? "an item"
        switch kind {
        case .assigned: return "\(who ?? "Someone") assigned you \(what)"
        case .reviewRequested: return "\(who ?? "Someone") requested your review on \(what)"
        case .mentioned: return "\(who ?? "Someone") mentioned you in \(what)"
        case .approved: return "\(who ?? "Someone") approved \(what)"
        case .changesRequested: return "\(who ?? "Someone") requested changes on \(what)"
        case .reviewed: return "\(who ?? "Someone") reviewed \(what)"
        case .merged: return "\(what) was merged"
        case .pipelineFailed: return "The pipeline of \(what) failed"
        case .otherTodo: return "New to-do on \(what)"
        case .claudeAnswered: return "Claude answered"
        case .digestReady: return "Your digest is ready"
        case .buildFailed, .watchedBuildFailed: return "\(shortReference ?? "A build") failed"
        case .buildSucceeded, .watchedBuildSucceeded: return "\(shortReference ?? "A build") succeeded"
        case .coffeeBreak: return "Time for a break"
        case .whatsNew: return "The app was updated"
        case .myTodo: return "To-do"
        }
    }

    /// the reference without the project, like `!12` or `#7`
    public var shortReference: String? {
        guard let reference, let sign = reference.lastIndex(where: { $0 == "!" || $0 == "#" || $0 == "&" }) else {
            return reference
        }
        return String(reference[sign...])
    }
}

/// Where an event goes: an entry in the Inbox, a count in the Red Dot (INBOX-06). Bit 1 was the macOS banner, which the
/// routes no longer carry: how an event announces itself is its ``InboxDelivery``. The Inbox bit follows it: every
/// choice but Off is an entry.
public struct InboxRoutes: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// an entry in the Inbox; GitLab's to-dos are always there, so this matters for the local entries: the changes seen
    /// in the lists, Claude's answers, the digest, the finished builds
    public static let inbox = InboxRoutes(rawValue: 2)
    /// a count in the Red Dot: the Inbox badge and the menu bar's dot
    public static let badge = InboxRoutes(rawValue: 4)
}

/// An event with where it goes, for the app layer to deliver.
public struct RoutedInboxEvent: Hashable, Sendable, Identifiable {
    public var event: InboxEvent
    public var routes: InboxRoutes
    /// how it announces itself beyond the Inbox: the user's choice for its kind (``InboxDelivery``)
    public var delivery: InboxDelivery

    public init(event: InboxEvent, routes: InboxRoutes, delivery: InboxDelivery = .inbox) {
        self.event = event
        self.routes = routes
        self.delivery = delivery
    }

    public var id: String { event.id }
}

/// The routing of the Inbox's events: per kind, and only my projects (INBOX-06). A pure rule,
/// kept in ``Preferences/inboxNotifications`` for Settings → Notifications to edit.
public struct InboxNotificationRules: Codable, Hashable, Sendable {
    /// the Red Dot choices the user changed, by ``InboxEventKind`` raw value: with ``InboxRoutes/badge`` the kind counts,
    /// without it doesn't; the others keep their defaults, and a kind the app no longer knows is ignored. The Inbox bit
    /// of a value saved before the single choice (Task 7.14) is read by ``NotificationMigration`` only.
    public var overrides: [String: InboxRoutes]
    /// whether only the items of my projects (Settings → Projects) count in the badge
    public var onlyMyProjects: Bool
    /// whether the coffee break's entry comes on weekdays (``CoffeeBreak``); on unless turned off, as the user asked for it
    public var coffeeBreak: Bool
    /// when the coffee break comes, in minutes after midnight, local time
    public var coffeeMinutes: Int
    /// what each kind does, by ``InboxEventKind`` raw value: the ones the user changed from the kind's default
    /// (``InboxEventKind/defaultDelivery``); a kind or a value the app no longer knows is ignored
    public var deliveries: [String: InboxDelivery]
    /// the Inbox's groups in the user's order, by ``InboxGroup`` raw value; empty is the default order
    /// (``InboxGroupOrder``)
    public var groupOrderNames: [String]

    /// the coffee break's time unless the user changes it: 08:59
    public static let defaultCoffeeMinutes = 8 * 60 + 59

    public init(
        overrides: [String: InboxRoutes] = [:], onlyMyProjects: Bool = false, coffeeBreak: Bool = true,
        coffeeMinutes: Int = InboxNotificationRules.defaultCoffeeMinutes, deliveries: [String: InboxDelivery] = [:],
        groupOrderNames: [String] = []
    ) {
        self.overrides = overrides
        self.onlyMyProjects = onlyMyProjects
        self.coffeeBreak = coffeeBreak
        self.coffeeMinutes = coffeeMinutes
        self.deliveries = deliveries
        self.groupOrderNames = groupOrderNames
    }

    // The quiet hours and the sound of the banners the app once had are in files already written; they're ignored.
    private enum CodingKeys: String, CodingKey {
        case overrides, onlyMyProjects, coffeeBreak, coffeeMinutes, deliveries, groupOrderNames
    }

    // A value saved before a field existed decodes with that field's default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            overrides: (try? container.decodeIfPresent([String: InboxRoutes].self, forKey: .overrides)) ?? [:],
            onlyMyProjects: (try? container.decodeIfPresent(Bool.self, forKey: .onlyMyProjects)) ?? false,
            coffeeBreak: (try? container.decodeIfPresent(Bool.self, forKey: .coffeeBreak)) ?? true,
            coffeeMinutes: min(max((try? container.decodeIfPresent(Int.self, forKey: .coffeeMinutes)) ?? Self.defaultCoffeeMinutes, 0), 1439),
            // A delivery this app doesn't know reads as the default, not as a file that can't be read; one equal to its
            // kind's default isn't an override.
            deliveries: ((try? container.decodeIfPresent([String: String].self, forKey: .deliveries)) ?? [:])
                .compactMapValues(InboxDelivery.init(rawValue:))
                .filter { entry in InboxEventKind(rawValue: entry.key).map { $0.defaultDelivery != entry.value } ?? false },
            groupOrderNames: (try? container.decodeIfPresent([String].self, forKey: .groupOrderNames)) ?? [])
    }

    /// Returns the routes of a kind: the Inbox when it isn't Off, the Red Dot as the user set it or the default.
    ///
    /// - Parameter kind: the kind
    /// - Returns: the routes, before the projects filter
    public func routes(for kind: InboxEventKind) -> InboxRoutes {
        var routes: InboxRoutes = delivery(for: kind) == .off ? [] : [.inbox]
        if overrides[kind.rawValue].map({ $0.contains(.badge) }) ?? kind.countsInRedDotByDefault {
            routes.insert(.badge)
        }
        return routes
    }

    /// Sets the Red Dot of a kind; the default removes the override. The Inbox bit is the delivery's, see
    /// the delivery, so it is ignored here.
    ///
    /// - Parameters:
    ///   - routes: the routes; only ``InboxRoutes/badge`` counts
    ///   - kind: the kind
    public mutating func setRoutes(_ routes: InboxRoutes, for kind: InboxEventKind) {
        let counts = routes.contains(.badge)
        overrides[kind.rawValue] = counts == kind.countsInRedDotByDefault ? nil : (counts ? [.badge] : [])
    }

    /// Returns where an event goes.
    ///
    /// "Only my projects": an item of another project doesn't count in the badge; it stays in the Inbox. An item without
    /// a project counts as mine.
    ///
    /// - Parameters:
    ///   - event: the event
    ///   - myProjects: the full paths of my projects
    /// - Returns: the routes; empty when it goes nowhere
    public func route(_ event: InboxEvent, myProjects: Set<String>) -> InboxRoutes {
        var routes = routes(for: event.kind)
        if !isMine(event.projectPath, myProjects) {
            routes.remove(.badge)
        }
        return routes
    }

    /// Whether an Inbox entry counts in the badge, whatever the time.
    ///
    /// - Parameters:
    ///   - kind: the entry's kind
    ///   - projectPath: the entry's project
    ///   - myProjects: the full paths of my projects
    /// - Returns: whether it counts
    public func countsInBadge(_ kind: InboxEventKind, projectPath: String?, myProjects: Set<String>) -> Bool {
        routes(for: kind).contains(.badge) && isMine(projectPath, myProjects)
    }

    private func isMine(_ projectPath: String?, _ myProjects: Set<String>) -> Bool {
        guard onlyMyProjects, let projectPath else {
            return true
        }
        return myProjects.contains(projectPath)
    }
}

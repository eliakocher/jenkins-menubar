import Foundation

/// One row of the Inbox, ready to draw: a GitLab to-do, or a change of my merge requests that the routing put in the
/// Inbox (INBOX-02).
public struct InboxEntry: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        /// a GitLab to-do: Done, Restore and Snooze go to GitLab
        case todo(InboxTodo)
        /// a change seen between two loads, kept on this Mac: Done and Restore stay here
        case event(InboxEvent)
        /// one of the user's own to-dos, kept on this Mac and never sent to GitLab (``MyTodo``)
        case mine(MyTodo)
    }

    public var source: Source
    /// the to-do's id, or the event's
    public var id: String
    public var kind: InboxEventKind
    public var group: InboxGroup
    /// the target's title
    public var title: String
    /// what happened, in sentence case: "Alex Doe mentioned you"
    public var headline: String
    /// GitLab's to-do text, like the comment that mentions me; empty for an event
    public var body: String
    /// the target's full reference, like `group/project!12`
    public var reference: String?
    /// the target's page, which the app opens in its own views (⌥ the browser)
    public var targetURL: URL?
    /// what the target is; `nil` for a local item of this app, which has no GitLab target
    public var targetKind: InboxTodo.TargetKind?
    public var projectPath: String?
    /// who did it
    public var actor: MergeRequest.Person?
    /// when it happened, newest first in the lists
    public var date: Date
    /// until when it sleeps, in the Snoozed list; `nil` elsewhere
    public var snoozedUntil: Date?
    /// when it is due, for one of my to-dos with a date; `nil` for the others
    public var dueDate: Date?
    /// the place in the user's own order, for a pending one of my to-dos; `nil` for the others, which go newest first
    public var position: Int?

    public init(todo: InboxTodo, snoozedUntil: Date? = nil) {
        source = .todo(todo)
        id = todo.id
        kind = todo.action.eventKind
        group = todo.group
        title = todo.title
        let who = todo.author.map { $0.name.isEmpty ? $0.username : $0.name }
        switch todo.action {
        case .buildFailed: headline = "Pipeline failed"
        case .unmergeable: headline = "Can't be merged"
        default:
            let phrase = todo.action.phrase
            if let who {
                headline = "\(who) \(phrase)"
            } else {
                headline = phrase.prefix(1).uppercased() + String(phrase.dropFirst())
            }
        }
        body = todo.body
        reference = todo.reference
        targetURL = todo.targetURL
        targetKind = todo.targetKind
        projectPath = todo.projectPath
        actor = todo.author
        date = todo.createdAt
        self.snoozedUntil = snoozedUntil
    }

    public init(event: InboxEvent, snoozedUntil: Date? = nil) {
        source = .event(event)
        id = event.id
        kind = event.kind
        group = event.kind.group
        title = event.title
        headline = event.headline
        body = event.excerpt ?? ""
        reference = event.reference
        targetURL = event.targetURL
        targetKind = event.source == .local ? nil : .mergeRequest
        projectPath = event.projectPath
        actor = event.actor
        date = event.occurredAt
        self.snoozedUntil = snoozedUntil
    }

    /// Returns the row of one of my to-dos.
    ///
    /// - Parameters:
    ///   - todo: the to-do
    ///   - position: its place in my order while it is pending; `nil` once it is done or snoozed
    ///   - snoozedUntil: until when it sleeps, in the Snoozed list
    public init(mine todo: MyTodo, position: Int? = nil, snoozedUntil: Date? = nil) {
        source = .mine(todo)
        id = todo.entryID
        kind = .myTodo
        group = .myToDos
        title = todo.title
        headline = todo.title
        body = todo.note
        reference = todo.link?.reference
        targetURL = todo.link?.url
        targetKind = nil
        projectPath = nil
        actor = nil
        date = todo.doneAt ?? todo.createdAt
        self.snoozedUntil = snoozedUntil
        dueDate = todo.dueDate
        self.position = position
    }

    /// Where the app goes when the row is opened, when it is a link to a place of the app itself: the Digest for "Your
    /// digest is ready". `nil` for a page of GitLab or Jenkins, which ``targetURL`` opens in the app's own views.
    public var appRoute: AppRoute? {
        targetURL.flatMap(AppRoute.init(url:))
    }

    /// whether the row is a local item of this app (a Claude answer, the digest, a failed build): Done only removes it
    /// here, and nothing goes to GitLab. One of my own to-dos isn't: opening it never clears it, its checkbox does.
    public var isLocalItem: Bool {
        if case .event(let event) = source { event.source == .local } else { false }
    }

    /// whether the row is one of my own to-dos
    public var isMine: Bool {
        if case .mine = source { true } else { false }
    }

    /// my to-do, when it is one
    public var myTodo: MyTodo? {
        if case .mine(let todo) = source { todo } else { nil }
    }

    /// the GitLab to-do, when it is one
    public var todo: InboxTodo? {
        if case .todo(let todo) = source { todo } else { nil }
    }
}

/// One group of rows, as the Inbox section shows it (INBOX-02).
public struct InboxSection: Hashable, Sendable, Identifiable {
    public var group: InboxGroup
    /// newest first
    public var entries: [InboxEntry]

    public init(group: InboxGroup, entries: [InboxEntry]) {
        self.group = group
        self.entries = entries
    }

    public var id: InboxGroup { group }

    /// Groups rows into the Inbox's sections, in the user's group order, newest first in each (my to-dos in my own order);
    /// empty groups are left out.
    ///
    /// - Parameters:
    ///   - entries: the rows
    ///   - order: the groups in the user's order (``InboxNotificationRules/groupOrder``)
    /// - Returns: the sections
    public static func grouped(_ entries: [InboxEntry], order: [InboxGroup] = InboxGroup.allCases) -> [InboxSection] {
        let byGroup = Dictionary(grouping: entries, by: \.group)
        return InboxGroupOrder.merged(stored: order.map(\.rawValue)).compactMap { group in
            guard let rows = byGroup[group], !rows.isEmpty else { return nil }
            return InboxSection(group: group, entries: rows.sorted(by: Self.isBefore))
        }
    }

    /// my own order first, where a to-do has a place, then newest first
    private static func isBefore(_ lhs: InboxEntry, _ rhs: InboxEntry) -> Bool {
        switch (lhs.position, rhs.position) {
        case (let left?, let right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return (lhs.date, lhs.id) > (rhs.date, rhs.id)
        }
    }
}

/// What the Inbox shows: like GitLab's To-Do List filters, plus Snoozed (INBOX-02).
public struct InboxFilter: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, CaseIterable {
        case pending
        case snoozed
        case done
    }

    public var state: State
    /// one group only; `nil` for all
    public var group: InboxGroup?
    /// one project's full path only; `nil` for all
    public var project: String?

    public init(state: State = .pending, group: InboxGroup? = nil, project: String? = nil) {
        self.state = state
        self.group = group
        self.project = project
    }

    func includes(_ entry: InboxEntry) -> Bool {
        (group == nil || entry.group == group) && (project == nil || entry.projectPath == project)
    }
}

/// A change of my merge requests that the routing put in the Inbox, kept on this Mac (INBOX-05).
public struct InboxLocalEntry: Codable, Hashable, Sendable {
    public var event: InboxEvent
    /// when Done was clicked; `nil` while pending
    public var doneAt: Date?
    /// until when it sleeps; `nil` when it isn't snoozed
    public var snoozedUntil: Date?

    public init(event: InboxEvent, doneAt: Date? = nil, snoozedUntil: Date? = nil) {
        self.event = event
        self.doneAt = doneAt
        self.snoozedUntil = snoozedUntil
    }
}

/// What the Inbox keeps in the app's support folder: the last snapshot, the announced events, the local entries and
/// snoozes, and what the GitLab turned out to answer (INBOX-04, INBOX-05).
struct InboxState: Codable, Hashable, Sendable {
    var snapshot = InboxSnapshot()
    var announcements = InboxAnnouncements()
    var localEntries: [InboxLocalEntry] = []
    /// to-do id → wake time, for a GitLab without the snooze mutations
    var localSnoozes: [String: Date] = [:]
    /// the to-do query level that answered; `nil` until one did
    var level: TodoQueryLevel?
    /// whether GitLab snoozes; `nil` until a snooze tried
    var snoozesInGitLab: Bool?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case snapshot, announcements, localEntries, localSnoozes, level, snoozesInGitLab
    }

    // A file written before a field existed reads with that field's default.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = (try? container.decodeIfPresent(InboxSnapshot.self, forKey: .snapshot)) ?? InboxSnapshot()
        announcements = (try? container.decodeIfPresent(InboxAnnouncements.self, forKey: .announcements)) ?? InboxAnnouncements()
        localEntries = (try? container.decodeIfPresent([InboxLocalEntry].self, forKey: .localEntries)) ?? []
        localSnoozes = (try? container.decodeIfPresent([String: Date].self, forKey: .localSnoozes)) ?? [:]
        level = try? container.decodeIfPresent(TodoQueryLevel.self, forKey: .level)
        snoozesInGitLab = try? container.decodeIfPresent(Bool.self, forKey: .snoozesInGitLab)
    }

    /// the most local entries kept; the oldest go first
    static let maxLocalEntries = 100
    /// how long a done local entry stays in the Done list
    static let doneKeptFor: TimeInterval = 14 * 24 * 3600
    /// how long a pending local entry stays
    static let pendingKeptFor: TimeInterval = 30 * 24 * 3600

    /// Drops the local entries past their time, and beyond ``maxLocalEntries``.
    mutating func pruneLocalEntries(now: Date) {
        localEntries.removeAll { entry in
            if let doneAt = entry.doneAt {
                return now.timeIntervalSince(doneAt) > Self.doneKeptFor
            }
            return now.timeIntervalSince(entry.event.occurredAt) > Self.pendingKeptFor
        }
        if localEntries.count > Self.maxLocalEntries {
            localEntries = Array(localEntries.sorted { $0.event.occurredAt > $1.event.occurredAt }.prefix(Self.maxLocalEntries))
        }
    }
}

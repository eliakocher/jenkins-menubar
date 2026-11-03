import Foundation

/// What the Inbox last saw, to tell what is new at the next poll (INBOX-05). Kept on disk with the announced events,
/// so a restart doesn't announce again what the last run saw.
public struct InboxSnapshot: Codable, Hashable, Sendable {
    /// the to-dos of the last to-do load; `nil` before the first
    public var todos: Todos?
    /// my merge requests at the last load of their list; `nil` before the first
    public var mergeRequests: MergeRequests?

    public init(todos: Todos? = nil, mergeRequests: MergeRequests? = nil) {
        self.todos = todos
        self.mergeRequests = mergeRequests
    }

    public struct Todos: Codable, Hashable, Sendable {
        /// the ids of the pending and snoozed to-dos
        public var ids: Set<String>
        public var takenAt: Date

        public init(ids: Set<String>, takenAt: Date) {
            self.ids = ids
            self.takenAt = takenAt
        }
    }

    public struct MergeRequests: Codable, Hashable, Sendable {
        public var items: [MergeRequestState]
        public var takenAt: Date

        public init(items: [MergeRequestState], takenAt: Date) {
            self.items = items
            self.takenAt = takenAt
        }

        /// Takes what the detection needs from the list.
        ///
        /// - Parameters:
        ///   - list: my open merge requests
        ///   - takenAt: when it was loaded
        public init(_ list: MergeRequestList, takenAt: Date) {
            self.init(items: list.mergeRequests.map(MergeRequestState.init), takenAt: takenAt)
        }
    }

    /// One merge request as the detection compares it.
    public struct MergeRequestState: Codable, Hashable, Sendable {
        public var url: URL
        public var reference: String
        public var title: String
        public var author: MergeRequest.Person
        public var roles: Set<MergeRequest.Role>
        public var pipelineStatus: MergeRequest.PipelineStatus?
        public var reviewers: [MergeRequest.Reviewer]

        public init(
            url: URL, reference: String, title: String, author: MergeRequest.Person, roles: Set<MergeRequest.Role>,
            pipelineStatus: MergeRequest.PipelineStatus? = nil, reviewers: [MergeRequest.Reviewer] = []
        ) {
            self.url = url
            self.reference = reference
            self.title = title
            self.author = author
            self.roles = roles
            self.pipelineStatus = pipelineStatus
            self.reviewers = reviewers
        }

        public init(_ mergeRequest: MergeRequest) {
            self.init(
                url: mergeRequest.webURL, reference: mergeRequest.reference, title: mergeRequest.title,
                author: mergeRequest.author, roles: mergeRequest.roles, pipelineStatus: mergeRequest.pipelineStatus,
                reviewers: mergeRequest.reviewers)
        }

        /// the project's full path, from the reference `group/project!12`
        var projectPath: String? {
            reference.lastIndex(of: "!").map { String(reference[..<$0]) }
        }
    }
}

/// The events already announced, so none is announced twice, across restarts too (INBOX-05).
public struct InboxAnnouncements: Codable, Hashable, Sendable {
    /// how long the same thing about one target counts as announced, like a review seen first as a to-do and then in
    /// the merge request list
    public static let coalesceWindow: TimeInterval = 30 * 60
    /// how long an announced event is remembered
    public static let keptFor: TimeInterval = 14 * 24 * 3600

    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var family: String
        /// the target's page, as text
        public var target: String?
        public var at: Date

        public init(id: String, family: String, target: String?, at: Date) {
            self.id = id
            self.family = family
            self.target = target
            self.at = at
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Whether an event was announced: its id, or the same kind of news about the same target within the
    /// ``coalesceWindow``.
    public func contains(_ event: InboxEvent) -> Bool {
        let target = event.targetURL?.absoluteString
        return entries.contains { entry in
            entry.id == event.id
                // Two answers of Claude about one item are two answers; only the news of GitLab coalesces.
                || (event.source != .local && target != nil && entry.target == target && entry.family == event.kind.family
                    && abs(event.occurredAt.timeIntervalSince(entry.at)) < Self.coalesceWindow)
        }
    }

    /// Notes an event as announced, and forgets those older than ``keptFor``.
    public mutating func record(_ event: InboxEvent, now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.keptFor }
        entries.append(Entry(id: event.id, family: event.kind.family, target: event.targetURL?.absoluteString, at: event.occurredAt))
    }
}

/// Finds the events between two snapshots (INBOX-05): from the to-dos, and from comparing my merge requests between
/// two loads. Pure: the store keeps the snapshots and the announcements.
///
/// - No earlier snapshot (the first launch, or a lost state file): nothing is announced; the snapshot is the start.
/// - The first detection after a launch announces only what happened in the last ``launchLookback``: the Mac may
///   have been off for a weekend, and that news waits in the Inbox, not in a flood of banners.
/// - A to-do is new when the last snapshot didn't have it and it was created after that snapshot (less
///   ``clockMargin``): a to-do back from snooze or from done isn't news.
public enum InboxEventDetector {
    /// how far back the first detection after a launch announces
    public static let launchLookback: TimeInterval = 3600
    /// how much earlier than the last snapshot a new to-do may be created, for the server's clock and the poll's time
    public static let clockMargin: TimeInterval = 600

    /// Returns the events of the to-dos that are new since the last snapshot.
    ///
    /// - Parameters:
    ///   - todos: the pending to-dos now (snoozed ones aren't news)
    ///   - previous: the last snapshot's to-dos
    ///   - now: the time of this poll
    ///   - firstAfterLaunch: whether this is the first detection since the app started
    /// - Returns: the events, newest first
    public static func todoEvents(
        _ todos: [InboxTodo], since previous: InboxSnapshot.Todos?, now: Date, firstAfterLaunch: Bool
    ) -> [InboxEvent] {
        guard let previous else {
            return []
        }
        let earliest = max(
            previous.takenAt.addingTimeInterval(-clockMargin),
            firstAfterLaunch ? now.addingTimeInterval(-launchLookback) : .distantPast)
        return todos
            .filter { !previous.ids.contains($0.id) && $0.createdAt >= earliest && $0.state == .pending }
            .sorted { $0.createdAt > $1.createdAt }
            .map { todo in
                InboxEvent(
                    id: "todo|\(todo.id)", kind: todo.action.eventKind, source: .todo, todoID: todo.id, title: todo.title,
                    reference: todo.reference, targetURL: todo.targetURL, projectPath: todo.projectPath, actor: todo.author,
                    occurredAt: todo.createdAt)
            }
    }

    /// Returns the events between two loads of my merge requests.
    ///
    /// - Review requested from me, or assigned to me by someone else: an MR that has the role now and didn't before.
    /// - On my own MRs (authored): a reviewer who approved, requested changes or reviewed since; the pipeline that
    ///   failed since; an MR gone from the list that `merged` names.
    ///
    /// - Parameters:
    ///   - previous: the last snapshot's merge requests
    ///   - current: the merge requests now
    ///   - me: my GitLab username
    ///   - merged: the pages of the MRs known merged, among those gone from the list
    ///   - firstAfterLaunch: whether this is the first detection since the app started
    /// - Returns: the events, in the list's order
    public static func mergeRequestEvents(
        from previous: InboxSnapshot.MergeRequests?, to current: InboxSnapshot.MergeRequests, me: String,
        merged: Set<URL> = [], firstAfterLaunch: Bool
    ) -> [InboxEvent] {
        guard let previous,
            !firstAfterLaunch || current.takenAt.timeIntervalSince(previous.takenAt) <= launchLookback
        else {
            return []
        }
        let now = current.takenAt
        let before = Dictionary(previous.items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [InboxEvent] = []
        func add(_ kind: InboxEventKind, _ item: InboxSnapshot.MergeRequestState, actor: MergeRequest.Person?) {
            events.append(InboxEvent(
                id: "\(kind.rawValue)|\(item.url.absoluteString)|\(actor?.username ?? "")|\(Int(now.timeIntervalSince1970))",
                kind: kind, source: .mergeRequests, title: item.title, reference: item.reference, targetURL: item.url,
                projectPath: item.projectPath, actor: actor, occurredAt: now))
        }
        for item in current.items {
            let old = before[item.url]
            if item.roles.contains(.reviewRequested), old?.roles.contains(.reviewRequested) != true {
                add(.reviewRequested, item, actor: item.author)
            }
            if item.roles.contains(.assigned), old?.roles.contains(.assigned) != true, item.author.username != me {
                add(.assigned, item, actor: item.author)
            }
            guard item.roles.contains(.authored), let old else {
                continue
            }
            if item.pipelineStatus == .failed, old.pipelineStatus != .failed {
                add(.pipelineFailed, item, actor: nil)
            }
            for reviewer in item.reviewers where reviewer.username != me {
                let was = old.reviewers.first { $0.username == reviewer.username }
                let person = MergeRequest.Person(username: reviewer.username, name: reviewer.name)
                if reviewer.approved, was?.approved != true {
                    add(.approved, item, actor: person)
                } else if reviewer.reviewState == .requestedChanges, was?.reviewState != .requestedChanges {
                    add(.changesRequested, item, actor: person)
                } else if reviewer.reviewState == .reviewed, was?.reviewState != .reviewed {
                    add(.reviewed, item, actor: person)
                }
            }
        }
        let still = Set(current.items.map(\.url))
        for item in previous.items where item.roles.contains(.authored) && !still.contains(item.url) && merged.contains(item.url) {
            add(.merged, item, actor: nil)
        }
        return events
    }

    /// Returns the events not announced yet, each once.
    ///
    /// - Parameters:
    ///   - events: the events found
    ///   - announcements: what was announced before
    /// - Returns: the new ones, in their order, and the announcements with them
    public static func unannounced(
        _ events: [InboxEvent], in announcements: InboxAnnouncements, now: Date
    ) -> (events: [InboxEvent], announcements: InboxAnnouncements) {
        var announcements = announcements
        var fresh: [InboxEvent] = []
        for event in events where !announcements.contains(event) {
            fresh.append(event)
            announcements.record(event, now: now)
        }
        return (fresh, announcements)
    }

    /// The merge requests of mine that left the list since the last snapshot: merged or closed, which one asks
    /// GitLab.
    ///
    /// - Parameters:
    ///   - previous: the last snapshot's merge requests
    ///   - current: the merge requests now
    /// - Returns: the ones gone, by project path, with their iids
    public static func vanishedAuthored(
        from previous: InboxSnapshot.MergeRequests?, to current: InboxSnapshot.MergeRequests
    ) -> [(path: String, iid: Int, url: URL)] {
        guard let previous else {
            return []
        }
        let still = Set(current.items.map(\.url))
        return previous.items.compactMap { item in
            guard item.roles.contains(.authored), !still.contains(item.url), let path = item.projectPath,
                let sign = item.reference.lastIndex(of: "!"), let iid = Int(item.reference[item.reference.index(after: sign)...])
            else { return nil }
            return (path, iid, item.url)
        }
    }
}

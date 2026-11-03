import Foundation

/// One entry of GitLab's To-Do List, which the Inbox is (Task 7.03, INBOX-01): done in the app is done in GitLab.
///
/// The field names come from GitLab's GraphQL schema source (`Types::TodoType`, `TodoableInterface`), not from an
/// answer of the user's GitLab: inferred until the first real run.
public struct InboxTodo: Codable, Hashable, Sendable, Identifiable {
    /// GitLab's global id, like `gid://gitlab/Todo/123`, which the mutations take
    public var id: String
    /// why the to-do exists, like `mentioned`
    public var action: Action
    /// what it points at, like `MERGEREQUEST`
    public var targetKind: TargetKind
    /// pending or done, as GitLab last said
    public var state: State
    /// the target's title; GitLab's to-do text when the target has none
    public var title: String
    /// GitLab's to-do text, like the comment that mentions me
    public var body: String
    /// the target's page, `nil` when GitLab sends none (a deleted target)
    public var targetURL: URL?
    /// the target's full reference, like `group/project!12`
    public var reference: String?
    /// the target's iid
    public var iid: Int?
    /// the project's full path, like `group/project`; `nil` for a group's to-do
    public var projectPath: String?
    /// who caused the to-do
    public var author: MergeRequest.Person?
    public var createdAt: Date
    /// until when GitLab snoozes it; `nil` when it isn't snoozed
    public var snoozedUntil: Date?

    public init(
        id: String, action: Action, targetKind: TargetKind, state: State = .pending, title: String, body: String = "",
        targetURL: URL? = nil, reference: String? = nil, iid: Int? = nil, projectPath: String? = nil,
        author: MergeRequest.Person? = nil, createdAt: Date, snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.targetKind = targetKind
        self.state = state
        self.title = title
        self.body = body
        self.targetURL = targetURL
        self.reference = reference
        self.iid = iid
        self.projectPath = projectPath
        self.author = author
        self.createdAt = createdAt
        self.snoozedUntil = snoozedUntil
    }

    /// pending or done (`TodoStateEnum`, lowercase in GraphQL: inferred)
    public enum State: String, Codable, Hashable, Sendable {
        case pending
        case done
    }

    /// GitLab's `TodoActionEnum`: the names of `Todo.action_names` (verified in GitLab's source); an unknown one is
    /// kept as it came, and counts as Other.
    public struct Action: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let assigned = Action(rawValue: "assigned")
        public static let mentioned = Action(rawValue: "mentioned")
        public static let buildFailed = Action(rawValue: "build_failed")
        public static let marked = Action(rawValue: "marked")
        public static let approvalRequired = Action(rawValue: "approval_required")
        public static let unmergeable = Action(rawValue: "unmergeable")
        public static let directlyAddressed = Action(rawValue: "directly_addressed")
        public static let mergeTrainRemoved = Action(rawValue: "merge_train_removed")
        public static let reviewRequested = Action(rawValue: "review_requested")
        public static let memberAccessRequested = Action(rawValue: "member_access_requested")
        public static let reviewSubmitted = Action(rawValue: "review_submitted")
        public static let addedApprover = Action(rawValue: "added_approver")

        public var description: String { rawValue }

        /// the event kind this to-do announces
        public var eventKind: InboxEventKind {
            switch self {
            case .assigned: .assigned
            case .reviewRequested, .approvalRequired, .addedApprover: .reviewRequested
            case .mentioned, .directlyAddressed: .mentioned
            case .buildFailed: .pipelineFailed
            case .reviewSubmitted: .reviewed
            default: .otherTodo
            }
        }

        /// what the author did, after their name: "mentioned you", "requested your review"
        public var phrase: String {
            switch self {
            case .assigned: "assigned you"
            case .mentioned: "mentioned you"
            case .directlyAddressed: "addressed you"
            case .reviewRequested: "requested your review"
            case .approvalRequired, .addedApprover: "asked for your approval"
            case .reviewSubmitted: "reviewed your merge request"
            case .buildFailed: "pipeline failed"
            case .unmergeable: "can't be merged"
            case .mergeTrainRemoved: "removed from the merge train"
            case .marked: "added a to-do"
            case .memberAccessRequested: "requested access"
            default: rawValue.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// GitLab's `TodoTargetEnum` (verified in GitLab's source; `EPIC` comes from the Enterprise Edition).
    public struct TargetKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let mergeRequest = TargetKind(rawValue: "MERGEREQUEST")
        public static let issue = TargetKind(rawValue: "ISSUE")
        public static let workItem = TargetKind(rawValue: "WORKITEM")
        public static let epic = TargetKind(rawValue: "EPIC")
        public static let commit = TargetKind(rawValue: "COMMIT")
        public static let design = TargetKind(rawValue: "DESIGN")

        public var description: String { rawValue }

        /// whether the app opens it in its Merge Requests or work item views
        public var opensInApp: Bool {
            [.mergeRequest, .issue, .workItem, .epic].contains(self)
        }
    }

    /// the Inbox group it shows in
    public var group: InboxGroup { action.eventKind.group }
}

/// The groups of the Inbox (INBOX-02). The cases are in the default order, which the user can change in Settings →
/// Notifications (``InboxGroupOrder``): their own to-dos first, the daily coffee next, so neither sits at the bottom.
public enum InboxGroup: String, Codable, Hashable, Sendable, CaseIterable {
    /// the user's own to-dos, kept on this Mac (``MyTodo``)
    case myToDos
    /// what's new after an update, a local entry of this app
    case whatsNew
    /// the coffee break, a local entry of this app
    case coffee
    /// Claude's answers and the digest: local entries of this app
    case claude
    case mentions
    case reviewRequests
    case assigned
    /// failed and unstable builds, and failed pipelines
    case builds
    case other

    /// the group's header, in Title Style
    public var title: String {
        switch self {
        case .myToDos: "My To-Dos"
        case .whatsNew: "What's New"
        case .coffee: "Coffee"
        case .claude: "Claude"
        case .mentions: "Mentions"
        case .reviewRequests: "Review Requests"
        case .assigned: "Assigned"
        case .builds: "Builds"
        case .other: "Other"
        }
    }
}
